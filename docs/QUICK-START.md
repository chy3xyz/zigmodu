# ZigModu Quick Start

Get up and running with ZigModu in 5 minutes.

## Prerequisites

ZigModu tracks Zig's **development** API (`std.process.Init`, `std.Io.Mutex`,
…), so a stable Zig release will not compile it. Install the exact dev build
CI pins:

```bash
# https://ziglang.org/download/ · zigup: https://github.com/marler8997/zigup
zigup 0.17.0-dev.2151+2ec5523d5

# ziglang's mirrors garbage-collect old dev builds (they start returning 404),
# so the version above goes stale by design: `.github/workflows/ci.yml` →
# `ZIG_VERSION` is the source of truth.
# `brew install zig` installs a *stable* Zig → not usable for this repo.
```

Verify installation:
```bash
zig version
# Should show the value pinned in .github/workflows/ci.yml → ZIG_VERSION,
# e.g. 0.17.0-dev.2151+2ec5523d5
```

## Step 1: Create a Module

Create a new file `src/modules/user.zig`:

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

// `pub` matters: `main.zig` refers to it as `user.UserModule`.
pub const UserModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "user",
        .description = "User management module",
        .dependencies = &.{},  // No dependencies
    };

    pub fn init() !void {
        std.log.info("User module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("User module cleaned up", .{});
    }
};
```

## Step 2: Bootstrap Application

Create `src/main.zig`:

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

// Import your modules
const user = @import("modules/user.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Scan and register modules
    var modules = try zigmodu.scanModules(allocator, .{user.UserModule});
    defer modules.deinit();

    // Validate dependencies
    try zigmodu.validateModules(&modules);

    // Generate documentation (optional)
    try zigmodu.generateDocs(&modules, "modules.puml", allocator, io);

    // Build the application. Bind the builder first: its methods take `*Self`,
    // and a function-call temporary materialises as `*const` — so the chained
    // one-liner `zigmodu.builder(…).build(…)` does not compile.
    var b = zigmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.build(.{user.UserModule});
    defer app.deinit();

    // start() runs each module's init() in dependency order; stop() reverses it.
    try app.start();
    defer app.stop();

    std.log.info("Application started successfully!", .{});
}
```

## Step 3: Configure the Build

`build.zig.zon` — declare the dependency. The very first `zig build` rejects the
placeholder `.fingerprint` and prints the exact value to paste in:

```zig
.{
    .name = .myapp,                 // must be a valid Zig identifier
    .version = "0.1.0",
    .fingerprint = 0x0,             // ← paste the value `zig build` suggests
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        // Local checkout (what examples/basic uses — no `.hash` needed):
        .zigmodu = .{ .path = "../zigmodu" },
        // …or a tagged release; `zig fetch --save <url>` fills in `.hash`:
        // .zigmodu = .{ .url = "git+https://github.com/chy3xyz/zigmodu?ref=v0.25.0" },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

`build.zig` — the `.db` argument selects which SQL drivers get linked (the
default `all` links all three; full contract: `docs/SQLX_DRIVERS.md`):

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Which SQL drivers to link (default: sqlite only). `-Ddb=` overrides.
    const db_opt = b.option([]const u8, "db", "SQL drivers to link: all|sqlite|postgres|mysql (comma-list)") orelse "sqlite";

    const zigmodu_dep = b.dependency("zigmodu", .{
        .target = target,
        .optimize = optimize,
        .db = db_opt,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the app's tests");
    test_step.dependOn(&run_tests.step);
}
```

## Step 4: Run

```bash
# Build and run
zig build run

# Or just build
zig build

# Run tests
zig build test
```

Expected output (trimmed):
```
info: All module dependencies validated successfully (1 modules)
info: User module initialized
info: Application 'app' started successfully
info: Application started successfully!
```

## Going to production

Before the first deploy, do these four things:

Fragment — `server` / `allocator` come from your own `main` (runnable wiring:
[`examples/tenant-mgmt`](../examples/tenant-mgmt/)):

```zig
// 1) one call: backpressure + security middleware + /metrics + /health/*
var profile = zigmodu.http.ProductionProfileState.init(allocator);
defer profile.deinit(allocator);
try zigmodu.http.productionProfile(&server, .{
    .max_connections = 4096,
    .header_timeout_ms = 10_000,
}, &profile);            // ⚠️ before router.mountAll / server.addRoute

// 2) panic attribution (root file)
pub const panic = zigmodu.panicHook;
```

3. Refuse to boot when misconfigured — `zigmodu.Preflight.run(...)`
   checks required env, placeholder JWT secrets, DB reachability, pending
   migrations and clock skew (see `docs/BEST_PRACTICES.md`「上线前预检」).
4. TLS terminates at a sidecar/gateway — reference topology in
   [`../examples/production-deploy/`](../examples/production-deploy/).
5. Run under a supervisor (`Restart=always` / k8s `restartPolicy: Always`).

Read next: [`OBSERVABILITY.md`](OBSERVABILITY.md) (alerts + dashboard),
[`BEST_PRACTICES.md`](BEST_PRACTICES.md)「韧性」, [`ROUTE_TABLE.md`](ROUTE_TABLE.md) §7.4.

## What's Next?

| Tutorial | Description |
|----------|-------------|
| [Examples](../examples/) | More complete examples |
| [Best Practices](BEST_PRACTICES.md) | Architecture + JWT / auth checklist |
| [Declarative Routes](ROUTE_TABLE.md) | ComptimeRouter + catalog RBAC |
| [AGENTS.md](../AGENTS.md) | AI agent handbook |
| [API Reference](API.md) | Detailed API docs |
| [Architecture](ARCHITECTURE.md) | System design |

## Common Commands

```bash
# Development
zig build run          # Run application
zig build test         # Run tests
zig fmt                # Format code

# Production
zig build -Doptimize=ReleaseSafe  # Optimized build
zig build install                   # Install binary

# Documentation
zig build docs        # Generate docs
```

## Troubleshooting

**"error: module not found"**
- Ensure `build.zig.zon` has correct paths

**"error: circular dependency"**
- Check Module.info.dependencies

**"missing init/deinit"**
- Every module must implement both functions

For more help, see [CONTRIBUTING.md](../CONTRIBUTING.md) or open an issue.