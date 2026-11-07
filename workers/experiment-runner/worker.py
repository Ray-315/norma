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
import ast
import resource
import subprocess
import threading
import signal
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

def generated_child():
    # OS sandbox is applied by the trusted parent before accepting model code.
    import statistics
    import random
    request = json.loads(sys.stdin.buffer.read(128 * 1024))
    code = request["python"]
    data = request["data"]
    if not isinstance(data, list) or not 1 <= len(data) <= 5 or len(code.encode()) > 64000:
        raise ValueError("实验超出已授权的五条数据范围")
    tree = ast.parse(code)
    modules = {"math": math, "statistics": statistics, "random": random}
    forbidden = {"open", "eval", "exec", "compile", "globals", "locals", "vars", "getattr", "setattr", "delattr", "input", "breakpoint", "help", "type", "object", "super", "memoryview"}
    for node in ast.walk(tree):
        if isinstance(node, (ast.ClassDef, ast.Global, ast.Nonlocal, ast.AsyncFunctionDef, ast.Await)):
            raise ValueError("不支持此实验语法")
        if isinstance(node, ast.Name) and (node.id.startswith("_") or node.id in forbidden):
            raise ValueError("实验引用了未允许的功能")
        if isinstance(node, ast.Attribute) and (node.attr.startswith("_") or node.attr in forbidden):
            raise ValueError("实验引用了未允许的属性")
        if isinstance(node, ast.Import) and any(n.name not in modules for n in node.names):
            raise ValueError("仅支持 math、statistics、random 标准库")
        if isinstance(node, ast.ImportFrom) and (node.level or node.module not in modules or any(n.name.startswith("_") or n.name == "*" for n in node.names)):
            raise ValueError("实验导入未获准")
    def safe_import(name, globals=None, locals=None, fromlist=(), level=0):
        if name not in modules or level:
            raise ValueError("实验导入未获准")
        return modules[name]
    safe = {name: __builtins__[name] if isinstance(__builtins__, dict) else getattr(__builtins__, name)
            for name in ("abs", "all", "any", "bool", "dict", "enumerate", "float", "int", "len", "list", "map", "max", "min", "pow", "range", "reversed", "round", "set", "sorted", "str", "sum", "tuple", "zip", "Exception", "ValueError", "ArithmeticError")}
    safe["__import__"] = safe_import
    scope = {"__builtins__": safe, **modules}
    random.seed(0)
    resource.setrlimit(resource.RLIMIT_CPU, (10, 10))
    resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    exec(compile(tree, "experiment.py", "exec"), scope)
    result = scope["run"](data)
    if not isinstance(result, dict) or not 1 <= len(result) <= 20 or any(not isinstance(k, str) or len(k) > 80 or isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for k, v in result.items()):
        raise ValueError("实验必须返回有限数值指标字典")
    return {"metrics": result}

def run_generated(manifest):
    # Model code gets neither authorization secrets nor access to user directories.
    script = str(Path(__file__).resolve())
    profile = '(version 1)(deny default)(allow process-exec)(allow sysctl-read)(allow mach-lookup)(allow signal (target self))(allow file-read-metadata)(allow file-read* (literal "/") (literal "/dev/urandom") (literal "/dev/random") (subpath "/System") (subpath "/usr") (subpath "/Library/Developer") (subpath "/Applications/Xcode.app") (subpath "/private/var/db/dyld") (literal "/dev/null") (literal ' + json.dumps(script) + '))'
    child = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile, sys.executable, "-I", "-B", script, "--generated-child"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env={"PATH": "/usr/bin:/bin", "LANG": "zh_CN.UTF-8"})
    stopped = threading.Event()
    exceeded = []
    def watch_memory():
        while not stopped.wait(0.05):
            measured = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(child.pid)], capture_output=True, timeout=2)
            if measured.stdout.strip() and int(measured.stdout.strip()) > 512 * 1024:
                exceeded.append(True)
                child.kill()
                return
    watchdog = threading.Thread(target=watch_memory, daemon=True)
    watchdog.start()
    def terminate_child(signum, frame):
        child.kill()
        child.wait(timeout=3)
        raise SystemExit(1)
    old_handler = signal.signal(signal.SIGTERM, terminate_child)
    try:
        output, errors = child.communicate(canonical({"python": manifest["python"], "data": manifest["data"]}), timeout=20)
    except subprocess.TimeoutExpired:
        child.kill()
        child.communicate()
        raise ValueError("实验超过 20 秒执行上限")
    finally:
        stopped.set()
        watchdog.join(timeout=3)
        signal.signal(signal.SIGTERM, old_handler)
    if exceeded:
        raise ValueError("实验超过 512 MB 内存上限")
    if child.returncode:
        raise ValueError("受限实验执行失败：" + (output + errors).decode(errors="replace")[:2000])
    value = json.loads(output)
    if manifest["metric"] not in value["metrics"]:
        raise ValueError("实验未返回约定的评价指标")
    return value["metrics"]

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
        generated = manifest.get("mode") == "generated"
        metrics = run_generated(manifest) if generated else fit(manifest["points"], manifest["independent"])
        result = {"metrics": metrics, "samples": len(manifest["data"] if generated else manifest["points"]), "batch": 1, "seed": 0,
                  "steps": 0, "exitCode": 0, "manifestHash": manifest_hash,
                  "workerHash": manifest["workerHash"], "environmentFingerprint": manifest["environmentFingerprint"],
                  "completedAt": time.time(), "independent": manifest["independent"]}
        if generated:
            result.update({"codeHash": hashlib.sha256(manifest["python"].encode()).hexdigest(), "dataHash": manifest["dataHash"], "planHash": manifest["planHash"]})
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
        print(json.dumps(generated_child() if sys.argv[1:] == ["--generated-child"] else main(), allow_nan=False))
    except Exception as exc:
        print(json.dumps({"error": type(exc).__name__ + ": " + str(exc)}))
        sys.exit(1)
