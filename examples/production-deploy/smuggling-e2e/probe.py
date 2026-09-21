#!/usr/bin/env python3
"""Raw-socket client for the CL/TE smuggling topology.

Deliberately not `curl`: the payloads here are *malformed on purpose* (conflicting
`Content-Length` / `Transfer-Encoding`, a chunk-size line that reads as a request
line), and a client library that normalises requests would hide exactly the
disagreement this harness measures. One `sendall`, then read whatever comes back.

    python3 probe.py --host 127.0.0.1 --port 18080 --payload p.bin --label cl-te
    python3 probe.py --host 127.0.0.1 --port 18080 --check-free

`--check-free` exits 1 when something is already listening: a second listener on
the same port silently steals part of the traffic, and that failure mode looks
like a capability regression in the results below.
"""

import argparse
import json
import socket
import sys
import time


def check_free(host: str, port: int) -> int:
    s = socket.socket()
    s.settimeout(0.4)
    try:
        s.connect((host, port))
    except OSError:
        print(json.dumps({"port": port, "free": True}))
        return 0
    finally:
        s.close()
    print(json.dumps({"port": port, "free": False}))
    return 1


def send(host: str, port: int, payload: bytes, label: str, read_timeout: float) -> int:
    result = {
        "label": label,
        "responses": 0,
        "statuses": [],
        "bytes": 0,
        "error": None,
    }
    try:
        s = socket.create_connection((host, port), timeout=3.0)
    except OSError as exc:
        result["error"] = f"connect: {exc}"
        print(json.dumps(result))
        return 0

    s.settimeout(read_timeout)
    t0 = time.time()
    try:
        s.sendall(payload)
    except OSError as exc:
        result["error"] = f"send: {exc}"

    buf = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    except OSError as exc:
        result["error"] = result["error"] or f"recv: {exc}"
    finally:
        s.close()

    result["elapsed_ms"] = round((time.time() - t0) * 1000, 1)
    result["bytes"] = len(buf)
    for line in buf.split(b"\r\n"):
        if line.startswith(b"HTTP/1."):
            parts = line.split(b" ")
            if len(parts) >= 2:
                result["statuses"].append(parts[1].decode("ascii", "replace"))
    result["responses"] = len(result["statuses"])
    print(json.dumps(result))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--payload")
    ap.add_argument("--label", default="")
    ap.add_argument("--read-timeout", type=float, default=2.0)
    ap.add_argument("--check-free", action="store_true")
    args = ap.parse_args()

    if args.check_free:
        return check_free(args.host, args.port)

    if not args.payload:
        ap.error("--payload is required unless --check-free")
    with open(args.payload, "rb") as fh:
        payload = fh.read()
    return send(args.host, args.port, payload, args.label or args.payload, args.read_timeout)


if __name__ == "__main__":
    sys.exit(main())
