"""Contract tests, separate from the real scientific smoke run."""
import base64
import hashlib
import hmac
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "workers/experiment-runner/worker.py"
spec = importlib.util.spec_from_file_location("worker", WORKER)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

class WorkerContracts(unittest.TestCase):
    def test_generated_code_cannot_read_files_or_import_os(self):
        for code in ["def run(data):\n    return {'x': len(open('/etc/passwd').read())}",
                     "import os\ndef run(data):\n    return {'x': os.getpid()}",
                     "def run(data):\n    return {'x': len(data.__class__.__mro__)}"]:
            with self.assertRaises(ValueError):
                worker.run_generated({"python": code, "data": [1], "metric": "x"})

    def test_analytic_solution_and_independent_rerun(self):
        points = [[i, 2*i+1] for i in range(5)]
        self.assertEqual(worker.fit(points), {"slope": 2.0, "intercept": 1.0, "mse": 0.0})
        self.assertEqual(worker.fit(points, True), worker.fit(points))

    def test_sample_limit_and_nonfinite(self):
        for points in ([[i, i] for i in range(6)], [[0, 1], [0, 2]], [[0, 1], [1, float("nan")]]):
            with self.assertRaises(ValueError):
                worker.fit(points)

    def test_untrusted_manifest_rejected(self):
        with tempfile.TemporaryDirectory(prefix="norma-worker-contract-") as path:
            os.chmod(path, 0o700)
            Path(path, ".worker-key").write_bytes(b"test-key")
            request = {"operation": "submit", "root": path, "manifest": base64.b64encode(b"{}").decode(), "signature": "0"*64}
            result = subprocess.run([sys.executable, "-I", str(WORKER)], input=json.dumps(request), text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn("untrusted", result.stdout)

    def test_expired_authorization_rejected(self):
        with tempfile.TemporaryDirectory(prefix="norma-worker-contract-") as path:
            os.chmod(path, 0o700)
            key = b"test-key"
            Path(path, ".worker-key").write_bytes(key)
            manifest = worker.canonical({"expiresAt": 0})
            request = {"operation": "submit", "root": path, "manifest": base64.b64encode(manifest).decode(),
                       "signature": hmac.new(key, manifest, hashlib.sha256).hexdigest()}
            result = subprocess.run([sys.executable, "-I", str(WORKER)], input=json.dumps(request), text=True, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn("expired", result.stdout)

    def test_health_has_no_credentials(self):
        result = subprocess.run([sys.executable, "-I", str(WORKER)], input='{"operation":"health"}', text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(set(json.loads(result.stdout)), {"version", "python", "pythonVersion", "architecture", "platform", "packagesFingerprint", "fingerprint"})

    def test_environment_drift_idempotency_and_evidence_recovery(self):
        with tempfile.TemporaryDirectory(prefix="norma-worker-contract-") as path:
            os.chmod(path, 0o700)
            key = b"isolated-test-key"
            Path(path, ".worker-key").write_bytes(key)
            def invoke(operation, manifest):
                raw = worker.canonical(manifest)
                request = {"operation": operation, "root": path, "manifest": base64.b64encode(raw).decode(),
                           "signature": hmac.new(key, raw, hashlib.sha256).hexdigest()}
                result = subprocess.run([sys.executable, "-I", str(WORKER)], input=json.dumps(request), text=True, capture_output=True, timeout=5)
                return result.returncode, json.loads(result.stdout)
            health = subprocess.run([sys.executable, "-I", str(WORKER)], input='{"operation":"health"}', text=True, capture_output=True, timeout=5)
            manifest = {"expiresAt": (time.time()+60)*1000, "runID": str(uuid.uuid4()), "targetID": "local", "runtimeSeconds": 30,
                        "workerHash": hashlib.sha256(WORKER.read_bytes()).hexdigest(), "environmentFingerprint": "changed",
                        "batch": 1, "seed": 0, "steps": 0, "independent": False, "points": [[i, 2*i+1] for i in range(5)]}
            code, value = invoke("submit", manifest)
            self.assertEqual(code, 1)
            self.assertIn("environment drift", value["error"])
            self.assertFalse(Path(path, "runs").exists())
            manifest["environmentFingerprint"] = json.loads(health.stdout)["fingerprint"]
            code, first = invoke("submit", manifest)
            self.assertEqual(code, 0, first)
            code, duplicate = invoke("submit", manifest)
            self.assertEqual(code, 0, duplicate)
            self.assertEqual(first, duplicate)
            code, recovered = invoke("fetch", manifest)
            self.assertEqual(code, 0, recovered)
            self.assertEqual(first, recovered)
            manifest["points"][0][1] = 99
            code, collision = invoke("submit", manifest)
            self.assertEqual(code, 1)
            self.assertIn("collision", collision["error"])

if __name__ == "__main__":
    unittest.main()
