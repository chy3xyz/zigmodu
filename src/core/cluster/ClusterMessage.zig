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
        return try std.fmt.allocPrint(allocator, "{any}", .{std.json.fmt(self, .{})});
    }

    /// Deserialize from JSON.
    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !ClusterMessage {
        const parsed = try std.json.parseFromSlice(ClusterMessage, allocator, json, .{});
        return parsed.value;
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

    const parsed = try ClusterMessage.fromJson(allocator, json);
    try std.testing.expectEqual(MessageType.vote_request, parsed.msg_type);
    try std.testing.expectEqual(@as(u64, 5), parsed.term);
}
