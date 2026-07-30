#!/usr/bin/env python3
"""Compare HTTP/1.1 keep-alive vs h2c prior-knowledge on the same ZigModu server."""

from __future__ import annotations

import argparse
import socket
import statistics
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import (
    DataReceived,
    ResponseReceived,
    StreamEnded,
    StreamReset,
    WindowUpdated,
)


def http11_once(host: str, port: int, path: str, keepalive: bool) -> float:
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        f"Connection: {'keep-alive' if keepalive else 'close'}\r\n"
        f"\r\n"
    ).encode()
    t0 = time.perf_counter()
    with socket.create_connection((host, port), timeout=5) as s:
        s.sendall(req)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        # Content-Length body
        header, _, rest = buf.partition(b"\r\n\r\n")
        cl = 0
        for line in header.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                cl = int(line.split(b":", 1)[1].strip())
        while len(rest) < cl:
            chunk = s.recv(4096)
            if not chunk:
                break
            rest += chunk
    return time.perf_counter() - t0


def http11_pipeline_conn(host: str, port: int, path: str, n: int) -> tuple[float, int]:
    """Many requests on one keep-alive connection (serialized)."""
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        f"Connection: keep-alive\r\n"
        f"\r\n"
    ).encode()
    ok = 0
    t0 = time.perf_counter()
    with socket.create_connection((host, port), timeout=10) as s:
        s.settimeout(10)
        for _ in range(n):
            s.sendall(req)
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = s.recv(4096)
                if not chunk:
                    raise RuntimeError("conn closed mid-response")
                buf += chunk
            header, _, rest = buf.partition(b"\r\n\r\n")
            cl = 0
            for line in header.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    cl = int(line.split(b":", 1)[1].strip())
            while len(rest) < cl:
                chunk = s.recv(4096)
                if not chunk:
                    raise RuntimeError("conn closed mid-body")
                rest += chunk
            # leftover for next response should be empty for CL responses
            if not header.startswith(b"HTTP/1.1 200"):
                raise RuntimeError(header.split(b"\r\n", 1)[0].decode())
            ok += 1
    return time.perf_counter() - t0, ok


def h2c_multiplex(host: str, port: int, path: str, n: int, concurrency: int) -> tuple[float, int]:
    """One h2c prior-knowledge connection, up to `concurrency` streams in flight."""
    conf = H2Configuration(client_side=True, header_encoding="utf-8")
    conn = H2Connection(config=conf)
    conn.initiate_connection()

    sock = socket.create_connection((host, port), timeout=10)
    sock.settimeout(10)
    # prior knowledge: send preface + settings immediately
    sock.sendall(conn.data_to_send())

    done = 0
    in_flight: dict[int, bytearray] = {}
    pending = n
    t0 = time.perf_counter()

    def open_streams():
        nonlocal pending
        while pending > 0 and len(in_flight) < concurrency:
            sid = conn.get_next_available_stream_id()
            conn.send_headers(
                sid,
                [
                    (":method", "GET"),
                    (":authority", f"{host}:{port}"),
                    (":scheme", "http"),
                    (":path", path),
                ],
                end_stream=True,
            )
            in_flight[sid] = bytearray()
            pending -= 1
        data = conn.data_to_send()
        if data:
            sock.sendall(data)

    open_streams()
    while done < n:
        data = sock.recv(65535)
        if not data:
            break
        events = conn.receive_data(data)
        for ev in events:
            if isinstance(ev, DataReceived):
                in_flight.get(ev.stream_id, bytearray()).extend(ev.data)
                conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
            elif isinstance(ev, StreamEnded):
                in_flight.pop(ev.stream_id, None)
                done += 1
                open_streams()
            elif isinstance(ev, StreamReset):
                in_flight.pop(ev.stream_id, None)
                done += 1
                open_streams()
            elif isinstance(ev, WindowUpdated):
                pass
            elif isinstance(ev, ResponseReceived):
                pass
        out = conn.data_to_send()
        if out:
            sock.sendall(out)

    elapsed = time.perf_counter() - t0
    sock.close()
    return elapsed, done


