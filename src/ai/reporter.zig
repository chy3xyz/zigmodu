//! Business reporting: run configured SQL queries and render a Markdown
//! report. Pair with `zigmodu.ai.trigger` for scheduled delivery (cron → run →
//! outbox writeback) or call `generate` directly from an API route.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const sqlx = @import("../sqlx/sqlx.zig");

pub const ReportQuery = struct {
    name: []const u8,
    sql: []const u8,
    args: []const sqlx.Value = &.{},
};

pub const BusinessReporter = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    title: []const u8,
    queries: []const ReportQuery,
    max_rows: usize = 20,

    pub fn init(
        allocator: std.mem.Allocator,
        backend: *SqlxBackend,
        title: []const u8,
        queries: []const ReportQuery,
    ) BusinessReporter {
        return .{ .allocator = allocator, .backend = backend, .title = title, .queries = queries };
    }

    /// Run every query and render a Markdown report (caller owns the string).
    pub fn generate(self: *BusinessReporter, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "# ");
        try buf.appendSlice(allocator, self.title);
        try buf.appendSlice(allocator, "\n\n");

        for (self.queries) |q| {
            try buf.appendSlice(allocator, "## ");
            try buf.appendSlice(allocator, q.name);
            try buf.appendSlice(allocator, "\n");

            var cursor = try self.backend.client.queryCursorEx(q.sql, q.args, .{});
            defer cursor.deinit();

            var first = true;
            var rows: usize = 0;
            while (cursor.next()) |row| {
                if (rows >= self.max_rows) break;
                rows += 1;
                if (first) {
                    try buf.appendSlice(allocator, "|");
                    for (row.columns) |c| {
                        try buf.appendSlice(allocator, " ");
                        try buf.appendSlice(allocator, c);
                        try buf.appendSlice(allocator, " |");
                    }
                    try buf.appendSlice(allocator, "\n|");
                    for (row.columns) |_| try buf.appendSlice(allocator, "---|");
                    try buf.appendSlice(allocator, "\n");
                    first = false;
                }
                try buf.appendSlice(allocator, "|");
                for (row.values) |v| {
                    try buf.appendSlice(allocator, " ");
                    switch (v orelse .null) {
                        .null => try buf.appendSlice(allocator, "null"),
                        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
                        .int => |i| try buf.print(allocator, "{d}", .{i}),
                        .float => |f| try buf.print(allocator, "{d}", .{f}),
                        .string => |s| try buf.appendSlice(allocator, s),
                    }
                    try buf.appendSlice(allocator, " |");
                }
                try buf.appendSlice(allocator, "\n");
            }
            if (first) try buf.appendSlice(allocator, "_no rows_\n");
            try buf.appendSlice(allocator, "\n");
        }

        return buf.toOwnedSlice(allocator);
    }
};

test "BusinessReporter renders queries as Markdown" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, amount INTEGER, status TEXT)", &.{});
    _ = try client.exec("INSERT INTO orders (amount, status) VALUES (100, 'paid'), (50, 'failed')", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const queries = [_]ReportQuery{
        .{ .name = "order summary", .sql = "SELECT amount, status FROM orders ORDER BY amount DESC" },
    };
    var reporter = BusinessReporter.init(allocator, &backend, "Daily Orders", &queries);
    const report = try reporter.generate(allocator);
    defer allocator.free(report);

    try std.testing.expect(std.mem.indexOf(u8, report, "# Daily Orders") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "## order summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "100") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "failed") != null);
}
