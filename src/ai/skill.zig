const std = @import("std");
const Time = @import("../core/Time.zig");

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
    /// Soft per-tool budget (ms). Handlers should poll `SkillContext.expired()`.
    /// Post-return overrun also yields `error.ToolTimeout` (does not preempt).
    timeout_ms: ?u64 = null,
    /// Required permission code (e.g. `approval:decide`). When set, dispatch
    /// refuses with `error.PermissionDenied` unless `SkillContext.permissions`
    /// contains it.
    required_permission: ?[]const u8 = null,
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
    /// Optional capability pointer for builtin skills (e.g. *Cron.Scheduler
    /// for the schedule bridge). Set by the caller before dispatch.
    userdata: ?*anyopaque = null,
    /// Permission codes granted to this context (checked against
    /// `Tool.required_permission`).
    permissions: []const []const u8 = &.{},
    /// Absolute deadline from `Time.monotonicNowMilliseconds()`; set by dispatch.
    deadline_ms: ?i64 = null,

    pub fn expired(self: *const SkillContext) bool {
        const d = self.deadline_ms orelse return false;
        return Time.monotonicNowMilliseconds() > d;
    }

    pub fn checkDeadline(self: *const SkillContext) !void {
        if (self.expired()) return error.ToolTimeout;
    }
};

pub const DispatchOpts = struct {
    allowlist: ?[]const []const u8 = null,
    /// Override tool.timeout_ms for this call (cooperative + post-check).
    timeout_ms: ?u64 = null,
};

/// Free a dispatch result produced by a skill handler. Convention: handlers
/// own every string in the result (dupe literals and row values with the
/// SkillContext allocator); object keys are freed by ObjectMap.put semantics.
pub fn freeValue(allocator: std.mem.Allocator, v: std.json.Value) void {
    var value = v;
    switch (value) {
        .string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |item| freeValue(allocator, item);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr.*);
            }
            obj.deinit(allocator);
        },
        else => {},
    }
}

