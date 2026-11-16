#!/usr/bin/python3
import json
import os
import signal
import sys
import time

if sys.argv[1:] != ["app-server", "--stdio"]:
    sys.exit(64)

scenario = os.environ.get("FAKE_CODEX_SCENARIO", "normal")
pid_path = os.environ.get("FAKE_CODEX_PID_PATH")
record_path = os.environ.get("FAKE_CODEX_RECORD_PATH")
private_value = os.environ.get("FAKE_PRIVATE_VALUE", "fixture-identity")

def publish(path, text):
    # Readers poll for existence; os.replace never exposes a created-but-empty file.
    temporary = f"{path}.{os.getpid()}.tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(temporary, path)

if pid_path:
    publish(pid_path, str(os.getpid()))

if scenario == "malformed":
    os.write(1, b"{not-json}\n")
    time.sleep(0.05)
    sys.exit(0)
if scenario == "oversized":
    os.write(1, b"x" * 8192)
    time.sleep(0.05)
    sys.exit(0)
if scenario == "eof":
    sys.exit(0)
if scenario == "nonzero":
    sys.exit(7)
if scenario == "timeout":
    time.sleep(30)
    sys.exit(0)

records = []

def persist_records():
    if record_path:
        publish(record_path, json.dumps(records, separators=(",", ":")))

def emit(value, fragmented=False, prefix=None):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n"
    if prefix:
        payload = json.dumps(prefix, separators=(",", ":")).encode("utf-8") + b"\n" + payload
    if fragmented:
        split = max(1, len(payload) // 3)
        os.write(1, payload[:split])
        time.sleep(0.01)
        os.write(1, payload[split:])
    else:
        os.write(1, payload)

for line in sys.stdin:
    request = json.loads(line)
    records.append({"id": request.get("id"), "method": request.get("method")})
    persist_records()
    method = request.get("method")
    if method == "initialize":
        emit(
            {"id": request["id"], "result": {"userAgent": "fake", "platformFamily": "unix", "platformOs": "macos", "codexHome": "/tmp/fake"}},
            fragmented=True,
            prefix={"method": "account/rateLimits/updated", "params": {}},
        )
    elif method == "initialized":
        continue
    elif method == "account/read":
        emit({"id": request["id"], "result": {"account": {"type": "chatgpt", "email": private_value, "planType": "plus"}, "requiresOpenaiAuth": True}})
    elif method == "account/rateLimits/read":
        emit({
            "id": request["id"],
            "result": {
                "rateLimits": {
                    "limitId": "codex",
                    "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1800018000},
                    "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1800604800},
                },
                "rateLimitsByLimitId": {
                    "codex": {
                        "limitId": "codex",
                        "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1800018000},
                        "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1800604800},
                    }
                },
            },
        })
        os.write(2, private_value.encode("utf-8") + b"\n")

persist_records()
