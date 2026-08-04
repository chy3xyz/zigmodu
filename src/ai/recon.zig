//! Data reconciliation ("对账") checks: run a source SQL and a target SQL that
//! both return `key, value...` columns, then compare the two snapshots.
//! Differences are reported as missing-in-target, extra-in-source and value
//! mismatches — via callback, a transactional-outbox writeback, or a Markdown
//! report. Pair with `zigmodu.ai.trigger` for scheduled reconciliation.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const sqlx = @import("../sqlx/sqlx.zig");

pub const ReconDiffKind = enum { missing_in_target, extra_in_source, mismatch };

/// A single detected difference.
pub const ReconDiff = struct {
    kind: ReconDiffKind,
    key: []const u8,
    source_value: ?[]const u8 = null, // value in the source snapshot
    target_value: ?[]const u8 = null, // value in the target snapshot
};

/// Optional callback fired for each diff (e.g. push to a channel / create a
/// ticket). Strings are only valid for the duration of the call.
pub const ReconFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    diff: ReconDiff,
) anyerror!void;

pub const ReconResult = struct {
    /// Total keys compared (union of source + target keys).
    compared: usize,
    missing_in_target: usize,
    extra_in_source: usize,
    mismatched: usize,

    pub fn clean(self: *const ReconResult) bool {
        return self.missing_in_target == 0 and self.extra_in_source == 0 and self.mismatched == 0;
    }
};