def h2c_serial(host: str, port: int, path: str, n: int) -> tuple[float, int]:
    return h2c_multiplex(host, port, path, n, concurrency=1)


def pct(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    ys = sorted(xs)
    i = min(len(ys) - 1, max(0, int(round((p / 100.0) * (len(ys) - 1)))))
    return ys[i]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18088)
    ap.add_argument("--path", default="/ping")
    ap.add_argument("--requests", type=int, default=2000)
    ap.add_argument("--warmup", type=int, default=50)
    ap.add_argument("--h2-concurrency", type=int, default=32)
    ap.add_argument("--parallel-conns", type=int, default=16)
    args = ap.parse_args()

    host, port, path = args.host, args.port, args.path

    print(f"target http://{host}:{port}{path}")
    print(f"requests={args.requests} warmup={args.warmup} h2_concurrency={args.h2_concurrency}")
    print()

    # warmup
    for _ in range(args.warmup):
        http11_once(host, port, path, keepalive=False)
    try:
        h2c_serial(host, port, path, 5)
    except Exception as e:
        print(f"h2c warmup failed: {e}")
        print("Is the server running with setHttp2Enabled(true)?")
        raise SystemExit(1)

    # 1) cold connection latency (new TCP each time)
    samples_h1 = [http11_once(host, port, path, keepalive=False) for _ in range(100)]
    samples_h2 = []
    for _ in range(100):
        t, ok = h2c_serial(host, port, path, 1)
        if ok != 1:
            raise RuntimeError("h2 single failed")
        samples_h2.append(t)

    def lat_line(name: str, xs: list[float]) -> None:
        print(
            f"{name:28} avg={statistics.mean(xs)*1000:7.2f}ms  "
            f"p50={pct(xs,50)*1000:7.2f}ms  p99={pct(xs,99)*1000:7.2f}ms"
        )

    print("=== Latency: new connection per request (n=100) ===")
    lat_line("HTTP/1.1 Connection:close", samples_h1)
    lat_line("h2c prior-knowledge (1 stream)", samples_h2)
    print()

    # 2) single-connection throughput
    n = args.requests
    t1, ok1 = http11_pipeline_conn(host, port, path, n)
    t2, ok2 = h2c_serial(host, port, path, n)
    t3, ok3 = h2c_multiplex(host, port, path, n, concurrency=args.h2_concurrency)
    print(f"=== Throughput: single TCP connection ({n} requests) ===")
    print(f"{'HTTP/1.1 keep-alive serial':28} ok={ok1}  {ok1/t1:8.0f} req/s  ({t1:.3f}s)")
    print(f"{'h2c serial (conc=1)':28} ok={ok2}  {ok2/t2:8.0f} req/s  ({t2:.3f}s)")
    print(f"{'h2c multiplex':28} ok={ok3}  {ok3/t3:8.0f} req/s  ({t3:.3f}s)")
    print()

    # 3) many parallel connections (more like wrk)
    per = max(1, n // args.parallel_conns)

    def h1_worker(_: int) -> tuple[float, int]:
        return http11_pipeline_conn(host, port, path, per)

    def h2_worker(_: int) -> tuple[float, int]:
        return h2c_multiplex(host, port, path, per, concurrency=min(8, args.h2_concurrency))

    def run_pool(fn, label: str) -> None:
        t0 = time.perf_counter()
        ok = 0
        with ThreadPoolExecutor(max_workers=args.parallel_conns) as ex:
            futs = [ex.submit(fn, i) for i in range(args.parallel_conns)]
            for f in as_completed(futs):
                _, k = f.result()
                ok += k
        elapsed = time.perf_counter() - t0
        print(f"{label:28} ok={ok}  {ok/elapsed:8.0f} req/s  ({elapsed:.3f}s, {args.parallel_conns} conns)")

    print(f"=== Throughput: {args.parallel_conns} parallel connections × {per} req ===")
    run_pool(h1_worker, "HTTP/1.1 keep-alive")
    run_pool(h2_worker, "h2c multiplex")


if __name__ == "__main__":
    main()
