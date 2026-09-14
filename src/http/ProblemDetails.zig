const std = @import("std");

/// RFC 7807 Problem Details — the machine-readable HTTP error body.
/// https://tools.ietf.org/html/rfc7807
///
/// Usage:
///   const problem = ProblemDetails.init(404, "User not found", "/users/42");
///   const json = try problem.toJson(allocator);
///   try ctx.json(problem.status, json);
///
/// Body shape: `{"status":404,"title":"Not Found","detail":"…","instance":"/users/42"}`
/// (`instance` and `type` are omitted when null).
pub const ProblemDetails = struct {
    /// HTTP status code.
    status: u16,
    /// Standard reason phrase for `status` (e.g. "Not Found").
    title: []const u8,
    /// Human-readable explanation of this specific occurrence.
    detail: []const u8,
    /// Request path that produced the error.
    instance: ?[]const u8 = null,
    /// Error type URI (e.g. "https://api.example.com/errors/validation-failed").
    type: ?[]const u8 = null,

    const Self = @This();

    /// Standard reason phrase for an HTTP status code. Unknown codes fall back
    /// to "Unknown Error" rather than inventing a phrase.
    pub fn statusTitle(status: u16) []const u8 {
        return switch (status) {
            400 => "Bad Request",
            401 => "Unauthorized",
            402 => "Payment Required",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            406 => "Not Acceptable",
            408 => "Request Timeout",
            409 => "Conflict",
            410 => "Gone",
            411 => "Length Required",
            412 => "Precondition Failed",
            413 => "Content Too Large",
            414 => "URI Too Long",
            415 => "Unsupported Media Type",
            416 => "Range Not Satisfiable",
            418 => "I'm a Teapot",
            422 => "Unprocessable Entity",
            423 => "Locked",
            425 => "Too Early",
            426 => "Upgrade Required",
            428 => "Precondition Required",
            429 => "Too Many Requests",
            431 => "Request Header Fields Too Large",
            451 => "Unavailable For Legal Reasons",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            504 => "Gateway Timeout",
            505 => "HTTP Version Not Supported",
            507 => "Insufficient Storage",
            else => "Unknown Error",
        };
    }

    /// Build a ProblemDetails whose `title` is derived from `status`.
    pub fn init(status: u16, detail: []const u8, instance: ?[]const u8) ProblemDetails {
        return .{
            .status = status,
            .title = statusTitle(status),
            .detail = detail,
            .instance = instance,
        };
    }

    /// Like `init`, plus an explicit error `type` URI for machine dispatch.
    pub fn initTyped(status: u16, err_type: []const u8, detail: []const u8) ProblemDetails {
        return .{
            .status = status,
            .title = statusTitle(status),
            .detail = detail,
            .type = err_type,
        };
    }

    /// Serialize to JSON. Every string field is escaped, so `detail` may carry
    /// validator output or other untrusted text without breaking the body.
    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        const quoteInto = struct {
            fn call(target: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
                const quoted = try std.json.Stringify.valueAlloc(alloc, s, .{});
                defer alloc.free(quoted);
                try target.appendSlice(alloc, quoted);
            }
        }.call;

        var num_buf: [8]u8 = undefined;
        const status_str = try std.fmt.bufPrint(&num_buf, "{d}", .{self.status});

        try buf.appendSlice(allocator, "{\"status\":");
        try buf.appendSlice(allocator, status_str);
        try buf.appendSlice(allocator, ",\"title\":");
        try quoteInto(&buf, allocator, self.title);
        try buf.appendSlice(allocator, ",\"detail\":");
        try quoteInto(&buf, allocator, self.detail);
        if (self.instance) |inst| {
            try buf.appendSlice(allocator, ",\"instance\":");
            try quoteInto(&buf, allocator, inst);
        }
        if (self.type) |t| {
            try buf.appendSlice(allocator, ",\"type\":");
            try quoteInto(&buf, allocator, t);
        }
        try buf.appendSlice(allocator, "}");

        return buf.toOwnedSlice(allocator);
    }

    /// Render into a caller-owned buffer — for the pre-routing transport errors
    /// (408/413/431/503), which are written from the accept thread and must not
    /// allocate. Truncates rather than failing if `buf` is too small.
    pub fn writeToBuf(self: *const Self, buf: []u8) []const u8 {
        var fbs = std.Io.Writer.fixed(buf);
        const w = &fbs;
        w.writeAll("{\"status\":") catch return buf[0..0];
        w.print("{d}", .{self.status}) catch return fbs.buffered();
        w.writeAll(",\"title\":") catch return fbs.buffered();
        writeJsonString(w, self.title) catch return fbs.buffered();
        w.writeAll(",\"detail\":") catch return fbs.buffered();
        writeJsonString(w, self.detail) catch return fbs.buffered();
        if (self.instance) |inst| {
            w.writeAll(",\"instance\":") catch return fbs.buffered();
            writeJsonString(w, inst) catch return fbs.buffered();
        }
        w.writeAll("}") catch return fbs.buffered();
        return fbs.buffered();
    }

    fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
        try w.writeByte('"');
        for (s) |c| switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        };
        try w.writeByte('"');
    }
};

