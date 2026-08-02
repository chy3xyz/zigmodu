#!/usr/bin/env python3
"""Local MCP client smoke: spawns examples/mcp-server and runs a real MCP
session (initialize, tools/list, tools/call) over stdio.

Usage: python3 scripts/mcp-client-test.py [path-to-mcp-server]
"""
import json
import subprocess
import sys

server_bin = sys.argv[1] if len(sys.argv) > 1 else "examples/mcp-server/zig-out/bin/mcp-server"

def call(proc, msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())

proc = subprocess.Popen(
    [server_bin],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
    bufsize=1,
)

try:
    r = call(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    assert r["result"]["protocolVersion"] == "2024-11-05", r
    print("initialize ok:", r["result"]["protocolVersion"])

    r = call(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    names = sorted(t["name"] for t in r["result"]["tools"])
    assert "kpi.query" in names and "ping" in names, names
    print("tools/list ok:", names)
    kpi = next(t for t in r["result"]["tools"] if t["name"] == "kpi.query")
    print("  kpi.query inputSchema.type:", kpi["inputSchema"]["type"])

    r = call(proc, {
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "kpi.query", "arguments": {"metric": "paid_revenue"}},
    })
    text = r["result"]["content"][0]["text"]
    assert '"value":5100' in text, text
    print("tools/call kpi.query:", text)

    r = call(proc, {
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": {"name": "ping", "arguments": {}},
    })
    print("tools/call ping:", r["result"]["content"][0]["text"])
finally:
    proc.stdin.close()
    proc.wait(timeout=10)

print("\nMCP session OK")
