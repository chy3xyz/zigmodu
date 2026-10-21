# AI Package Boundary (`src/ai/`)

Applies to: zmodu v0.20.1+ · Gate: `src/test/AiBoundary.zig`

`src/ai/` is an optional subsystem (~12k lines) designed so it can be extracted into a standalone package. `src/test/AiBoundary.zig` enforces two directional import rules on every `zig build test` run:

1. **Core never imports `src/ai/`**: No file under `src/{core,api,data,sqlx,http,security,messaging,runtime}` may `@import` any file in `src/ai/`. The single top-level re-export in `src/root.zig` is the only entry point.
2. **`src/ai/` only imports domain seams**: Files inside `src/ai/` may only import approved domain barrels and seams:
   - `data.zig` (never `sqlx/sqlx.zig` or `persistence/backends/**` directly; both baselines are frozen at `0`)
   - `http.zig` and `http/Sse.zig`
   - `runtime.zig` (used by `src/ai/agent_worker.zig` to run an `Agent` as a runtime worker)
   - `core/`, `messaging/`, `scheduler/`, `resilience/`, `tracing/`, `redis/`, `api/`, `security/`, `test/`

```zig
// Disallowed in src/ai/:
// const sqlx = @import("../sqlx/sqlx.zig");

// Required: import through the domain barrel
const data = @import("../data.zig");
```

Any new import outside the allowlist in `src/test/AiBoundary.zig` fails the test suite with `error.AiBoundaryViolation`.