/// Validation error body: ProblemDetails plus a per-field `errors` array.
pub const ValidationProblem = struct {
    base: ProblemDetails,
    errors: []const FieldError,

    pub const FieldError = struct {
        field: []const u8,
        message: []const u8,
        code: ?[]const u8 = null,
    };

    /// Build a 422-shaped validation body; `title` follows `status`.
    pub fn init(status: u16, detail: []const u8, field_errors: []const FieldError) ValidationProblem {
        return .{
            .base = ProblemDetails.init(status, detail, null),
            .errors = field_errors,
        };
    }

    /// Serialize to JSON (`base` fields plus `errors`). All strings escaped.
    pub fn toJson(self: *const ValidationProblem, allocator: std.mem.Allocator) ![]const u8 {
        const base_json = try self.base.toJson(allocator);
        defer allocator.free(base_json);

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        // Splice `errors` in before the base object's closing brace.
        try buf.appendSlice(allocator, base_json[0 .. base_json.len - 1]);
        try buf.appendSlice(allocator, ",\"errors\":[");
        for (self.errors, 0..) |err, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            const field = try std.json.Stringify.valueAlloc(allocator, err.field, .{});
            defer allocator.free(field);
            const message = try std.json.Stringify.valueAlloc(allocator, err.message, .{});
            defer allocator.free(message);
            try buf.appendSlice(allocator, "{\"field\":");
            try buf.appendSlice(allocator, field);
            try buf.appendSlice(allocator, ",\"message\":");
            try buf.appendSlice(allocator, message);
            if (err.code) |code| {
                const code_json = try std.json.Stringify.valueAlloc(allocator, code, .{});
                defer allocator.free(code_json);
                try buf.appendSlice(allocator, ",\"code\":");
                try buf.appendSlice(allocator, code_json);
            }
            try buf.appendSlice(allocator, "}");
        }
        try buf.appendSlice(allocator, "]}");

        return buf.toOwnedSlice(allocator);
    }
};

/// Write an RFC 7807 body for a handler (`ctx.json`, not `ctx.sendError`).
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
    try std.testing.expectEqualStrings("Content Too Large", ProblemDetails.statusTitle(413));
    try std.testing.expectEqualStrings("Request Header Fields Too Large", ProblemDetails.statusTitle(431));
    try std.testing.expectEqualStrings("Unknown Error", ProblemDetails.statusTitle(599));
}

test "ProblemDetails escapes untrusted detail" {
    const allocator = std.testing.allocator;

    // A validator message can carry user input verbatim; unescaped quotes used to
    // emit a body that no JSON parser accepts.
    const problem = ProblemDetails.init(422, "bad \"value\" from <script>\n\\end", "/x?q=\"1\"");
    const json = try problem.toJson(allocator);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bad \"value\" from <script>\n\\end", parsed.value.object.get("detail").?.string);
    try std.testing.expectEqualStrings("/x?q=\"1\"", parsed.value.object.get("instance").?.string);
}

test "ValidationProblem escapes field errors" {
    const allocator = std.testing.allocator;

    const errors = &[_]ValidationProblem.FieldError{
        .{ .field = "na\"me", .message = "tab\there", .code = "C\\D" },
    };
    const problem = ValidationProblem.init(422, "Validation failed", errors);
    const json = try problem.toJson(allocator);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const first = parsed.value.object.get("errors").?.array.items[0];
    try std.testing.expectEqualStrings("na\"me", first.object.get("field").?.string);
    try std.testing.expectEqualStrings("tab\there", first.object.get("message").?.string);
    try std.testing.expectEqualStrings("C\\D", first.object.get("code").?.string);
}

test "ProblemDetails.writeToBuf is allocation-free and truncates safely" {
    const problem = ProblemDetails.init(413, "Payload Too Large", null);

    var buf: [256]u8 = undefined;
    const body = problem.writeToBuf(&buf);
    try std.testing.expectEqualStrings("{\"status\":413,\"title\":\"Content Too Large\",\"detail\":\"Payload Too Large\"}", body);

    // Too small for the whole body: the writer stops at the boundary instead of
    // overrunning, so the transport path can always fall back to what it has.
    var tiny: [13]u8 = undefined;
    const truncated = problem.writeToBuf(&tiny);
    try std.testing.expectEqualStrings("{\"status\":413", truncated);
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
