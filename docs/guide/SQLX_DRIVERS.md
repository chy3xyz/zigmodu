# SQLx Selective Driver Linking (`-Ddb=` / `.db=`)

By default, zmodu links **SQLite + PostgreSQL + MySQL** (`-Ddb=all`) so the framework test suite can run against all drivers. Applications and examples should narrow `.db` to link only the drivers they use, or set `.db = "none"` when not using `data.sqlx`.

## 1. Configuring Package Dependencies

In your application's `build.zig`, pass `.db` to `b.dependency("zmodu", ...)`:

```zig
const zmodu_dep = b.dependency("zmodu", .{
    .target = target,
    .optimize = optimize,
    .db = "sqlite", // or "postgres" | "mysql" | "sqlite,postgres" | "none" | "all"
});
exe_mod.addImport("zmodu", zmodu_dep.module("zmodu"));
```

- Do not manually call `linkSystemLibrary("sqlite3")` in the consumer `build.zig`; zmodu's `build.zig` links the selected C libraries automatically.
- `enable_sqlite`, `enable_postgres`, and `enable_mysql` belong to zmodu's internal `build_options` module. Pass `.db` to `b.dependency("zmodu", ...)` rather than adding a custom `build_options` import.
- If your application uses `zent` or no SQL database, set `.db = "none"`. All three C driver headers are skipped and `data.sqlx` compiles against internal stubs.

## 2. Valid `.db` / `-Ddb=` Values

| Value | Linked Libraries |
|-------|------------------|
| `all` (default) | `libsqlite3` + `libpq` + `libmysqlclient` (or `libmariadb`) |
| `none` / `off` | None (uses C stubs; connecting returns `error.DriverNotEnabled`) |
| `sqlite` | `libsqlite3` |
| `postgres` / `postgresql` / `pg` | `libpq` |
| `mysql` / `mariadb` | `libmysqlclient` or `libmariadb` |
| Comma-separated list | e.g., `sqlite,postgres` |

Invalid values panic during build configuration (`invalid -Ddb=`).

## 3. Compile-Time and Runtime Behavior

| Layer | Behavior when Driver is Disabled |
|-------|----------------------------------|
| Linker | System library is not linked |
| C bindings | Uses `src/sqlx/{sqlite3,libpq,libmysql}_c_stub.zig` |
| Runtime | `Client.connect` returns `error.DriverNotEnabled` |
| HTTP | `ZmoduError.DriverNotEnabled` maps to `400 Bad Request` |
| Feature detection | `sqlx.DriverFeatures.isEnabled(driver)` returns `false` |

### Startup Verification (`expect_drivers`)

Declare required drivers in `Application.Config.expect_drivers` to fail fast during `app.start()` if the binary was built without the configured driver:

```zig
var app = try zmodu.Application.init(
    io,
    allocator,
    "shop",
    .{ OrderModule, PaymentModule },
    .{ .expect_drivers = &.{.postgres} },
);
```

## 4. Testing Conventions

| Target | Recommended `-Ddb=` |
|--------|---------------------|
| Framework `zig build test` | Keep default `all` |
| Application / Example builds | Narrow to actual driver (e.g., `-Ddb=sqlite`) |
| Windows cross-compile check | `zig build -Ddb=none -Dtarget=x86_64-windows` |

## 5. CLI Scaffolding Defaults

| Command | Generated `.db` in `build.zig` |
|---------|--------------------------------|
| `zmodu new <name>` | `sqlite` |
| `zmodu scaffold --sql ...` | `sqlite` |
| `zmodu scaffold --from-db postgres://...` | `postgres` |
| `zmodu scaffold --from-db mysql://...` | `mysql` |

## 6. Query Timeouts and Connection Pool Behavior

- **Socket read timeout (`Config.query_timeout_ms`)**: Defaults to `30000` ms (`0` falls back to `30000` ms). Applies `SO_RCVTIMEO` on PostgreSQL and MySQL sockets so synchronous `libpq` / `libmysqlclient` calls cannot hang a fiber indefinitely.
- **Connection pool wait (`ConnPool.acquire`)**: Uses 50 ms segmented waits up to `max_wait_ms` so pool shutdown or cancellation is observed promptly.

## 7. Cross-Compilation

Host include and library paths (Homebrew, `/usr/include`, `pkg-config`) are probed **only when `target` matches the build host**. When cross-compiling:

1. **Driver-free build**: Pass `-Ddb=none`.
2. **With SQL drivers**: Provide target-platform libraries via `XCOMPILE_ROOT` (or `ZENT_XROOT`) pointing to the target sysroot/rootfs, or set per-driver environment variables:

| Environment Variable | Driver | Description |
|----------------------|--------|-------------|
| `XCOMPILE_ROOT` / `ZENT_XROOT` | All | Target sysroot containing `usr/include` and `usr/lib/<multiarch>` |
| `SQLITE_INCLUDE` / `SQLITE_LIB` | SQLite | Target SQLite header and library directories |
| `PQ_INCLUDE` / `PQ_LIB` | PostgreSQL | Target `libpq` header and library directories |
| `MYSQL_INCLUDE` / `MYSQL_LIB` | MySQL | Target MySQL/MariaDB header and library directories |

### Example: Cross-Compiling from macOS (`aarch64`) to Linux (`aarch64-linux-gnu`)

```bash
# 1. Extract target libraries from a container or sysroot
docker run --rm -v /tmp/sqlite-linux:/out debian:bookworm-slim \
  sh -c 'cp -L /usr/lib/$(uname -m)-linux-gnu/libsqlite3.so.0* /out/'

# 2. Build for a glibc target (specify the glibc version matching the target library)
SQLITE_LIB=/tmp/sqlite-linux zig build \
  -Dtarget=aarch64-linux-gnu.2.34 \
  -Ddb=sqlite \
  -Doptimize=ReleaseSmall \
  -p /tmp/out
```

### Cross-Compilation Guidelines

- Always pass `-p <output-dir>` when cross-compiling so foreign ELF binaries do not overwrite host binaries in `zig-out/bin/`.
- Clear `.zig-cache` if you change `XCOMPILE_ROOT` or `*_LIB` environment variables between builds.
- On memory-constrained CI runners, use `-Doptimize=ReleaseSmall` (~420 MiB peak RSS) or `Debug` (~270 MiB) with `-j2 --maxrss 1G --skip-oom-steps`, and compile the library/binary step rather than the full `test` target (~1 GiB).
