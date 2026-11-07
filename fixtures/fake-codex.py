#!/usr/bin/python3
"""Protocol fixture only. Never authenticates or invokes a model."""
import json
import os
import sys

def emit(value):
    print(json.dumps(value), flush=True)

last_thread = {}
last_turn = {}
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request.get("method")
    if method == "thread/start":
        last_thread = request.get("params", {})
        emit({"id": request["id"], "result": {"thread": {"id": "fixture-thread"}}})
    elif method == "turn/start":
        last_turn = request.get("params", {})
        emit({"id": request["id"], "result": {"turn": {"id": "fixture-turn"}}})
        for total, thread in [(12, "fixture-thread"), (20, "fixture-thread"), (20, "fixture-thread"), (999, "another-thread")]:
            usage = {"inputTokens": total - 5, "outputTokens": 5, "totalTokens": total, "cachedInputTokens": 3, "reasoningOutputTokens": 2}
            emit({"method": "thread/tokenUsage/updated", "params": {"threadId": thread, "turnId": "fixture-turn", "tokenUsage": {"total": usage, "last": usage}}})
        emit({"method": "item/agentMessage/delta", "params": {"threadId": "fixture-thread", "delta": "fixture answer"}})
        status = "failed" if request.get("params", {}).get("model") == "fixture-failed" else "completed"
        emit({"method": "turn/completed", "params": {"threadId": "fixture-thread", "turn": {"id": "fixture-turn", "status": status}}})
    elif method == "test/languageRequests":
        emit({"id": request["id"], "result": {"thread": last_thread, "turn": last_turn}})
    elif method == "test/error":
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
