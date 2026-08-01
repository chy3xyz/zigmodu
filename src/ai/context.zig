//! Conversation context management: estimate token usage and automatically
//! compact long histories by summarizing the older portion.
//!
//! The summarizer is a callback so it can be wired to any LLM provider; when
//! no summarizer is set, the older portion is dropped instead.

const std = @import("std");
const provider_mod = @import("provider.zig");
const tokenizer = @import("tokenizer.zig");

pub const ChatMsg = provider_mod.AiProvider.ChatMsg;

/// Produce a summary of `messages` (owned with `allocator`).
pub const SummarizeFn = *const fn (
    allocator: std.mem.Allocator,
    messages: []const ChatMsg,
    summary: *[]const u8,
) anyerror!void;

pub const ContextManager = struct {
    max_tokens: usize = 16_000,
    keep_recent_tokens: usize = 8_000,
    summarize: ?SummarizeFn = null,

    pub fn init() ContextManager {
        return .{};
    }

    /// True when the estimated token count of `messages` exceeds the budget.
    pub fn shouldCompact(self: ContextManager, messages: []const ChatMsg) bool {
        return tokenizer.estimateMessages(messages) > self.max_tokens;
    }

    /// Compaction split: index after which the tail fits within
    /// `keep_recent_tokens` (estimated). 0 means everything should be kept.
    pub fn splitPoint(self: ContextManager, messages: []const ChatMsg) usize {
        var used: usize = 0;
        var i: usize = messages.len;
        while (i > 0) {
            i -= 1;
            used += tokenizer.estimateTokens(messages[i].role) +
                tokenizer.estimateTokens(messages[i].content) + 4;
            if (used > self.keep_recent_tokens) return i + 1;
        }
        return 0;
    }

    /// Compacts `messages` when over budget: older messages are summarized
    /// (or dropped without a summarizer) and prepended as a system message.
    /// `summary` is an in/out pointer to an owned summary (caller frees);
    /// returned messages alias the input slices — caller keeps `messages`
    /// alive while using the result.
    pub fn manage(
        self: ContextManager,
        allocator: std.mem.Allocator,
        messages: []const ChatMsg,
        summary: *?[]const u8,
    ) !std.ArrayList(ChatMsg) {
        var out = std.ArrayList(ChatMsg).empty;
        errdefer out.deinit(allocator);

        if (!self.shouldCompact(messages)) {
            try out.appendSlice(allocator, messages);
            return out;
        }

        const split = self.splitPoint(messages);
        const older = messages[0..split];
        const recent = messages[split..];

        if (self.summarize) |sf| {
            if (older.len > 0) {
                var new_summary: []const u8 = "";
                try sf(allocator, older, &new_summary);
                const merged = if (summary.*) |s| blk: {
                    const m = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ s, new_summary });
                    allocator.free(new_summary);
                    allocator.free(s);
                    break :blk m;
                } else new_summary;
                summary.* = merged;
                try out.append(allocator, .{ .role = "system", .content = merged });
            }
        }
        try out.appendSlice(allocator, recent);
        return out;
    }
};

test "ContextManager copies when under budget" {
    const allocator = std.testing.allocator;
    var mgr = ContextManager.init();
    mgr.max_tokens = 1000;
    const msgs = [_]ChatMsg{.{ .role = "user", .content = "hi" }};
    var summary: ?[]const u8 = null;
    var out = try mgr.manage(allocator, &msgs, &summary);
    defer out.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(summary == null);
}

test "ContextManager summarizes the older portion" {
    const allocator = std.testing.allocator;
    const T = struct {
        fn summarize(a: std.mem.Allocator, msgs: []const ChatMsg, out: *[]const u8) anyerror!void {
            out.* = try std.fmt.allocPrint(a, "summary({d} msgs)", .{msgs.len});
        }
    };

    var mgr = ContextManager.init();
    mgr.max_tokens = 20;
    mgr.keep_recent_tokens = 14;
    mgr.summarize = T.summarize;

    const msgs = [_]ChatMsg{
        .{ .role = "user", .content = "aaaa bbbb cccc dddd" },
        .{ .role = "user", .content = "eeee ffff gggg hhhh" },
        .{ .role = "user", .content = "iiii jjjj kkkk llll" },
    };
    var summary: ?[]const u8 = null;
    var out = try mgr.manage(allocator, &msgs, &summary);
    defer out.deinit(allocator);
    defer if (summary) |s| allocator.free(s);

    try std.testing.expectEqual(@as(usize, 2), out.items.len); // system summary + recent tail
    try std.testing.expectEqualStrings("system", out.items[0].role);
    try std.testing.expect(summary != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.?, "summary") != null);
}
