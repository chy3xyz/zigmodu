//! Server-side SSE bridge for streamed agent output.
//!
//! Adapts `AgentHooks.on_delta` to any SSE sink (`http.SseWriter` on a live
//! socket, `http.SseRecorder` in tests): every `AiProvider.StreamDelta`
//! becomes one `data:` JSON event whose union tag is the event type, and a
//! `.done` delta additionally terminates the stream with the SSE `done`
//! event. The run still aggregates the full response internally — send the
//! final `AgentResult` yourself when you want an answer envelope after the
//! deltas (see `examples/ai-ops`).
//!
//! Handler wire-up:
//!
//!     var sse = try zigmodu.http.sse(ctx);
//!     var bridge = ai.stream_sse.DeltaSse(@TypeOf(sse)).init(allocator, &sse);
//!     agent.hooks.ctx = &bridge;
//!     agent.hooks.on_delta = @TypeOf(bridge).onDelta;
//!     var result = try agent.run(allocator, goal, &skill_ctx, max_steps);
//!     defer result.deinit(allocator);
//!     try sse.sendData(try std.json.Stringify.valueAlloc(allocator, .{
//!         .answer = result.answer, .steps = result.steps,
//!     }, .{}));
//!     try sse.done();

const std = @import("std");
const provider_mod = @import("provider.zig");

/// One `data:` JSON event. The union tag is the event type; payload strings
/// are borrowed from the live delta and copied during serialization, so the
/// serialized buffer can be freed right after the write.
pub const DeltaEvent = union(enum) {
    content: struct { delta: []const u8 },
    /// Incremental thinking-chain fragment (reasoning models only).
    reasoning: struct { delta: []const u8 },
    /// A streamed tool-call fragment: the function name (set on the first
    /// fragment) plus an incremental `arguments` JSON slice (may be partial).
    tool: struct { name: []const u8, arguments_delta: []const u8 = "" },
    /// Upstream `[DONE]` — the bridge also emits the SSE-level `done` event.
    done: struct {},
};

/// `AgentHooks.on_delta` sink writing JSON events to `W` (`SseWriter` or
/// `SseRecorder` — anything with `sendData`/`done`).
pub fn DeltaSse(comptime W: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        writer: *W,

        pub fn init(allocator: std.mem.Allocator, writer: *W) Self {
            return .{ .allocator = allocator, .writer = writer };
        }

        /// Drop-in for `AgentHooks.on_delta`; `ctx` must be `*Self`.
        pub fn onDelta(ud: ?*anyopaque, delta: provider_mod.AiProvider.StreamDelta) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            const event: DeltaEvent = if (delta.content_delta) |d|
                .{ .content = .{ .delta = d } }
            else if (delta.reasoning_delta) |d|
                .{ .reasoning = .{ .delta = d } }
            else if (delta.tool_name) |n|
                .{ .tool = .{ .name = n, .arguments_delta = delta.tool_arguments_delta orelse "" } }
            else if (delta.done)
                .{ .done = .{} }
            else
                return; // empty fragment — nothing worth an event

            const payload = try std.json.Stringify.valueAlloc(self.allocator, event, .{});
            defer self.allocator.free(payload);
            try self.writer.sendData(payload);
            if (delta.done) try self.writer.done();
        }
    };
}

test "DeltaSse maps every delta kind to a data event, done also closes the stream" {
    const allocator = std.testing.allocator;
    const Sse = @import("../http/Sse.zig");

    var rec = Sse.SseRecorder.init(allocator);
    defer rec.deinit();
    const Bridge = DeltaSse(Sse.SseRecorder);
    var bridge = Bridge.init(allocator, &rec);

    try Bridge.onDelta(&bridge, .{ .content_delta = "Hel" });
    try Bridge.onDelta(&bridge, .{ .reasoning_delta = "let me" });
    try Bridge.onDelta(&bridge, .{ .tool_name = "lookup", .tool_arguments_delta = "{\"q\":" });
    try Bridge.onDelta(&bridge, .{ .done = true });

    const wire = rec.bytes();
    try std.testing.expect(std.mem.indexOf(u8, wire, "data: {\"content\":{\"delta\":\"Hel\"}}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "data: {\"reasoning\":{\"delta\":\"let me\"}}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "data: {\"tool\":{\"name\":\"lookup\",\"arguments_delta\":\"{\\\"q\\\":\"}}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "data: {\"done\":{}}\n") != null);
    // The terminal delta also emits the SSE-level done event.
    try std.testing.expect(std.mem.indexOf(u8, wire, "event: done\ndata: [DONE]\n\n") != null);
}

test "DeltaSse ignores empty fragments and propagates writer errors" {
    const allocator = std.testing.allocator;
    const Sse = @import("../http/Sse.zig");

    var rec = Sse.SseRecorder.init(allocator);
    defer rec.deinit();
    const Bridge = DeltaSse(Sse.SseRecorder);
    var bridge = Bridge.init(allocator, &rec);

    try Bridge.onDelta(&bridge, .{}); // nothing set — no event
    try std.testing.expectEqual(@as(usize, 0), rec.event_count);

    // A failing sink surfaces to the agent loop instead of being swallowed.
    const BadWriter = struct {
        fn sendData(_: *@This(), _: []const u8) !void {
            return error.BrokenPipe;
        }
        fn done(_: *@This()) !void {
            return error.BrokenPipe;
        }
    };
    var bad: BadWriter = .{};
    const BadBridge = DeltaSse(BadWriter);
    var bad_bridge = BadBridge.init(allocator, &bad);
    try std.testing.expectError(error.BrokenPipe, BadBridge.onDelta(&bad_bridge, .{ .content_delta = "x" }));
}
