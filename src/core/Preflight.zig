//! Startup preflight — turn "it broke at 3am" into "it refused to start".
//!
//! Production failures are rarely subtle at the moment they happen; they are
//! subtle *before* it: a missing environment variable, a placeholder JWT
//! secret, a database that is not reachable, migrations not applied, a clock
//! that is years off. Each is cheap to detect at boot and expensive to debug
//! in production. Run the checks, log the report, and refuse to serve when
//! something fatal is wrong:
//!
//! ```zig
//! var report = zigmodu.Preflight.run(allocator, &.{
//!     zigmodu.Preflight.envCheck(&env_ctx),
//!     zigmodu.Preflight.secretCheck(&secret_ctx),
//!     zigmodu.Preflight.dbCheck(&db_client),
//!     zigmodu.Preflight.clockCheck(),
//! });
//! defer report.deinit(allocator);
//! report.log();
//! if (!report.ok()) return error.PreflightFailed;
//! ```
//!
//! Checks never panic and never abort: a failure is counted and (allocation
//! permitting) recorded as a finding with a message, so one broken probe cannot
//! hide the others. The counter is bumped before the finding is formatted, so
//! memory pressure cannot talk `ok()` out of a fatal failure; what it can cost
//! is the finding's own line, and `log()` reports that gap.

const std = @import("std");
const Time = @import("Time.zig");

pub const Severity = enum { warn, fatal };

/// One probe. `run` returns an error to fail the check; the error name becomes
/// the finding message.
pub const Check = struct {
    name: []const u8,
    severity: Severity = .fatal,
    run: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!void,
    ctx: ?*anyopaque = null,
};

pub const Finding = struct {
    name: []const u8,
    severity: Severity,
    message: []const u8,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    findings: std.ArrayList(Finding) = .empty,
    passed: usize = 0,
    warnings: usize = 0,
    failures: usize = 0,

    /// True when nothing fatal was found. Warnings do not block startup.
    pub fn ok(self: *const Report) bool {
        return self.failures == 0;
    }

    pub fn deinit(self: *Report) void {
        for (self.findings.items) |f| {
            self.allocator.free(f.name);
            self.allocator.free(f.message);
        }
        self.findings.deinit(self.allocator);
        self.* = undefined;
    }

    /// One line per finding, then a summary — meant for the startup log.
    pub fn log(self: *const Report) void {
        for (self.findings.items) |f| {
            switch (f.severity) {
                .fatal => std.log.err("[preflight] {s}: {s}", .{ f.name, f.message }),
                .warn => std.log.warn("[preflight] {s}: {s}", .{ f.name, f.message }),
            }
        }
        // Findings are counted before they are formatted, so the counters can
        // outrun the lines above. Say so instead of printing a total the list
        // does not add up to.
        if (self.findings.items.len < self.failures + self.warnings) {
            std.log.err("[preflight] {d} finding(s) could not be recorded (out of memory)", .{
                self.failures + self.warnings - self.findings.items.len,
            });
        }
        if (self.ok()) {
            std.log.info("[preflight] {d} checks passed, {d} warning(s)", .{ self.passed, self.warnings });
        } else {
            std.log.err("[preflight] {d} check(s) failed — refusing to start", .{self.failures});
        }
    }
};

/// Run every check and collect findings.
///
/// A check that reports an error is counted the moment it does — before its
/// finding is formatted. `ok()` is the value the caller acts on (the header
/// example refuses to start on it), so it must not depend on whether the report
/// could be allocated: a failed probe that vanishes under memory pressure would
/// have `ok()` say "nothing fatal" about a run that had a fatal failure. What
/// memory pressure *can* cost is the finding's own strings — `log()` reports
/// that gap rather than printing a count no finding backs.
pub fn run(allocator: std.mem.Allocator, checks: []const Check) Report {
    var report = Report{ .allocator = allocator };
    for (checks) |check| {
        check.run(check.ctx, allocator) catch |err| {
            if (check.severity == .fatal) report.failures += 1 else report.warnings += 1;
            const message = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch continue;
            const name_copy = allocator.dupe(u8, check.name) catch {
                allocator.free(message);
                continue;
            };
            report.findings.append(allocator, .{
                .name = name_copy,
                .severity = check.severity,
                .message = message,
            }) catch {
                allocator.free(name_copy);
                allocator.free(message);
            };
            continue;
        };
        report.passed += 1;
    }
    return report;
}