pub const ReconCheck = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    source_sql: []const u8,
    target_sql: []const u8,
    source_args: []const sqlx.Value = &.{},
    target_args: []const sqlx.Value = &.{},
    /// Name of the key column. Defaults to the first column of both queries.
    key_column: ?[]const u8 = null,
    /// Optional extra columns compared. Defaults to every non-key column.
    value_columns: ?[]const []const u8 = null,
    on_diff: ?ReconFn = null,
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.recon",

    pub fn init(
        allocator: std.mem.Allocator,
        backend: *SqlxBackend,
        source_sql: []const u8,
        target_sql: []const u8,
    ) ReconCheck {
        return .{
            .allocator = allocator,
            .backend = backend,
            .source_sql = source_sql,
            .target_sql = target_sql,
        };
    }

    /// Run both queries and compare. The returned result is owned by the
    /// caller; every string inside the returned diffs is allocated in
    /// `allocator` and must be freed by the caller (see `freeDiffs`).
    pub fn check(self: *ReconCheck, allocator: std.mem.Allocator, ctx: *SkillContext) !struct {
        result: ReconResult,
        diffs: []ReconDiff,
    } {
        var source_map = std.StringHashMap([]const u8).init(allocator);
        defer {
            freeMap(allocator, &source_map);
            source_map.deinit();
        }
        try self.load(allocator, self.source_sql, self.source_args, &source_map);

        var target_map = std.StringHashMap([]const u8).init(allocator);
        defer {
            freeMap(allocator, &target_map);
            target_map.deinit();
        }
        try self.load(allocator, self.target_sql, self.target_args, &target_map);

        var diffs = std.ArrayList(ReconDiff).empty;
        errdefer diffs.deinit(allocator);

        var missing: usize = 0;
        var extra: usize = 0;
        var mismatched: usize = 0;

        // Source → target: missing or mismatched.
        var it = source_map.iterator();
        while (it.next()) |entry| {
            const target_value = target_map.get(entry.key_ptr.*) orelse {
                missing += 1;
                try diffs.append(allocator, .{
                    .kind = .missing_in_target,
                    .key = try allocator.dupe(u8, entry.key_ptr.*),
                    .source_value = try allocator.dupe(u8, entry.value_ptr.*),
                });
                continue;
            };
            if (!std.mem.eql(u8, target_value, entry.value_ptr.*)) {
                mismatched += 1;
                try diffs.append(allocator, .{
                    .kind = .mismatch,
                    .key = try allocator.dupe(u8, entry.key_ptr.*),
                    .source_value = try allocator.dupe(u8, entry.value_ptr.*),
                    .target_value = try allocator.dupe(u8, target_value),
                });
            }
        }

        // Target → source: extra rows.
        var tit = target_map.iterator();
        while (tit.next()) |entry| {
            if (!source_map.contains(entry.key_ptr.*)) {
                extra += 1;
                try diffs.append(allocator, .{
                    .kind = .extra_in_source,
                    .key = try allocator.dupe(u8, entry.key_ptr.*),
                    .target_value = try allocator.dupe(u8, entry.value_ptr.*),
                });
            }
        }

        // Union of distinct keys across both snapshots.
        var compared: usize = 0;
        var sit = source_map.iterator();
        while (sit.next()) |e| {
            compared += 1;
            _ = e;
        }
        var tjt = target_map.iterator();
        while (tjt.next()) |e| {
            if (!source_map.contains(e.key_ptr.*)) compared += 1;
        }

        const result = ReconResult{
            .compared = compared,
            .missing_in_target = missing,
            .extra_in_source = extra,
            .mismatched = mismatched,
        };

        for (diffs.items) |d| {
            if (self.on_diff) |cb| try cb(allocator, ctx, d);
        }
        if (self.outbox != null) try self.writeSummary(allocator, result);

        return .{ .result = result, .diffs = try diffs.toOwnedSlice(allocator) };
    }

    fn load(
        self: *ReconCheck,
        allocator: std.mem.Allocator,
        sql: []const u8,
        args: []const sqlx.Value,
        map: *std.StringHashMap([]const u8),
    ) !void {
        var cursor = try self.backend.client.queryCursorEx(sql, args, .{});
        defer cursor.deinit();
        var key_buf: [64]u8 = undefined;
        while (cursor.next()) |row| {
            const key = self.keyOf(row, &key_buf) orelse continue;
            const key_owned = try allocator.dupe(u8, key);
            const canonical = try self.canonicalValue(allocator, row);
            errdefer allocator.free(key_owned);
            errdefer allocator.free(canonical);
            const gop = try map.getOrPut(key_owned);
            if (gop.found_existing) {
                allocator.free(key_owned);
                allocator.free(canonical);
            } else {
                gop.value_ptr.* = canonical;
            }
        }
    }

    fn keyOf(self: *ReconCheck, row: *sqlx.Row, buf: *[64]u8) ?[]const u8 {
        if (self.key_column) |col| {
            return if (row.get(col)) |v| switch (v) {
                .string => |s| s,
                else => self.inlineValue(v, buf),
            } else null;
        }
        if (row.columns.len == 0) return null;
        return if (row.get(row.columns[0])) |v| switch (v) {
            .string => |s| s,
            else => self.inlineValue(v, buf),
        } else null;
    }

    /// Render a scalar into the caller's scratch buffer (no allocation) so the
    /// key slice stays valid until the next key lookup.
    fn inlineValue(self: *ReconCheck, v: sqlx.Value, buf: *[64]u8) []const u8 {
        _ = self;
        switch (v) {
            .null => return "null",
            .bool => |b| return if (b) "true" else "false",
            .int => |i| return std.fmt.bufPrint(buf, "{d}", .{i}) catch "int",
            .float => |f| return std.fmt.bufPrint(buf, "{d}", .{f}) catch "float",
            .string => |s| return s,
        }
    }

    /// Canonical form of the compared value columns:
    /// `col1=val1|col2=val2|...` (stable column order).
    fn canonicalValue(self: *ReconCheck, allocator: std.mem.Allocator, row: *sqlx.Row) ![]const u8 {
        var extra_cols = std.ArrayList([]const u8).empty;
        defer extra_cols.deinit(allocator);

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        const cols: []const []const u8 = if (self.value_columns) |vc|
            vc
        else if (self.key_column) |kc| blk: {
            for (row.columns) |c| {
                if (!std.mem.eql(u8, c, kc)) try extra_cols.append(allocator, c);
            }
            break :blk extra_cols.items;
        } else if (row.columns.len > 1) row.columns[1..] else &.{};

        var first = true;
        for (cols) |c| {
            if (!first) try buf.appendSlice(allocator, "|");
            first = false;
            try buf.appendSlice(allocator, c);
            try buf.appendSlice(allocator, "=");
            const v = if (row.get(c)) |val| val else .null;
            try appendValue(allocator, &buf, v);
        }
        return buf.toOwnedSlice(allocator);
    }

    fn writeSummary(self: *ReconCheck, allocator: std.mem.Allocator, result: ReconResult) !void {
        const payload = try std.fmt.allocPrint(
            allocator,
            "RECON compared={d} missing={d} extra={d} mismatch={d} {s}",
            .{
                result.compared,
                result.missing_in_target,
                result.extra_in_source,
                result.mismatched,
                if (result.clean()) "CLEAN" else "DRIFT",
            },
        );
        defer allocator.free(payload);
        const insert = try self.outbox.?.buildInsert(self.outbox_topic, payload);
        _ = try self.backend.exec(insert.sql, &.{
            .{ .string = insert.params.topic },
            .{ .string = insert.params.payload },
            .{ .int = @intCast(insert.params.max_retries) },
            .{ .int = insert.params.created_at },
            .{ .int = insert.params.updated_at },
        });
    }
};

