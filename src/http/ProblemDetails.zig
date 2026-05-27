const std = @import("std");

/// RFC 7807 Problem Details — [...] HTTP Error[...]
/// https://tools.ietf.org/html/rfc7807
///
/// Usage:
///   const problem = ProblemDetails.init(allocator, 404, "User not found", "/users/42");
///   try ctx.json(problem.status, try problem.toJson());
pub const ProblemDetails = struct {
    /// HTTP status code
    status: u16,
    /// [...]Error[...] ([...] "Not Found")
    title: []const u8,
    /// [...]Error[...]
    detail: []const u8,
    /// [...]Error[...] URI
    instance: ?[]const u8 = null,
    /// [...]Error type URI ([...] "https://api.example.com/errors/validation-failed")
    type: ?[]const u8 = null,

    const Self = @This();

    /// [...] HTTP [...]
    pub fn statusTitle(status: u16) []const u8 {
        return switch (status) {
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            408 => "Request Timeout",
            409 => "Conflict",
            410 => "Gone",
            422 => "Unprocessable Entity",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            504 => "Gateway Timeout",
            else => "Unknown Error",
        };
    }

    /// [...] ProblemDetails
    pub fn init(status: u16, detail: []const u8, instance: ?[]const u8) ProblemDetails {
        return .{
            .status = status,
            .title = statusTitle(status),
            .detail = detail,
            .instance = instance,
        };
    }

    /// Create one with custom type ProblemDetails
    pub fn initTyped(status: u16, err_type: []const u8, detail: []const u8) ProblemDetails {
        return .{
            .status = status,
            .title = statusTitle(status),
            .detail = detail,
            .type = err_type,
        };
    }

    /// [...] JSON
    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{");

        const Emit = struct {
            fn field(target: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
                const s = try std.fmt.allocPrint(alloc, fmt, args);
                defer alloc.free(s);
                try target.appendSlice(alloc, s);
            }
        };

        try Emit.field(&buf, allocator, "\"status\":{d}", .{self.status});
        try buf.appendSlice(allocator, ",\"title\":\"");
        try buf.appendSlice(allocator, self.title);
        try buf.appendSlice(allocator, "\"");

        try Emit.field(&buf, allocator, ",\"detail\":\"{s}\"", .{self.detail});

        if (self.instance) |inst| {
            try Emit.field(&buf, allocator, ",\"instance\":\"{s}\"", .{inst});
        }
        if (self.type) |t| {
            try Emit.field(&buf, allocator, ",\"type\":\"{s}\"", .{t});
        }

        try buf.appendSlice(allocator, "}");

        return buf.toOwnedSlice(allocator);
    }
};

/// [...]ValidationError (RFC 7807 [...] — [...]Field error)
pub const ValidationProblem = struct {
    base: ProblemDetails,
    errors: []const FieldError,

    pub const FieldError = struct {
        field: []const u8,
        message: []const u8,
        code: ?[]const u8 = null,
    };

    /// [...]ValidationError
    pub fn init(status: u16, detail: []const u8, field_errors: []const FieldError) ValidationProblem {
        return .{
            .base = ProblemDetails.init(status, detail, null),
            .errors = field_errors,
        };
    }

    /// [...] JSON ([...] errors [...])
    pub fn toJson(self: *const ValidationProblem, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        const Emit = struct {
            fn field(target: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
                const s = try std.fmt.allocPrint(alloc, fmt, args);
                defer alloc.free(s);
                try target.appendSlice(alloc, s);
            }
        };

        try buf.appendSlice(allocator, "{");
        try Emit.field(&buf, allocator, "\"status\":{d}", .{self.base.status});
        try buf.appendSlice(allocator, ",\"title\":\"");
        try buf.appendSlice(allocator, self.base.title);
        try buf.appendSlice(allocator, "\"");
        try Emit.field(&buf, allocator, ",\"detail\":\"{s}\"", .{self.base.detail});

        // errors [...]
        try buf.appendSlice(allocator, ",\"errors\":[");
        for (self.errors, 0..) |err, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "{");
            try Emit.field(&buf, allocator, "\"field\":\"{s}\"", .{err.field});
            try Emit.field(&buf, allocator, ",\"message\":\"{s}\"", .{err.message});
            if (err.code) |code| {
                try Emit.field(&buf, allocator, ",\"code\":\"{s}\"", .{code});
            }
            try buf.appendSlice(allocator, "}");
        }
        try buf.appendSlice(allocator, "]");

        try buf.appendSlice(allocator, "}");

        return buf.toOwnedSlice(allocator);
    }
};

/// HTTP Error[...] — for[...] handler
pub fn sendProblem(ctx: anytype, status: u16, detail: []const u8) !void {
    const problem = ProblemDetails.init(status, detail, null);
    const json = try problem.toJson(ctx.allocator);
    defer ctx.allocator.free(json);
    try ctx.json(status, json);
}

pub fn sendProblemWithType(ctx: anytype, status: u16, err_type: []const u8, detail: []const u8) !void {
    const problem = ProblemDetails.initTyped(status, err_type, detail);
    const json = try problem.toJson(ctx.allocator);
    defer ctx.allocator.free(json);
    try ctx.json(status, json);
}

pub fn sendValidationProblem(ctx: anytype, status: u16, detail: []const u8, field_errors: []const ValidationProblem.FieldError) !void {
    const problem = ValidationProblem.init(status, detail, field_errors);
    const json = try problem.toJson(ctx.allocator);
    defer ctx.allocator.free(json);
    try ctx.json(status, json);
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "ProblemDetails basic" {
    const allocator = std.testing.allocator;

    const problem = ProblemDetails.init(404, "User with ID 42 not found", "/users/42");
    const json = try problem.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"status\":404"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "Not Found"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "User with ID 42 not found"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "/users/42"));
}

test "ProblemDetails typed" {
    const allocator = std.testing.allocator;

    const problem = ProblemDetails.initTyped(422, "https://api.example.com/errors/validation", "Validation failed");
    const json = try problem.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"type\":"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "validation"));
}

test "ProblemDetails status titles" {
    try std.testing.expectEqualStrings("Not Found", ProblemDetails.statusTitle(404));
    try std.testing.expectEqualStrings("Internal Server Error", ProblemDetails.statusTitle(500));
    try std.testing.expectEqualStrings("Bad Request", ProblemDetails.statusTitle(400));
    try std.testing.expectEqualStrings("Too Many Requests", ProblemDetails.statusTitle(429));
    try std.testing.expectEqualStrings("Unknown Error", ProblemDetails.statusTitle(418));
}

test "ValidationProblem basic" {
    const allocator = std.testing.allocator;

    const field_errors = &[_]ValidationProblem.FieldError{
        .{ .field = "email", .message = "Invalid email format", .code = "INVALID_EMAIL" },
        .{ .field = "age", .message = "Age must be at least 18", .code = "TOO_YOUNG" },
    };

    const problem = ValidationProblem.init(422, "Validation failed", field_errors);
    const json = try problem.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"errors\":["));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "email"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "INVALID_EMAIL"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "age"));
}

test "ProblemDetails without instance" {
    const allocator = std.testing.allocator;

    const problem = ProblemDetails.init(500, "Database connection failed", null);
    const json = try problem.toJson(allocator);
    defer allocator.free(json);

    // Should NOT contain "instance"
    try std.testing.expect(!std.mem.containsAtLeast(u8, json, 1, "\"instance\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "Database connection failed"));
}
