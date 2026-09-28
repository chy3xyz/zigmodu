//! Shared DB driver link helpers for zigmodu / examples `build.zig`.
//! Build-scripts only — not part of the runtime library.

const std = @import("std");

pub const Features = struct {
    sqlite: bool = false,
    postgres: bool = false,
    mysql: bool = false,

    pub const all: Features = .{ .sqlite = true, .postgres = true, .mysql = true };
    pub const sqlite_only: Features = .{ .sqlite = true, .postgres = false, .mysql = false };

    pub fn any(self: Features) bool {
        return self.sqlite or self.postgres or self.mysql;
    }
};

pub const ParseError = error{InvalidDbOption};

/// Parse `-Ddb=` value: `all` | `sqlite` | `postgres` | `mysql` | comma-list.
pub fn parseDb(s: []const u8) ParseError!Features {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidDbOption;
    if (std.mem.eql(u8, trimmed, "all")) return Features.all;
    if (std.mem.eql(u8, trimmed, "none") or std.mem.eql(u8, trimmed, "off")) return .{};

    var features: Features = .{};
    var it = std.mem.splitScalar(u8, trimmed, ',');
    var saw_any = false;
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        saw_any = true;
        if (std.mem.eql(u8, part, "all")) {
            return Features.all;
        } else if (std.mem.eql(u8, part, "sqlite")) {
            features.sqlite = true;
        } else if (std.mem.eql(u8, part, "postgres") or std.mem.eql(u8, part, "postgresql") or std.mem.eql(u8, part, "pg")) {
            features.postgres = true;
        } else if (std.mem.eql(u8, part, "mysql") or std.mem.eql(u8, part, "mariadb")) {
            features.mysql = true;
        } else {
            return error.InvalidDbOption;
        }
    }
    if (!saw_any or !features.any()) return error.InvalidDbOption;
    return features;
}

pub fn addToOptions(options: *std.Build.Step.Options, features: Features) void {
    options.addOption(bool, "enable_sqlite", features.sqlite);
    options.addOption(bool, "enable_postgres", features.postgres);
    options.addOption(bool, "enable_mysql", features.mysql);
}

// -----------------------------------------------------------------
// Target / environment helpers
// -----------------------------------------------------------------

/// True when the build's target is the machine the build script runs on.
///
/// Compared on the resolved triple rather than `target.query.isNative()`, so an
/// explicit `-Dtarget=aarch64-macos` on an aarch64 Mac is still a host build,
/// while anything with a foreign arch/os/abi is not — and must never be handed
/// the build machine's `-I`/`-L`: those directories hold the host's own objects,
/// so a foreign link gets `/opt/homebrew/opt/mysql`'s `libmysqlclient.a` (a
/// Mach-O archive) and answers with one "undefined symbol" per symbol in it.
fn isHostTarget(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = b.graph.host.result;
    return target.result.cpu.arch == host.cpu.arch and
        target.result.os.tag == host.os.tag and
        target.result.abi == host.abi;
}

/// The **target's** root — a sysroot or a distro rootfs — or null when none was
/// named. `ZENT_XROOT` is the zent-prefixed spelling of the same variable, so a
/// build that already sets it for zent does not have to set it twice.
fn crossRoot(b: *std.Build) ?[]const u8 {
    return envValue(b, "XCOMPILE_ROOT") orelse envValue(b, "ZENT_XROOT");
}

/// `getenv` for a build script, with an empty value treated as unset: the
/// `XCOMPILE_ROOT=` line a wrapper script leaves behind means "unset", not "/".
/// The returned slice is owned by the build graph and outlives the script.
fn envValue(b: *std.Build, name: []const u8) ?[]const u8 {
    const value = b.graph.environ_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

/// The GNU multiarch triple for `arch` — the directory Debian and Ubuntu keep
/// their libraries in (`/usr/lib/aarch64-linux-gnu`). Null for an arch whose
/// spelling this does not know: the plain `usr/lib` candidates are searched
/// either way, so an unknown triple costs a directory, not the build.
fn multiarchTriple(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .aarch64, .aarch64_be => "aarch64-linux-gnu",
        .x86_64 => "x86_64-linux-gnu",
        .arm, .armeb, .thumb, .thumbeb => "arm-linux-gnueabihf",
        .riscv64 => "riscv64-linux-gnu",
        else => null,
    };
}

fn dirExists(b: *std.Build, path: []const u8) bool {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{}) catch return false;
    return true;
}

