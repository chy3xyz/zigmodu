# HTTP Stress Test

Self-contained server + load generator: [`src/main.zig`](src/main.zig) starts an
`http.Server` (h2c enabled) and then hammers it with **32 concurrent clients ×
50 requests each** (1600 requests, a 1-in-3 `/ping` mix, the rest `/json`). No
external tool is required.

```bash
cd examples/http-stress-test
zig build run
```

The run ends with the report and fails the process (`error.TestFailed`) if any
request errored:

```
info: === Stress Test Results ===
info: Duration: 0.83s
info: Total requests: 1600
info: Completed: 1600
info: Errors: 0
info: Requests/sec: 1931.08
info: Success rate: 100.0%
info: Stress test PASSED - Server handled 1931.08 requests/sec
```

Throughput depends on the machine — treat the `Errors: 0` line as the assertion,
not the requests/sec number.

## Knobs

| Variable | Meaning |
|----------|---------|
| `HTTP_PORT` | Listen port (default `8080`) |
| `BENCH_HOLD=1` | Serve forever instead of running the built-in clients — for external benchmarks |

## Optional: external benchmark (wrk)

Only needed if you want a third-party load tool. Start the server in hold mode
and point the tool at it:

```bash
BENCH_HOLD=1 zig build run          # serves /json and /ping, prints its port
# in another shell:
wrk -t4 -c100 -d30s http://localhost:8080/json     # brew install wrk
```
