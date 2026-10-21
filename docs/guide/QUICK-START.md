# Quick Start

This guide walks through installing the toolchain, creating a zmodu application, wiring an HTTP endpoint, and preparing the service for production.

## 1. Prerequisites

zmodu requires **Zig 0.17.0** (matching `ZIG_VERSION` in `.github/workflows/ci.yml`).

Install Zig 0.17.0 using [zigup](https://github.com/marler8997/zigup) or download the official tarball from [ziglang.org](https://ziglang.org/download/):

```bash
zigup 0.17.0
zig version
# Expected: 0.17.0
```

If your application uses SQLite, PostgreSQL, or MySQL, install the corresponding C client libraries (optional when building with `-Ddb=none`):

```bash
# macOS
brew install sqlite3 libpq mariadb-connector-c

# Ubuntu / Debian
sudo apt-get install -y libsqlite3-dev libpq-dev libmariadb-dev libmariadb-dev-compat
```

## 2. Option A: Generate a Project with `zmodu` CLI

The fastest way to start a structured project is with the built-in `zmodu` CLI generator.

Build the CLI from the zmodu repository root:

```bash
zig build zmodu
```

Generate a complete modulith project from a SQL schema:

```bash
./zig-out/bin/zmodu scaffold \
  --sql examples/shopdemo/schema.sql \
  --name my_app \
  --out /tmp/my_app \
  --with-auth \
  --with-metrics
```

The generated project includes `build.zig`, `build.zig.zon`, `src/main.zig`, and domain modules under `src/modules/<name>/` (`model.zig`, `persistence.zig`, `service.zig`, `api.zig`, `module.zig`). See [CLI & Code Generation](./ZMODU_CLI_INTEGRATION.md) for all subcommands.

## 3. Option B: Create a Project Manually

### Project Layout

```text
myapp/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig
    └── modules/
        └── user/
            ├── module.zig
            └── api.zig
```

### Step 1: Configure `build.zig.zon`

Declare `zmodu` as a dependency. On the first `zig build`, Zig prints the expected `.fingerprint` value to copy into the manifest:

```zig
.{
    .name = .myapp,
    .version = "0.1.0",
    .fingerprint = 0x0, // Replace with the value suggested by `zig build`
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        // Local checkout:
        .zmodu = .{ .path = "../zmodu" },
        // Or fetch a tagged release with `zig fetch --save <url>`:
        // .zmodu = .{ .url = "git+https://github.com/chy3xyz/zmodu?ref=v0.42.0" },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

### Step 2: Configure `build.zig`

Use the `.db` option to link only the SQL drivers your application needs (`sqlite`, `postgres`, `mysql`, `none`, or `all`):

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const db_opt = b.option(
        []const u8,
        "db",
        "SQL drivers to link: all|sqlite|postgres|mysql|none",
    ) orelse "sqlite";

    const zmodu_dep = b.dependency("zmodu", .{
        .target = target,
        .optimize = optimize,
        .db = db_opt,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zmodu", zmodu_dep.module("zmodu"));

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run the application");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
```

### Step 3: Define a Module and Route Table

Create `src/modules/user/module.zig`:

```zig
const std = @import("std");
const zmodu = @import("zmodu");
const http = zmodu.http;

pub const UserModule = struct {
    pub const info = zmodu.api.Module{
        .name = "user",
        .description = "User management module",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("user module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("user module stopped", .{});
    }
};

pub const UserApi = struct {
    pub const module_name = "user";
    pub const nest = .{"users"};
    pub const State = @This();

    pub const routes = [_]http.RouteSpec(State){
        .{ .method = .GET, .path = "{id}", .handler = getUser, .meta = .{ .auth = .public } },
    };

    fn getUser(ctx: *http.Context, _: *State) !void {
        const id = try ctx.paramInt(i64, "id");
        try ctx.jsonStruct(200, .{ .id = id, .name = "alice" });
    }
};
```

### Step 4: Bootstrap the Application

Create `src/main.zig`:

```zig
const std = @import("std");
const zmodu = @import("zmodu");
const http = zmodu.http;
const user = @import("modules/user/module.zig");

pub const panic = zmodu.panicHook;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 1. Build and start the module graph.
    // Bind the builder to a variable first because builder methods take `*Self`.
    var b = zmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.withName("myapp").build(.{user.UserModule});
    defer app.deinit();

    try app.start();
    defer app.stop();

    // 2. Configure the HTTP server and production profile.
    var server = http.Server.init(io, allocator, 8080);
    defer server.deinit();

    var profile = http.ProductionProfileState.init(allocator);
    defer profile.deinit(allocator);
    try http.productionProfile(&server, .{
        .max_connections = 4096,
        .header_timeout_ms = 10_000,
    }, &profile);

    // 3. Mount module routes.
    var user_api = user.UserApi{};
    const AppState = struct {};
    var app_state = AppState{};
    var router = http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();

    var api_v1 = router.scope("/api/v1");
    try api_v1.mountAll(.{
        .{ .Mod = user.UserApi, .state = &user_api },
    });

    try server.start();
}
```

### Step 5: Build, Run, and Verify

```bash
zig build run
```

In another terminal, query the endpoints:

```bash
curl -s http://127.0.0.1:8080/api/v1/users/42
# {"id":42,"name":"alice"}

curl -s http://127.0.0.1:8080/health/live
# UP

curl -s http://127.0.0.1:8080/metrics | head -n 5
```

## 4. Production Checklist

Before deploying a service, verify these four items:

1. **Mount `productionProfile` before registering routes**: `Server.addRoute` snapshots global middleware at registration time. Calling `http.productionProfile` first enables connection limits (`max_connections`), slowloris protection (`header_timeout_ms`), `/metrics`, and `/health/*`.
2. **Install `panicHook`**: Export `pub const panic = zmodu.panicHook;` in `src/main.zig` so panic stack traces include the active `METHOD /path`.
3. **Run startup preflight checks**: Call `zmodu.Preflight.run(...)` at boot to reject missing environment variables, placeholder JWT secrets, unreachable databases, pending migrations, or clock skew.
4. **Terminate TLS at a gateway or sidecar**: Place Nginx or Envoy in front of the service. Reference configurations are in [`examples/production-deploy/`](../../examples/production-deploy/).

## 5. Common Commands

```bash
zig build                          # Compile the project
zig build run                      # Compile and run
zig build test                     # Run unit tests
zig build -Ddb=sqlite              # Link only SQLite
zig build -Doptimize=ReleaseSafe   # Production build with safety checks
zig fmt src/                       # Format source files
```

## Next Steps

- [Modulith Architecture](./MODULITH.md): Module boundaries and communication rules.
- [Domain Layers](./MODULE_LAYERS.md): Structuring `model`, `persistence`, `service`, and `api`.
- [Declarative Routing & Auth](../reference/ROUTE_TABLE.md): JWT authentication and RBAC permission gates.
- [SQLx Drivers](./SQLX_DRIVERS.md): Selective driver linking and cross-compilation.
