#!/usr/bin/python3
"""Protocol fixture only. Never authenticates or invokes a model."""
import json
import os
import sys

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request.get("method")
    if method == "test/error":
        emit({"id": request["id"], "error": {"code": -1, "message": "fixture error"}})
    elif method == "test/approval":
        emit({"id": "server-approval", "method": "item/commandExecution/requestApproval", "params": {}})
        decision = json.loads(sys.stdin.readline())
        emit({"id": request["id"], "result": {"declined": decision.get("result", {}).get("decision") == "decline"}})
    elif method == "test/environment":
        emit({"id": request["id"], "result": {
            "home": os.environ.get("CODEX_HOME"),
            "apiKeyInherited": "OPENAI_API_KEY" in os.environ,
            "sshAgentInherited": "SSH_AUTH_SOCK" in os.environ,
            "externalAuthInherited": "CODEX_THREAD_ID" in os.environ
        }})
    else:
        emit({"id": request["id"], "result": {}})