// ── Ready-made checks ───────────────────────────────────────────────────────

pub const EnvCheck = struct {
    /// Backing store for `get` (typically `*const std.process.Environ`).
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, name: []const u8) ?[]const u8,
    /// Variables that must be set and non-empty.
    required: []const []const u8,

    /// Accepted form: **a pointer** to anything with `get(name) ?[]const u8`.
    /// `init.environ_map` (a `*Environ.Map`) and `*std.process.Environ` both
    /// qualify; a plain map value does not (the checker stores the pointer).
    pub fn fromMap(map: anytype, required: []const []const u8) EnvCheck {
        const T = @TypeOf(map);
        if (@typeInfo(T) != .pointer) {
            @compileError("Preflight.EnvCheck.fromMap expects a *pointer* to an environment map (e.g. `init.environ_map`); got " ++ @typeName(T));
        }
        const Map = @TypeOf(map.*);
        return .{
            .ctx = @constCast(map),
            .get = struct {
                fn lookup(ctx: ?*anyopaque, name: []const u8) ?[]const u8 {
                    const m: *const Map = @ptrCast(@alignCast(ctx.?));
                    return m.get(name);
                }
            }.lookup,
            .required = required,
        };
    }
};

/// Fails when a required variable is missing (the classic "works locally,
/// crashes in the container" bug).
pub fn envCheck(ctx: *EnvCheck) Check {
    return .{ .name = "environment", .run = struct {
        fn probe(userdata: ?*anyopaque, allocator: std.mem.Allocator) anyerror!void {
            _ = allocator;
            const c: *EnvCheck = @ptrCast(@alignCast(userdata.?));
            for (c.required) |name| {
                const value = c.get(c.ctx, name);
                if (value == null or value.?.len == 0) return error.MissingRequiredEnvVar;
            }
        }
    }.probe, .ctx = @ptrCast(ctx) };
}

pub const SecretCheck = struct {
    secret: []const u8,
    min_len: usize = 32,
    /// Values that ship in examples/docs and must never reach production.
    forbidden: []const []const u8 = &.{ "dev-secret", "dev-secret-change-me", "secret", "changeme", "test" },
};

/// Rejects placeholder/short JWT secrets — a guessable signing key is a full
/// authentication bypass.
pub fn secretCheck(ctx: *SecretCheck) Check {
    return .{
        .name = "jwt-secret",
        .run = struct {
            fn probe(userdata: ?*anyopaque, allocator: std.mem.Allocator) anyerror!void {
                _ = allocator;
                const c: *SecretCheck = @ptrCast(@alignCast(userdata.?));
                // Placeholder first: "you shipped the example secret" is a more
                // actionable diagnosis than "too short".
                for (c.forbidden) |bad| {
                    if (std.ascii.eqlIgnoreCase(c.secret, bad)) return error.JwtSecretIsPlaceholder;
                }
                if (c.secret.len < c.min_len) return error.JwtSecretTooShort;
            }
        }.probe,
        .ctx = @ptrCast(ctx),
    };
}

