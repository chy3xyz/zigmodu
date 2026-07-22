// MCP Protocol Types — JSON-RPC 2.0 message definitions for Model Context Protocol
const std = @import("std");

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?i64 = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const JsonRpcError = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?i64 = null,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
};

/// Build a JSON-RPC 2.0 success response string. Caller owns the returned slice.
pub fn successResponse(allocator: std.mem.Allocator, id: i64, result: std.json.Value) ![]const u8 {
    const resp = JsonRpcResponse{
        .id = id,
        .result = result,
    };
    return try std.json.Stringify.valueAlloc(allocator, resp, .{});
}

/// Build a JSON-RPC 2.0 error response string. Caller owns the returned slice.
pub fn errorResponse(allocator: std.mem.Allocator, id: ?i64, code: i64, message: []const u8) ![]const u8 {
    const resp = JsonRpcResponse{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    };
    return try std.json.Stringify.valueAlloc(allocator, resp, .{});
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "successResponse produces valid JSON-RPC 2.0" {
    const allocator = std.testing.allocator;
    const json = try successResponse(allocator, 42, .{ .string = "ok" });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 42), root.get("id").?.integer);
    try std.testing.expectEqualStrings("ok", root.get("result").?.string);
}

test "errorResponse produces valid JSON-RPC 2.0 error" {
    const allocator = std.testing.allocator;
    const json = try errorResponse(allocator, 1, -32600, "Invalid Request");
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("id").?.integer);
    const err_obj = root.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32600), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("Invalid Request", err_obj.get("message").?.string);
}

test "both responses produce parseable JSON" {
    const allocator = std.testing.allocator;

    const success_json = try successResponse(allocator, 1, .{ .integer = 99 });
    defer allocator.free(success_json);
    const s = try std.json.parseFromSlice(std.json.Value, allocator, success_json, .{});
    s.deinit();

    const error_json = try errorResponse(allocator, null, -32700, "Parse error");
    defer allocator.free(error_json);
    const e = try std.json.parseFromSlice(std.json.Value, allocator, error_json, .{});
    e.deinit();
}
