const std = @import("std");

/// Parameter definition for a Tool — maps to JSON Schema for LLM function calling.
pub const Param = struct {
    name: []const u8,
    type: Type,
    description: []const u8,
    required: bool = false,

    pub const Type = enum { string, number, boolean, array, object };
};

/// A callable tool exposed to AI Agents.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const Param,
    /// Handler: receives context + JSON value of arguments, returns JSON result.
    handler: *const fn (ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value,
};

/// Context in which a skill executes. Carries tenant + user identity.
pub const SkillContext = struct {
    allocator: std.mem.Allocator,
    tenant_id: ?i64 = null,
    user_id: ?i64 = null,
    backend_ptr: ?*anyopaque = null, // *data.SqlxBackend for DB skills
    run_id: ?[]const u8 = null,
};

/// Registry that aggregates Tool definitions from all modules.
/// Thread-safe via std.Io.Mutex (same fiber model as ConnectionRegistry).
pub const SkillRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    tools: std.StringHashMap(Tool),
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .tools = std.StringHashMap(Tool).init(allocator),
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.parameters) |p| self.allocator.free(p.name);
            self.allocator.free(entry.value_ptr.parameters);
        }
        self.tools.deinit();
    }

    /// Register a tool. Duplicate names are replaced.
    pub fn register(self: *Self, tool: Tool) !void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        const key = try self.allocator.dupe(u8, tool.name);
        // Deep copy parameters
        const params = try self.allocator.alloc(Param, tool.parameters.len);
        for (tool.parameters, 0..) |p, i| {
            params[i] = .{
                .name = try self.allocator.dupe(u8, p.name),
                .type = p.type,
                .description = p.description,
                .required = p.required,
            };
        }
        const owned = Tool{
            .name = key,
            .description = tool.description,
            .parameters = params,
            .handler = tool.handler,
        };
        try self.tools.put(key, owned);
    }

    /// Dispatch a tool call by name.
    pub fn dispatch(self: *Self, name: []const u8, ctx: *SkillContext, args: std.json.Value) !std.json.Value {
        self.mutex.lock(self.io) catch return error.RegistryLockFailed;
        defer self.mutex.unlock(self.io);

        const tool = self.tools.get(name) orelse return error.ToolNotFound;
        return try tool.handler(ctx, args);
    }

    /// Get a tool definition by name.
    pub fn get(self: *Self, name: []const u8) ?Tool {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);
        return self.tools.get(name);
    }

    pub fn count(self: *Self) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.tools.count();
    }

    /// List all tool names.
    pub fn names(self: *Self, buf: []const []const u8) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);

        var n: usize = 0;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            if (n >= buf.len) break;
            buf[n] = entry.key_ptr.*;
            n += 1;
        }
        return n;
    }

    /// Generate OpenAI-compatible function calling JSON.
    pub fn toOpenAiFunctions(self: *Self, writer: anytype) !void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        try writer.writeAll("[");
        var first = true;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            const t = entry.value_ptr;
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{{\"type\":\"object\",\"properties\":{{", .{ t.name, t.description });
            for (t.parameters, 0..) |p, pi| {
                if (pi > 0) try writer.writeAll(",");
                try writer.print("\"{s}\":{{\"type\":\"{s}\",\"description\":\"{s}\"}}", .{ p.name, @tagName(p.type), p.description });
            }
            try writer.writeAll("},\"required\":[");
            var req_first = true;
            for (t.parameters) |p| {
                if (p.required) {
                    if (!req_first) try writer.writeAll(",");
                    req_first = false;
                    try writer.print("\"{s}\"", .{p.name});
                }
            }
            try writer.writeAll("]}}}}");
        }
        try writer.writeAll("]");
    }
};

test "SkillRegistry register and dispatch" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    try reg.register(.{
        .name = "ping",
        .description = "Returns pong",
        .parameters = &.{},
        .handler = pingHandler,
    });

    try std.testing.expectEqual(@as(usize, 1), reg.count());

    var ctx = SkillContext{ .allocator = allocator };
    const result = try reg.dispatch("ping", &ctx, .null);
    try std.testing.expectEqualStrings("pong", result.string);
}

test "SkillRegistry unknown tool" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var ctx = SkillContext{ .allocator = allocator };
    try std.testing.expectError(error.ToolNotFound, reg.dispatch("nonexistent", &ctx, .null));
}

fn pingHandler(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
    _ = ctx;
    return .{ .string = "pong" };
}