/// Library directories to add as `-L`, kept in search order. Four is exactly
/// what `targetLibDirs` yields (multiarch `usr/lib`, multiarch `lib`,
/// `usr/lib64`, `usr/lib`); a host build fills one. A value type rather than an
/// allocation, so a detection never has to touch the build arena.
const LibDirs = struct {
    buf: [4][]const u8 = undefined,
    len: usize = 0,

    fn slice(self: *const LibDirs) []const []const u8 {
        return self.buf[0..self.len];
    }

    fn add(self: *LibDirs, dir: []const u8) void {
        self.buf[self.len] = dir;
        self.len += 1;
    }

    fn addIfExists(self: *LibDirs, b: *std.Build, dir: []const u8) void {
        if (dirExists(b, dir)) self.add(dir);
    }
};

/// The target's library directories inside `root`, in search order: the
/// multiarch spellings first, where Debian and Ubuntu put everything, then the
/// plain ones for RHEL/SUSE and hand-rolled rootfs. Only directories that exist
/// are added — a path the target does not have is noise in every verbose log,
/// and a directory the linker will not have either.
fn targetLibDirs(b: *std.Build, target: std.Build.ResolvedTarget, root: []const u8) LibDirs {
    var dirs: LibDirs = .{};
    if (multiarchTriple(target.result.cpu.arch)) |triple| {
        dirs.addIfExists(b, b.fmt("{s}/usr/lib/{s}", .{ root, triple }));
        dirs.addIfExists(b, b.fmt("{s}/lib/{s}", .{ root, triple }));
    }
    dirs.addIfExists(b, b.fmt("{s}/usr/lib64", .{root}));
    dirs.addIfExists(b, b.fmt("{s}/usr/lib", .{root}));
    return dirs;
}

/// The libraries and include directory found for one driver. `lib_name` is only
/// read for MySQL; every other driver keeps the default.
const CLibPaths = struct {
    include: ?[]const u8 = null,
    libs: LibDirs = .{},
    /// `mysqlclient` — today's hard-coded name and the fallback — or `mariadb`
    /// when the resolved directories hold only that one (see `mysqlLibName`).
    lib_name: []const u8 = "mysqlclient",
};

/// Which MySQL client library to link, read from the directories that were
/// resolved: `mysqlclient` (Homebrew's `mysql-client`, Debian's
/// `libmysqlclient-dev`) or `mariadb` (MariaDB Connector/C, Debian's
/// `libmariadb-dev`, whose `libmysqlclient` comes only from the `-dev-compat`
/// package). Falls back to `mysqlclient` when the files cannot be read — that
/// is the name the host has always linked, and a missing file is not an answer.
fn mysqlLibName(b: *std.Build, libs: *const LibDirs) []const u8 {
    if (mysqlLibPresent(b, libs, "mysqlclient")) return "mysqlclient";
    if (mysqlLibPresent(b, libs, "mariadb")) return "mariadb";
    return "mysqlclient";
}

fn mysqlLibPresent(b: *std.Build, libs: *const LibDirs, name: []const u8) bool {
    const exts = [_][]const u8{ "so", "so.3", "dylib", "a" };
    for (libs.slice()) |dir| {
        for (exts) |ext| {
            if (dirExists(b, b.fmt("{s}/lib{s}.{s}", .{ dir, name, ext }))) return true;
        }
    }
    return false;
}

/// `-I`/`-L` for libpq: an explicit override for **any** target (it describes
/// one install), then the target's own root, and only then the build host — that
/// last one reachable only when `target` is the host.
fn detectPqPaths(b: *std.Build, target: std.Build.ResolvedTarget) CLibPaths {
    if (envValue(b, "PQ_INCLUDE")) |inc| {
        var paths: CLibPaths = .{ .include = inc };
        if (envValue(b, "PQ_LIB")) |lib| paths.libs.add(lib);
        return paths;
    }

    if (crossRoot(b)) |root| {
        var paths: CLibPaths = .{ .libs = targetLibDirs(b, target, root) };
        const layouts = [_][]const u8{ "/usr/include/postgresql", "/usr/include/pgsql" };
        for (layouts) |layout| {
            if (dirExists(b, b.fmt("{s}{s}/libpq-fe.h", .{ root, layout }))) {
                paths.include = b.fmt("{s}{s}", .{ root, layout });
                return paths;
            }
        }
        if (dirExists(b, b.fmt("{s}/usr/include/libpq-fe.h", .{root}))) {
            paths.include = b.fmt("{s}/usr/include", .{root});
        }
        return paths;
    }

    if (!isHostTarget(b, target)) return .{};

    const host_target = target.result;
    var paths: CLibPaths = .{};
    if (host_target.os.tag == .macos) {
        if (dirExists(b, "/opt/homebrew/opt/libpq")) {
            paths.include = "/opt/homebrew/opt/libpq/include";
            paths.libs.add("/opt/homebrew/opt/libpq/lib");
            return paths;
        }
        if (dirExists(b, "/usr/local/opt/libpq")) {
            paths.include = "/usr/local/opt/libpq/include";
            paths.libs.add("/usr/local/opt/libpq/lib");
            return paths;
        }
    } else if (host_target.os.tag == .linux) {
        const lib_dir = if (host_target.cpu.arch == .aarch64) "/usr/lib/aarch64-linux-gnu" else "/usr/lib/x86_64-linux-gnu";
        const candidates = &[_][]const u8{
            "/usr/include/postgresql",
            "/usr/include/pgsql",
            "/usr/pgsql/include",
        };
        for (candidates) |c| {
            if (dirExists(b, c)) {
                paths.include = c;
                paths.libs.add(lib_dir);
                return paths;
            }
        }
    }
    return paths;
}

