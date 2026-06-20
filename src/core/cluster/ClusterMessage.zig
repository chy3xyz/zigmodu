//! Standardized cluster message protocol for node-to-node communication.
//!
//! All cluster messages use JSON serialization for debuggability.
//! Binary framing provided by NetworkTransport (4-byte length prefix).

const std = @import("std");

/// All known cluster message types.
pub const MessageType = enum(u8) {
    vote_request = 1,
    vote_response = 2,
    heartbeat = 3,
    heartbeat_ack = 4,
    gossip_sync = 5,
    event_publish = 6,
    event_subscribe = 7,
    leave = 8,
    join = 9,
};

/// A serializable cluster message.
pub const ClusterMessage = struct {
    version: u8 = 1,
    msg_type: MessageType,
    sender_id: []const u8,
    term: u64 = 0,
    payload: ?[]const u8 = null,

    /// Serialize to JSON. Caller owns returned memory.
    pub fn toJson(self: *const ClusterMessage, allocator: std.mem.Allocator) ![]const u8 {
        return try std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    /// Deserialize from JSON. Caller owns returned string fields via `deinit`.
    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !ClusterMessage {
        var parsed = try std.json.parseFromSlice(ClusterMessage, allocator, json, .{ .allocate = .alloc_if_needed });
        defer parsed.deinit();
        return .{
            .version = parsed.value.version,
            .msg_type = parsed.value.msg_type,
            .sender_id = try allocator.dupe(u8, parsed.value.sender_id),
            .term = parsed.value.term,
            .payload = if (parsed.value.payload) |p| try allocator.dupe(u8, p) else null,
        };
    }

    pub fn deinit(self: *ClusterMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.sender_id);
        if (self.payload) |p| allocator.free(p);
    }
};

test "ClusterMessage JSON round-trip" {
    const allocator = std.testing.allocator;
    const msg = ClusterMessage{
        .msg_type = .vote_request,
        .sender_id = "node-1",
        .term = 5,
        .payload = "{\"candidate\":\"node-1\"}",
    };

    const json = try msg.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "vote_request") != null);

    var parsed = try ClusterMessage.fromJson(allocator, json);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(MessageType.vote_request, parsed.msg_type);
    try std.testing.expectEqual(@as(u64, 5), parsed.term);
}