/// Free every string inside diffs returned by `check`.
pub fn freeDiffs(allocator: std.mem.Allocator, diffs: []ReconDiff) void {
    for (diffs) |d| {
        allocator.free(d.key);
        if (d.source_value) |s| allocator.free(s);
        if (d.target_value) |t| allocator.free(t);
    }
    allocator.free(diffs);
}

/// Free every owned key and value stored by `load`. Keys are globally unique
/// because `load` drops duplicate keys, so iterating both maps once is safe.
fn freeMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
}

/// Render the diffs as a compact Markdown report (caller owns the string).
pub fn renderReport(allocator: std.mem.Allocator, result: ReconResult, diffs: []const ReconDiff) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "# Reconciliation report\n\n");
    try buf.print(allocator, "compared {d} · missing {d} · extra {d} · mismatch {d} · {s}\n\n", .{
        result.compared,
        result.missing_in_target,
        result.extra_in_source,
        result.mismatched,
        if (result.clean()) "CLEAN" else "DRIFT",
    });
    for (diffs) |d| {
        switch (d.kind) {
            .missing_in_target => try buf.print(allocator, "- `{s}` missing in target (source value `{s}`)\n", .{ d.key, d.source_value orelse "" }),
            .extra_in_source => try buf.print(allocator, "- `{s}` extra in source (target value `{s}`)\n", .{ d.key, d.target_value orelse "" }),
            .mismatch => try buf.print(allocator, "- `{s}` mismatch: `{s}` → `{s}`\n", .{ d.key, d.source_value orelse "", d.target_value orelse "" }),
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn appendValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: sqlx.Value) !void {
    switch (v) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |i| try buf.print(allocator, "{d}", .{i}),
        .float => |f| try buf.print(allocator, "{d}", .{f}),
        .string => |s| try buf.appendSlice(allocator, s),
    }
}

test "ReconCheck detects missing, extra and mismatched rows" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec("CREATE TABLE src_orders (id INTEGER PRIMARY KEY, amount INTEGER)", &.{});
    _ = try client.exec("CREATE TABLE tgt_orders (id INTEGER PRIMARY KEY, amount INTEGER)", &.{});
    _ = try client.exec("INSERT INTO src_orders VALUES (1, 100), (2, 200), (3, 300)", &.{});
    _ = try client.exec("INSERT INTO tgt_orders VALUES (1, 100), (2, 999), (4, 400)", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    var recon = ReconCheck.init(
        allocator,
        &backend,
        "SELECT id, amount FROM src_orders ORDER BY id",
        "SELECT id, amount FROM tgt_orders ORDER BY id",
    );
    recon.outbox = &outbox;
    var ctx = SkillContext{ .allocator = allocator };

    const out = try recon.check(allocator, &ctx);
    defer freeDiffs(allocator, out.diffs);

    try std.testing.expectEqual(@as(usize, 1), out.result.missing_in_target); // id=3
    try std.testing.expectEqual(@as(usize, 1), out.result.extra_in_source); // id=4
    try std.testing.expectEqual(@as(usize, 1), out.result.mismatched); // id=2 amount
    try std.testing.expect(!out.result.clean());

    // Outbox summary written for downstream automation.
    var cursor = try client.queryCursorEx("SELECT topic, payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next() orelse return error.NoOutboxRow;
    try std.testing.expectEqualStrings("ai.recon", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "DRIFT") != null);

    const report = try renderReport(allocator, out.result, out.diffs);
    defer allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "mismatch") != null);
}

test "ReconCheck reports clean when snapshots match" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE src (id INTEGER PRIMARY KEY, amount INTEGER)", &.{});
    _ = try client.exec("CREATE TABLE tgt (id INTEGER PRIMARY KEY, amount INTEGER)", &.{});
    _ = try client.exec("INSERT INTO src VALUES (1, 100), (2, 200)", &.{});
    _ = try client.exec("INSERT INTO tgt VALUES (1, 100), (2, 200)", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var recon = ReconCheck.init(allocator, &backend, "SELECT id, amount FROM src", "SELECT id, amount FROM tgt");
    var ctx = SkillContext{ .allocator = allocator };
    const out = try recon.check(allocator, &ctx);
    defer freeDiffs(allocator, out.diffs);

    try std.testing.expect(out.result.clean());
    try std.testing.expectEqual(@as(usize, 2), out.result.compared);
    try std.testing.expectEqual(@as(usize, 0), out.diffs.len);
}