/// `-I`/`-L` for the MySQL/MariaDB client: same precedence as libpq — override,
/// the target's root, then the host (host targets only).
fn detectMysqlPaths(b: *std.Build, target: std.Build.ResolvedTarget) CLibPaths {
    if (envValue(b, "MYSQL_INCLUDE")) |inc| {
        var paths: CLibPaths = .{ .include = inc };
        if (envValue(b, "MYSQL_LIB")) |lib| paths.libs.add(lib);
        paths.lib_name = mysqlLibName(b, &paths.libs);
        return paths;
    }

    if (crossRoot(b)) |root| {
        var paths: CLibPaths = .{ .libs = targetLibDirs(b, target, root) };
        // The `mariadb/` layout is the one `<mariadb/mysql.h>` resolves against,
        // so its include dir is the parent; `mysql/` and the bare header each
        // want the directory that contains them.
        if (dirExists(b, b.fmt("{s}/usr/include/mariadb/mysql.h", .{root}))) {
            paths.include = b.fmt("{s}/usr/include", .{root});
        } else if (dirExists(b, b.fmt("{s}/usr/include/mysql/mysql.h", .{root}))) {
            paths.include = b.fmt("{s}/usr/include/mysql", .{root});
        } else if (dirExists(b, b.fmt("{s}/usr/include/mysql.h", .{root}))) {
            paths.include = b.fmt("{s}/usr/include", .{root});
        }
        paths.lib_name = mysqlLibName(b, &paths.libs);
        return paths;
    }

    if (!isHostTarget(b, target)) return .{};

    const host_target = target.result;
    var paths: CLibPaths = .{};
    if (host_target.os.tag == .macos) {
        const prefixes = &[_][]const u8{
            "/opt/homebrew/opt/mariadb-connector-c",
            "/usr/local/opt/mariadb-connector-c",
            "/opt/homebrew/opt/mysql-client",
            "/usr/local/opt/mysql-client",
            "/opt/homebrew/opt/mysql",
            "/usr/local/opt/mysql",
        };
        for (prefixes) |prefix| {
            if (dirExists(b, prefix)) {
                paths.libs.add(b.fmt("{s}/lib", .{prefix}));
                // Prefer mariadb include layout when present.
                const maria_inc = b.fmt("{s}/include/mariadb", .{prefix});
                if (dirExists(b, maria_inc)) {
                    paths.include = maria_inc;
                } else {
                    const mysql_inc = b.fmt("{s}/include/mysql", .{prefix});
                    paths.include = if (dirExists(b, mysql_inc)) mysql_inc else b.fmt("{s}/include", .{prefix});
                }
                paths.lib_name = mysqlLibName(b, &paths.libs);
                return paths;
            }
        }
    } else if (host_target.os.tag == .linux) {
        const lib_dir = if (host_target.cpu.arch == .aarch64) "/usr/lib/aarch64-linux-gnu" else "/usr/lib/x86_64-linux-gnu";
        const candidates = &[_][]const u8{
            "/usr/include/mariadb",
            "/usr/include/mysql",
            "/usr/local/include/mariadb",
        };
        for (candidates) |c| {
            if (dirExists(b, c)) {
                paths.include = c;
                paths.libs.add(lib_dir);
                paths.lib_name = mysqlLibName(b, &paths.libs);
                return paths;
            }
        }
    }
    return paths;
}

/// sqlite3 lives on the default search paths of macOS/Linux hosts, so there is
/// nothing to detect there. Everything here is for **cross-compiling**:
/// `SQLITE_LIB` (plus `SQLITE_INCLUDE` when wanted) points at the *target*
/// ABI's `libsqlite3.{so,a}`, and `XCOMPILE_ROOT`/`ZENT_XROOT` names the
/// target's root, whose `usr/include` and library directories are searched.
/// Without one of those a cross build fails with
/// `unable to find dynamic system library 'sqlite3' using strategy 'paths_first'`,
/// because Zig searches the target's default paths, not the host's Homebrew ones.
fn detectSqlitePaths(b: *std.Build, target: std.Build.ResolvedTarget) CLibPaths {
    if (envValue(b, "SQLITE_INCLUDE")) |inc| {
        var paths: CLibPaths = .{ .include = inc };
        if (envValue(b, "SQLITE_LIB")) |lib| paths.libs.add(lib);
        return paths;
    }
    if (envValue(b, "SQLITE_LIB")) |lib| {
        var paths: CLibPaths = .{};
        paths.libs.add(lib);
        return paths;
    }
    if (crossRoot(b)) |root| {
        var paths: CLibPaths = .{ .libs = targetLibDirs(b, target, root) };
        if (dirExists(b, b.fmt("{s}/usr/include/sqlite3.h", .{root}))) {
            paths.include = b.fmt("{s}/usr/include", .{root});
        }
        return paths;
    }
    return .{};
}

