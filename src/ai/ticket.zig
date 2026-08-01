//! Ticket triage: load customer/order context, classify the ticket, draft a
//! reply, run an approval/send gate, and write the outcome to the outbox.
//!
//! Classification and drafting are callbacks (wire them to an LLM or rules);
//! the send gate is where a human-in-the-loop approval lives.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const reporter = @import("reporter.zig");

pub const ClassifyFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    ticket_text: []const u8,
    category: *[]const u8,
) anyerror!void;

pub const DraftFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    ticket_text: []const u8,
    category: []const u8,
    context_block: []const u8,
    draft: *[]const u8,
) anyerror!void;

/// Approval/send gate: the app decides whether to send, hold for a human, or
/// reject. Set `out.sent`.
pub const SendFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    category: []const u8,
    draft: []const u8,
    out: *TicketOutcome,
) anyerror!void;

pub const TicketOutcome = struct {
    category: []const u8,
    context: []const u8,
    draft: []const u8,
    sent: bool = false,

    pub fn deinit(self: *TicketOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.category);
        allocator.free(self.context);
        allocator.free(self.draft);
        self.* = undefined;
    }
};

pub const TicketFlow = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    context_queries: []const reporter.ReportQuery = &.{},
    classify: ?ClassifyFn = null,
    draft: ?DraftFn = null,
    on_send: ?SendFn = null,
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.ticket",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend) TicketFlow {
        return .{ .allocator = allocator, .backend = backend };
    }

    /// Triage one ticket: context → classify → draft → send gate → outbox.
    pub fn handle(self: *TicketFlow, allocator: std.mem.Allocator, ctx: *SkillContext, ticket_text: []const u8) !TicketOutcome {
        var out = TicketOutcome{
            .category = "",
            .context = "",
            .draft = "",
        };
        errdefer out.deinit(allocator);

        var context_block: []const u8 = "";
        if (self.context_queries.len > 0) {
            var rep = reporter.BusinessReporter.init(allocator, self.backend, "Context", self.context_queries);
            const block = try rep.generate(allocator);
            context_block = block;
        }
        out.context = try allocator.dupe(u8, context_block);
        if (context_block.len > 0) allocator.free(@constCast(context_block));

        if (self.classify) |f| try f(allocator, ctx, ticket_text, &out.category);
        if (self.draft) |f| try f(allocator, ctx, ticket_text, out.category, out.context, &out.draft);
        if (self.on_send) |f| try f(allocator, ctx, out.category, out.draft, &out);

        if (self.outbox) |ob| {
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"category\":\"{s}\",\"draft\":\"{s}\",\"sent\":{s}}}",
                .{ out.category, out.draft, if (out.sent) "true" else "false" },
            );
            defer allocator.free(payload);
            const insert = try ob.buildInsert(self.outbox_topic, payload);
            _ = try self.backend.exec(insert.sql, &.{
                .{ .string = insert.params.topic },
                .{ .string = insert.params.payload },
                .{ .int = @intCast(insert.params.max_retries) },
                .{ .int = insert.params.created_at },
                .{ .int = insert.params.updated_at },
            });
        }
        return out;
    }
};

test "TicketFlow triages with context and writes to outbox" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, plan TEXT)", &.{});
    _ = try client.exec("INSERT INTO customers (name, plan) VALUES ('Alice', 'pro')", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    const T = struct {
        fn classify(a: std.mem.Allocator, _: *SkillContext, _: []const u8, cat: *[]const u8) anyerror!void {
            cat.* = try a.dupe(u8, "billing");
        }
        fn draft(a: std.mem.Allocator, _: *SkillContext, _: []const u8, _: []const u8, context: []const u8, d: *[]const u8) anyerror!void {
            d.* = try std.fmt.allocPrint(a, "reply with context: {s}", .{context});
        }
        fn send(a: std.mem.Allocator, _: *SkillContext, _: []const u8, _: []const u8, out: *TicketOutcome) anyerror!void {
            _ = a;
            out.sent = true;
        }
    };

    var flow = TicketFlow.init(allocator, &backend);
    flow.context_queries = &.{.{ .name = "customer", .sql = "SELECT name, plan FROM customers LIMIT 1" }};
    flow.classify = T.classify;
    flow.draft = T.draft;
    flow.on_send = T.send;
    flow.outbox = &outbox;

    var ctx = SkillContext{ .allocator = allocator };
    var outcome = try flow.handle(allocator, &ctx, "my invoice is wrong");
    defer outcome.deinit(allocator);

    try std.testing.expectEqualStrings("billing", outcome.category);
    try std.testing.expect(std.mem.indexOf(u8, outcome.context, "Alice") != null);
    try std.testing.expect(outcome.sent);

    var cursor = try client.queryCursorEx("SELECT topic, payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next() orelse return error.NoOutboxRow;
    try std.testing.expectEqualStrings("ai.ticket", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "billing") != null);
}