/// One round-trip against the database. `client` is the framework sqlx client
/// (or anything with `queryRows(T, sql, params)`).
/// Database reachability probe.
///
/// Accepted form: **a pointer** to anything with
/// `queryRows(T, sql, params) -> QueryResult(T)` — in practice `*zigmodu.data.Client`.
/// Pass `&client`, not `client`: a value would fail deeper inside this function
/// with a type error that does not mention the caller.
pub fn dbCheck(client: anytype) Check {
    const T = @TypeOf(client);
    if (@typeInfo(T) != .pointer) {
        @compileError("Preflight.dbCheck expects a *pointer* to a client (e.g. `&db_client`); got " ++ @typeName(T) ++ ". Pass the address, not the value.");
    }
    const Client = @typeInfo(T).pointer.child;
    if (!@hasDecl(Client, "queryRows")) {
        @compileError("Preflight.dbCheck expects a type with `queryRows(T, sql, params)` (a sqlx Client or a wrapper); got " ++ @typeName(Client));
    }
    return .{ .name = "database", .run = struct {
        fn probe(userdata: ?*anyopaque, allocator: std.mem.Allocator) anyerror!void {
            const c: *Client = @ptrCast(@alignCast(userdata.?));
            const Row = struct { v: i64 };
            var rows = try c.queryRows(Row, "SELECT 1 AS v", &.{});
            defer rows.deinit(allocator);
            if (rows.items.len == 0) return error.DatabaseProbeFailed;
            if (rows.items[0].v != 1) return error.DatabaseProbeFailed;
        }
    }.probe, .ctx = @ptrCast(client) };
}

pub const MigrationCheck = struct {
    /// Returns the number of migrations still to apply (caller stays free to
    /// use `MigrationRunner.getPendingMigrations`, a CLI, or a raw query).
    pending: *const fn (ctx: ?*anyopaque) anyerror!usize,
    ctx: ?*anyopaque = null,
    /// Fail when migrations are pending (default) or merely warn.
    severity: Severity = .fatal,
};

/// Fails when the schema is behind the binary — serving traffic against an
/// unmigrated database produces confusing partial failures.
pub fn migrationCheck(ctx: *MigrationCheck) Check {
    return .{ .name = "migrations", .severity = ctx.severity, .run = struct {
        fn probe(userdata: ?*anyopaque, allocator: std.mem.Allocator) anyerror!void {
            _ = allocator;
            const c: *MigrationCheck = @ptrCast(@alignCast(userdata.?));
            const pending = try c.pending(c.ctx);
            if (pending > 0) return error.PendingMigrations;
        }
    }.probe, .ctx = @ptrCast(ctx) };
}

pub const ClockCheck = struct {
    io: std.Io,
    /// Earliest plausible wall-clock year (a container with a broken clock
    /// mints tokens that are already expired or valid forever).
    min_year: i64 = 2024,
};

pub fn clockCheck(ctx: *ClockCheck) Check {
    return .{
        .name = "clock",
        .severity = .fatal,
        .run = struct {
            fn probe(userdata: ?*anyopaque, allocator: std.mem.Allocator) anyerror!void {
                _ = allocator;
                const c: *ClockCheck = @ptrCast(@alignCast(userdata.?));
                const now = Time.wallClockSeconds(c.io);
                if (now <= 0) return error.ClockUnreadable;
                // 1970-01-01 + 86400*365 days per year, cheap and dependency-free.
                const years_since_epoch = @divFloor(now, 31_536_000);
                if (1970 + years_since_epoch < c.min_year) return error.ClockSkewed;
            }
        }.probe,
        .ctx = @ptrCast(ctx),
    };
}

test "preflight collects findings and does not block on warnings" {
    const allocator = std.testing.allocator;
    const Fake = struct {
        fn lookup(_: ?*anyopaque, name: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, name, "PRESENT")) "1" else null;
        }
    };
    var env_ctx = EnvCheck{ .get = Fake.lookup, .required = &.{ "PRESENT", "ABSENT" } };
    var warn_ctx = EnvCheck{ .get = Fake.lookup, .required = &.{"ABSENT"} };
    var warn_check = envCheck(&warn_ctx);
    warn_check.severity = .warn;

    var report = run(allocator, &.{ envCheck(&env_ctx), warn_check });
    defer report.deinit();

    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.failures);
    try std.testing.expectEqual(@as(usize, 1), report.warnings);
    try std.testing.expectEqualStrings("environment", report.findings.items[0].name);
    try std.testing.expectEqualStrings("MissingRequiredEnvVar", report.findings.items[0].message);
}

