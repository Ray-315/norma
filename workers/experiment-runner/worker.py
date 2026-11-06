#!/usr/bin/env python3
"""NORMA restricted local worker. JSON requests on stdin, no shell evaluation."""
import base64
import hashlib
import hmac
import json
import math
import os
import platform
import sys
import time
import importlib.metadata
from pathlib import Path

VERSION = 1

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()

def environment():
    packages = sorted((d.metadata.get("Name", ""), d.version) for d in importlib.metadata.distributions())
    package_hash = hashlib.sha256(canonical(packages)).hexdigest()
    binary_hash = hashlib.sha256(Path(sys.executable).resolve().read_bytes()).hexdigest()
    dependency_hash = hashlib.sha256((binary_hash + package_hash).encode()).hexdigest()
    parts = ["local", sys.executable, platform.python_version(), platform.machine(), platform.system(), dependency_hash]
    return {"version": VERSION, "python": sys.executable, "pythonVersion": platform.python_version(),
            "architecture": platform.machine(), "platform": platform.system(),
            "packagesFingerprint": package_hash, "fingerprint": hashlib.sha256("|".join(parts).encode()).hexdigest()}

def fit(points, independent=False):
    if not 2 <= len(points) <= 5:
        raise ValueError("smoke requires 2..5 points")
    if any(len(p) != 2 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in p) for p in points):
        raise ValueError("invalid data")
    n = len(points)
    sx, sy = sum(p[0] for p in points), sum(p[1] for p in points)
    if independent:
        mx, my = sx / n, sy / n
        variance = sum((x - mx) ** 2 for x, _ in points)
        if variance == 0:
            raise ValueError("singular design")
        slope = sum((x - mx) * (y - my) for x, y in points) / variance
        intercept = my - slope * mx
    else:
        sxx = sum(x * x for x, _ in points)
        sxy = sum(x * y for x, y in points)
        denominator = n * sxx - sx * sx
        if denominator == 0:
            raise ValueError("singular design")
        slope = (n * sxy - sx * sy) / denominator
        intercept = (sy - slope * sx) / n
    mse = sum((slope * x + intercept - y) ** 2 for x, y in points) / n
    return {"slope": slope, "intercept": intercept, "mse": mse}

def main():
    request = json.loads(sys.stdin.buffer.read(1024 * 1024 + 1))
    op = request.get("operation")
    if op == "health":
        return environment()
    supplied_root = Path(request["root"])
    root = supplied_root.resolve(strict=True)
    if supplied_root.is_symlink() or (root.stat().st_mode & 0o077):
        raise ValueError("worker root permissions must be private")
    raw = base64.b64decode(request["manifest"], validate=True)
    secret = (root / ".worker-key").read_bytes()
    if not hmac.compare_digest(hmac.new(secret, raw, hashlib.sha256).hexdigest(), request["signature"]):
        raise ValueError("untrusted manifest")
    manifest = json.loads(raw)
    if op == "submit" and manifest["expiresAt"] <= time.time() * 1000:
        raise ValueError("authorization expired")
    if manifest["targetID"] != "local" or not 0 < manifest["runtimeSeconds"] <= 30:
        raise ValueError("scope violation")
    if manifest["workerHash"] != hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        raise ValueError("worker code drift")
    if op == "submit" and manifest["environmentFingerprint"] != environment()["fingerprint"]:
        raise ValueError("environment drift")
    run_id = manifest["runID"]
    if len(run_id) != 36 or any(c not in "0123456789abcdefABCDEF-" for c in run_id):
        raise ValueError("invalid run ID")
    directory = root / "runs" / run_id
    if (root / "runs").is_symlink() or directory.is_symlink():
        raise ValueError("symlink execution directory rejected")
    if op not in ("submit", "status", "cancel", "fetch"):
        raise ValueError("unsupported operation")
    if op == "submit":
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest_hash = hashlib.sha256(raw).hexdigest()
    lock = directory / "manifest.sha256"
    artifact = directory / "result.json"
    if lock.is_symlink() or artifact.is_symlink():
        raise ValueError("symlink artifact rejected")
    if lock.exists() and lock.read_text() != manifest_hash:
        raise ValueError("idempotency collision")
    claimed = lock.exists()
    if not claimed and op == "submit":
        fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(manifest_hash)
    if op == "status":
        return {"status": "succeeded" if artifact.exists() else "unknown"}
    if op == "cancel":
        return {"status": "succeeded" if artifact.exists() else "unknown"}
    if op not in ("submit", "fetch"):
        raise ValueError("unsupported operation")
    if not artifact.exists():
        if op == "fetch":
            raise ValueError("artifact unavailable")
        if claimed:
            raise ValueError("existing execution claim requires reconciliation")
        if manifest["batch"] != 1 or manifest["seed"] != 0 or manifest["steps"] != 0:
            raise ValueError("smoke budget exceeded")
        metrics = fit(manifest["points"], manifest["independent"])
        result = {"metrics": metrics, "samples": len(manifest["points"]), "batch": 1, "seed": 0,
                  "steps": 0, "exitCode": 0, "manifestHash": manifest_hash,
                  "workerHash": manifest["workerHash"], "environmentFingerprint": manifest["environmentFingerprint"],
                  "completedAt": time.time(), "independent": manifest["independent"]}
        temporary = directory / "result.pending"
        with open(temporary, "xb") as stream:
            stream.write(canonical(result))
        os.replace(temporary, artifact)
    result = json.loads(artifact.read_bytes())
    if result.get("manifestHash") != manifest_hash or result.get("workerHash") != manifest["workerHash"] or result.get("environmentFingerprint") != manifest["environmentFingerprint"]:
        raise ValueError("artifact provenance mismatch")
    result["artifactPath"] = str(artifact)
    result["artifactHash"] = hashlib.sha256(artifact.read_bytes()).hexdigest()
    return result

if __name__ == "__main__":
    try:
        print(json.dumps(main(), allow_nan=False))
    except Exception as exc:
        print(json.dumps({"error": type(exc).__name__ + ": " + str(exc)}))
        sys.exit(1)