/// Registry that aggregates Tool definitions from all modules.
/// Thread-safe via std.Io.Mutex (same fiber model as ConnectionRegistry).
pub const SkillRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    tools: std.StringHashMap(Tool),
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return initCapacity(allocator, io, 32);
    }

    /// Init with capacity hint (max registered tools). Pre-allocates
    /// HashMap storage so runtime register() is infallible.
    pub fn initCapacity(allocator: std.mem.Allocator, io: std.Io, capacity: usize) Self {
        var tools = std.StringHashMap(Tool).init(allocator);
        tools.ensureTotalCapacity(@intCast(capacity)) catch {};
        return .{
            .allocator = allocator,
            .io = io,
            .tools = tools,
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
        self.* = undefined;
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
            .timeout_ms = tool.timeout_ms,
            .required_permission = tool.required_permission,
            .handler = tool.handler,
        };
        self.tools.putAssumeCapacity(key, owned);
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
    pub fn names(self: *Self, buf: [][]const u8) usize {
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

    /// Generate OpenAI-compatible tools JSON (owned slice).
    pub fn toOpenAiFunctionsAlloc(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock(self.io) catch return error.RegistryLockFailed;
        defer self.mutex.unlock(self.io);

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try buf.append(allocator, '[');
        var first = true;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            const t = entry.value_ptr;
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.print(allocator, "{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{{\"type\":\"object\",\"properties\":{{", .{ t.name, t.description });
            for (t.parameters, 0..) |p, pi| {
                if (pi > 0) try buf.append(allocator, ',');
                try buf.print(allocator, "\"{s}\":{{\"type\":\"{s}\",\"description\":\"{s}\"}}", .{ p.name, @tagName(p.type), p.description });
            }
            try buf.appendSlice(allocator, "},\"required\":[");
            var req_first = true;
            for (t.parameters) |p| {
                if (p.required) {
                    if (!req_first) try buf.append(allocator, ',');
                    req_first = false;
                    try buf.print(allocator, "\"{s}\"", .{p.name});
                }
            }
            try buf.appendSlice(allocator, "]}}}");
        }
        try buf.append(allocator, ']');
        return try buf.toOwnedSlice(allocator);
    }

    /// Generate OpenAI-compatible function calling JSON via writer.interface.writeAll.
    pub fn toOpenAiFunctions(self: *Self, writer: anytype) !void {
        const json = try self.toOpenAiFunctionsAlloc(self.allocator);
        defer self.allocator.free(json);
        try writer.interface.writeAll(json);
    }

    /// Validate required parameters against a JSON object.
    pub fn validateArgs(tool: Tool, args: std.json.Value) !void {
        if (tool.parameters.len == 0) return;
        if (args == .null) return error.MissingToolArg;
        if (args != .object) return error.InvalidToolArgs;
        for (tool.parameters) |p| {
            if (p.required and args.object.get(p.name) == null) return error.MissingToolArg;
        }
    }

    /// Dispatch with optional name allowlist (security boundary).
    pub fn dispatchAllowed(
        self: *Self,
        name: []const u8,
        ctx: *SkillContext,
        args: std.json.Value,
        allowlist: ?[]const []const u8,
    ) !std.json.Value {
        return self.dispatchWith(name, ctx, args, .{ .allowlist = allowlist });
    }

    /// Dispatch a tool call by name (validates required params).
    pub fn dispatch(self: *Self, name: []const u8, ctx: *SkillContext, args: std.json.Value) !std.json.Value {
        return self.dispatchWith(name, ctx, args, .{});
    }

    /// Dispatch with allowlist + cooperative timeout skeleton.
    pub fn dispatchWith(
        self: *Self,
        name: []const u8,
        ctx: *SkillContext,
        args: std.json.Value,
        opts: DispatchOpts,
    ) !std.json.Value {
        if (opts.allowlist) |al| {
            var ok = false;
            for (al) |n| {
                if (std.mem.eql(u8, n, name)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) return error.ToolNotAllowed;
        }

        self.mutex.lock(self.io) catch return error.RegistryLockFailed;
        const tool = self.tools.get(name) orelse {
            self.mutex.unlock(self.io);
            return error.ToolNotFound;
        };
        if (tool.required_permission) |perm| {
            var granted = false;
            for (ctx.permissions) |p| {
                if (std.mem.eql(u8, p, perm)) {
                    granted = true;
                    break;
                }
            }
            if (!granted) {
                self.mutex.unlock(self.io);
                return error.PermissionDenied;
            }
        }
        try validateArgs(tool, args);
        const handler = tool.handler;
        const budget = opts.timeout_ms orelse tool.timeout_ms;
        self.mutex.unlock(self.io);

        const prev_deadline = ctx.deadline_ms;
        defer ctx.deadline_ms = prev_deadline;
        const started = Time.monotonicNowMilliseconds();
        if (budget) |ms| {
            ctx.deadline_ms = started + @as(i64, @intCast(ms));
        } else {
            ctx.deadline_ms = null;
        }

        const result = try handler(ctx, args);
        if (budget) |ms| {
            const elapsed: u64 = @intCast(@max(Time.monotonicNowMilliseconds() - started, 0));
            if (elapsed > ms) return error.ToolTimeout;
        }
        try ctx.checkDeadline();
        return result;
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

test "SkillRegistry required_permission gates dispatch" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();
    try reg.register(.{
        .name = "approve",
        .description = "approve",
        .parameters = &.{},
        .required_permission = "approval:decide",
        .handler = struct {
            fn h(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                return .{ .bool = true };
            }
        }.h,
    });

    var no_perm = SkillContext{ .allocator = allocator };
    try std.testing.expectError(error.PermissionDenied, reg.dispatch("approve", &no_perm, .null));

    const perms = [_][]const u8{"approval:decide"};
    var with_perm = SkillContext{ .allocator = allocator, .permissions = &perms };
    const res = try reg.dispatch("approve", &with_perm, .null);
    try std.testing.expectEqual(@as(bool, true), res.bool);
}

test "SkillRegistry allowlist and required args" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    try reg.register(.{
        .name = "echo",
        .description = "echo",
        .parameters = &.{.{ .name = "text", .type = .string, .description = "t", .required = true }},
        .handler = echoHandler,
    });

    var ctx = SkillContext{ .allocator = allocator };
    try std.testing.expectError(error.ToolNotAllowed, reg.dispatchAllowed("echo", &ctx, .null, &.{"other"}));

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"text\":\"hi\"}", .{});
    defer parsed.deinit();
    const ok = try reg.dispatchAllowed("echo", &ctx, parsed.value, &.{"echo"});
    try std.testing.expectEqualStrings("hi", ok.string);
}

test "SkillRegistry cooperative deadline" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    try reg.register(.{
        .name = "slow",
        .description = "checks deadline",
        .parameters = &.{},
        .timeout_ms = 1,
        .handler = struct {
            fn h(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                ctx.deadline_ms = Time.monotonicNowMilliseconds() - 1;
                try ctx.checkDeadline();
                return .{ .string = "late" };
            }
        }.h,
    });

    var ctx = SkillContext{ .allocator = allocator };
    try std.testing.expectError(error.ToolTimeout, reg.dispatch("slow", &ctx, .null));
}

fn pingHandler(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
    _ = ctx;
    return .{ .string = "pong" };
}

fn echoHandler(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
    _ = ctx;
    return args.object.get("text").?;
}
