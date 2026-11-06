#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
# One known solved problem: five points, one batch, one seed, zero training steps.
# The second execution is the independent I1 reproduction, not another search.
/usr/bin/python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile

project = Path.cwd()
app = project / "artifacts/local/NORMA.app/Contents"
if not (app / "MacOS/NORMAResearchService").exists():
    raise SystemExit("Run zsh scripts/build-local.sh first")
root = Path(tempfile.mkdtemp(prefix="smoke-", dir=project / "artifacts/local"))
env = {k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR", "LANG") if k in os.environ}
env.update(NORMA_DATA_ROOT=str(root), NORMA_WORKER=str(app / "Resources/worker.py"))
result = subprocess.run([str(app / "MacOS/NORMAResearchService"), "--local-smoke"],
                        env=env, capture_output=True, text=True, timeout=45)
(root / "execution.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit("Local smoke failed; inspect " + str(root / "execution.log"))
state = json.loads((root / "smoke-report.json").read_text())
assert state["outcome"] == "smokeVerified" and state["modelCalls"] == 0
assert len(state["runs"]) == 2
assert state["authorization"]["maxModelCalls"] == 0
assert [(c["id"], c["status"]) for c in state["integrity"]] == [("I1", "pass"), ("I2", "pass"), ("I3", "unknown"), ("I4", "unknown")]
for run in state["runs"]:
    assert run["metrics"] == {"slope": 2, "intercept": 1, "mse": 0}
    payload = json.loads(Path(run["artifactPath"]).read_text())
    assert (payload["samples"], payload["batch"], payload["seed"], payload["steps"]) == (5, 1, 0, 0)
with sqlite3.connect(root / "research.sqlite") as database:
    objects = [json.loads(row[0]) for row in database.execute("SELECT payload FROM artifacts")]
    for artifact in objects:
        assert hashlib.sha256((root / "objects" / artifact["relativePath"]).read_bytes()).hexdigest() == artifact["hash"]
    assert database.execute("SELECT count(*) FROM evidence_edges").fetchone()[0] == 8
    assert database.execute("SELECT count(*) FROM outbox WHERE acknowledged=0").fetchone()[0] == 0
print("PASS: five-point analytic solution, independent rerun, evidence graph; zero model calls")
print(root)
PY