test "preflight rejects placeholder and short JWT secrets" {
    const allocator = std.testing.allocator;
    var short = SecretCheck{ .secret = "abc" };
    var placeholder = SecretCheck{ .secret = "dev-secret-change-me" };
    var good = SecretCheck{ .secret = "a-very-long-production-secret-value-42" };

    var report = run(allocator, &.{ secretCheck(&short), secretCheck(&placeholder), secretCheck(&good) });
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), report.failures);
    try std.testing.expectEqual(@as(usize, 1), report.passed);
    try std.testing.expectEqualStrings("JwtSecretTooShort", report.findings.items[0].message);
    try std.testing.expectEqualStrings("JwtSecretIsPlaceholder", report.findings.items[1].message);
}

test "preflight database probe reports a real connection" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    var report = run(allocator, &.{dbCheck(&client)});
    defer report.deinit();
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.passed);
}

test "preflight migration and clock checks" {
    const allocator = std.testing.allocator;
    const Pending = struct {
        var count: usize = 3;
        fn query(_: ?*anyopaque) anyerror!usize {
            return count;
        }
    };
    var migration_ctx = MigrationCheck{ .pending = Pending.query };
    var clock_ctx = ClockCheck{ .io = std.testing.io, .min_year = 1970 }; // any sane clock passes

    var report = run(allocator, &.{ migrationCheck(&migration_ctx), clockCheck(&clock_ctx) });
    defer report.deinit();

    try std.testing.expect(!report.ok());
    try std.testing.expectEqualStrings("migrations", report.findings.items[0].name);
    try std.testing.expectEqualStrings("PendingMigrations", report.findings.items[0].message);
    try std.testing.expectEqual(@as(usize, 1), report.passed); // clock check
}

// `ok()` is the value the caller acts on — the example in the header of this
// file refuses to start on it. It must therefore not depend on whether the
// report could be formatted: a check that failed has to be counted even when
// the finding cannot be recorded.
test "preflight counts a failed check even when its finding cannot be recorded" {
    const Probe = struct {
        fn run(_: ?*anyopaque, _: std.mem.Allocator) anyerror!void {
            return error.ProbeFailed;
        }
    };

    // Every allocation the report needs fails, so no finding can be stored.
    var report = run(std.testing.failing_allocator, &.{Check{ .name = "probe", .run = Probe.run }});
    defer report.deinit();

    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.failures);
    try std.testing.expectEqual(@as(usize, 0), report.findings.items.len);
    try std.testing.expectEqual(@as(usize, 0), report.passed);
}

test "dbCheck accepts any type with queryRows (kept as a contract test)" {
    const allocator = std.testing.allocator;

    // A minimal duck-typed stand-in: the contract is the method, not the type.
    const Fake = struct {
        called: bool = false,
        pub fn queryRows(self: *@This(), comptime T: type, sql: []const u8, args: []const @import("../sqlx/sqlx.zig").Value) !@import("../sqlx/sqlx.zig").QueryResult(T) {
            _ = sql;
            _ = args;
            self.called = true;
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const rows = try arena.allocator().alloc(T, 1);
            rows[0] = .{ .v = 1 };
            return .{ .items = rows, .arena = arena };
        }
    };
    var fake = Fake{};
    var report = run(allocator, &.{dbCheck(&fake)});
    defer report.deinit();
    try std.testing.expect(report.ok());
    try std.testing.expect(fake.called);

    // Real client, pointer form (the documented one).
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var report2 = run(allocator, &.{dbCheck(&client)});
    defer report2.deinit();
    try std.testing.expect(report2.ok());
}