/// Set once per `zig build` invocation: `link` is called once per module, and
/// the warning is about the build, not one module.
var warned_cross_without_root = false;

/// Say so, once, when a cross build has nowhere to look. Silence would read as
/// "the host's drivers were used", when the truth is "host discovery was
/// skipped by design" — and the link failure that follows names none of that.
fn warnCrossWithoutRoot(b: *std.Build, target: std.Build.ResolvedTarget, features: Features) void {
    if (!features.any()) return;
    if (isHostTarget(b, target)) return;
    if (crossRoot(b) != null) return;
    if (hasDriverOverride(b)) return;
    if (warned_cross_without_root) return;
    warned_cross_without_root = true;
    std.log.warn(
        "cross-compiling for {s}-{s}: skipping host driver discovery (Homebrew, /usr/include), whose paths hold the build machine's own libraries. Set XCOMPILE_ROOT (or ZENT_XROOT) to the target's root — a sysroot or a distro rootfs — or point PQ_INCLUDE/PQ_LIB, MYSQL_INCLUDE/MYSQL_LIB and SQLITE_INCLUDE/SQLITE_LIB at the target's headers and libraries.",
        .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
    );
}

fn hasDriverOverride(b: *std.Build) bool {
    const names = [_][]const u8{ "PQ_INCLUDE", "PQ_LIB", "MYSQL_INCLUDE", "MYSQL_LIB", "SQLITE_INCLUDE", "SQLITE_LIB" };
    for (names) |name| {
        if (envValue(b, name) != null) return true;
    }
    return false;
}

/// `linkSystemLibrary` options. pkg-config describes the **build machine**
/// (Homebrew's `mysqlclient.pc` names `/opt/homebrew/Cellar/mysql/…`) and Zig
/// consults it whatever the target is — so on a foreign target it is turned
/// off, or it hands the link the host's own `-I`/`-L` through a door the
/// `detect*Paths` gate does not close.
fn linkOpts(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.Module.LinkSystemLibraryOptions {
    return .{ .use_pkg_config = if (isHostTarget(b, target)) .yes else .no };
}

fn addPaths(mod: *std.Build.Module, paths: CLibPaths) void {
    if (paths.include) |inc| {
        mod.addSystemIncludePath(.{ .cwd_relative = inc });
    }
    for (paths.libs.slice()) |lib| {
        mod.addLibraryPath(.{ .cwd_relative = lib });
    }
}

/// Link only the drivers enabled in `features`.
///
/// `target` is the caller's own (`b.standardTargetOptions` result) and decides
/// whether the build machine's paths may be used at all.
pub fn link(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget, features: Features) void {
    warnCrossWithoutRoot(b, target, features);
    const opts = linkOpts(b, target);

    if (features.postgres) {
        addPaths(mod, detectPqPaths(b, target));
        mod.linkSystemLibrary("pq", opts);
    }

    if (features.mysql) {
        const mysql = detectMysqlPaths(b, target);
        addPaths(mod, mysql);
        mod.linkSystemLibrary(mysql.lib_name, opts);
    }

    if (features.sqlite) {
        addPaths(mod, detectSqlitePaths(b, target));
        mod.linkSystemLibrary("sqlite3", opts);
    }
}

/// Like `link`, but postgres/mysql are linked only when their headers are
/// actually detected. Use for modules (e.g. zent's exported module) whose C
/// bindings are wired conditionally by their own build script: linking an
/// absent library would fail on machines without it.
pub fn linkDetected(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget, features: Features) void {
    warnCrossWithoutRoot(b, target, features);
    const opts = linkOpts(b, target);

    if (features.postgres) {
        const pq = detectPqPaths(b, target);
        if (pq.include != null) {
            addPaths(mod, pq);
            mod.linkSystemLibrary("pq", opts);
        }
    }

    if (features.mysql) {
        const mysql = detectMysqlPaths(b, target);
        if (mysql.include != null) {
            addPaths(mod, mysql);
            mod.linkSystemLibrary(mysql.lib_name, opts);
        }
    }

    if (features.sqlite) {
        addPaths(mod, detectSqlitePaths(b, target));
        mod.linkSystemLibrary("sqlite3", opts);
    }
}
