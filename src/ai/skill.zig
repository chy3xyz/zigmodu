const std = @import("std");
const Time = @import("../core/Time.zig");
const guard_mod = @import("guard.zig");

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
    /// What kind of effect this tool has — the class `guard.Guard` checks
    /// before dispatch. **Default `execute`** (the most restricted): a tool that
    /// forgot to declare itself can never be granted by a read-only policy.
    action: guard_mod.Action = .execute,
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

/// What a `guard.Permissions` policy does to the tools that are actually
/// registered — judged by each tool's **declared class**, which is exactly what
/// `Guard`/`Permissions` cannot see.
///
/// `Permissions.isInert()` only asks "is `allow` empty?", so a policy that names
/// exclusively `execute` tools looks configured while `allow_execute = false`
/// makes every one of those calls `denied_execute_class`. This struct is the
/// registry-side answer to that blind spot: `class_denied` (and the names behind
/// it) is the count that must be zero for a policy to be worth deploying.
pub const PolicyHealth = struct {
    /// Registered tools examined. Zero means the audit had nothing to judge.
    total: usize = 0,
    /// Listed by the policy **and** admitted by its class gate.
    allowed: usize = 0,
    /// Listed by the policy, but refused by its own class gate
    /// (`denied_execute_class`) — the blind spot described above.
    class_denied: usize = 0,
    /// Not on the allow list.
    not_listed: usize = 0,
    /// On the deny list (`deny` beats `allow`).
    explicitly_denied: usize = 0,
    /// The names behind `class_denied`. **Borrowed from the registry** (name keys
    /// live as long as the registry does); only the outer slice is allocated.
    class_denied_tools: []const []const u8 = &.{},

    /// The policy cannot admit a single registered tool — whether because `allow`
    /// is empty (`Permissions.isInert()`) **or** because everything it lists is
    /// blocked by its class gate. Fail startup on this, not on the narrower
    /// `Guard.isInert()` alone.
    pub fn isInert(self: PolicyHealth) bool {
        if (self.total == 0) return false; // nothing registered: nothing to report
        return self.allowed == 0;
    }

    /// The policy names tools but the class gate refuses at least one of them.
    /// Log `class_denied_tools` at startup: the settings are not wrong, they are
    /// just not enough (`allow_execute`, or swap an `execute` tool for a
    /// `propose` one).
    pub fn hasClassBlindSpot(self: PolicyHealth) bool {
        return self.class_denied > 0;
    }

    pub fn deinit(self: *PolicyHealth, allocator: std.mem.Allocator) void {
        allocator.free(self.class_denied_tools);
        self.class_denied_tools = &.{};
    }
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
        return initCapacity(allocator, io, 32);
    }

    /// Init with capacity hint (max registered tools). Pre-allocates
    /// HashMap storage so runtime register() is infallible.
    pub fn initCapacity(allocator: std.mem.Allocator, io: std.Io, capacity: usize) Self {
        var tools = std.StringHashMap(Tool).init(allocator);
        tools.ensureTotalCapacity(@intCast(capacity)) catch |err| {
            std.log.warn("[ai.skill] pre-allocating {d} tools failed ({s}); register() may fail later", .{ capacity, @errorName(err) });
        };
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
        // Propagated, not waited out: `register` returns `!void` — a silent
        // success would tell the caller a tool is registered that never reached
        // the model (`toOpenAiFunctionsAlloc`/`auditPolicy` would not list it, and
        // `agent.zig` reads the registry before the guard judges a call).
        // Red: `ai.skill.test.canceled lock wait does not lose a register, get,
        // count or names`.
        self.mutex.lock(self.io) catch return error.RegistryLockFailed;
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
            .action = tool.action,
            .handler = tool.handler,
        };
        self.tools.putAssumeCapacity(key, owned);
    }

    /// Get a tool definition by name.
    pub fn get(self: *Self, name: []const u8) ?Tool {
        // Uncancelable: `null` here reads as "no such tool" (the guard in
        // `agent.zig` treats a missing tool as "let dispatch decide on an unknown
        // name"), so a canceled wait must not answer it. The signature is fixed
        // by that caller; one map lookup.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.tools.get(name);
    }

    pub fn count(self: *Self) usize {
        // Uncancelable: a fabricated `0` reads as "no tools registered". One map
        // count.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.tools.count();
    }

    /// List all tool names.
    pub fn names(self: *Self, buf: [][]const u8) usize {
        // Uncancelable: `0` reads as "the registry is empty" — and a short list
        // would silently drop registered tools from whatever is built from `buf`.
        // One walk.
        self.mutex.lockUncancelable(self.io);
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

    /// Audit a policy against the **declared classes** of the registered tools.
    ///
    /// `Guard` decides by name; this is the layer that can also see each tool's
    /// `action`, so it answers the question a name-only check cannot: *which
    /// registered tools does the class gate refuse even though the policy lists
    /// them?* Call it once at startup next to `Guard.isInert()` and fail loudly
    /// when `PolicyHealth.isInert()` or `hasClassBlindSpot()` is true.
    ///
    /// Free the result with `PolicyHealth.deinit` (`class_denied_tools` borrows
    /// the registry's own name keys, so nothing else is owned).
    pub fn auditPolicy(
        self: *Self,
        allocator: std.mem.Allocator,
        permissions: guard_mod.Permissions,
    ) !PolicyHealth {
        self.mutex.lock(self.io) catch return error.RegistryLockFailed;
        defer self.mutex.unlock(self.io);

        var health = PolicyHealth{};
        var denied = std.ArrayList([]const u8).empty;
        errdefer denied.deinit(allocator);

        var it = self.tools.iterator();
        while (it.next()) |entry| {
            const tool = entry.value_ptr.*;
            health.total += 1;
            switch (permissions.permits(tool.action, tool.name)) {
                .allowed => health.allowed += 1,
                .denied_execute_class => {
                    health.class_denied += 1;
                    try denied.append(allocator, tool.name);
                },
                .denied_not_listed => health.not_listed += 1,
                .denied_explicitly => health.explicitly_denied += 1,
                .denied_budget => unreachable, // produced by `Guard.check`, not `permits`
            }
        }
        health.class_denied_tools = try denied.toOwnedSlice(allocator);
        return health;
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

// ─────────────────────────────────────────────────
// Policy audit — declared classes vs. a policy (guard.zig)
// ─────────────────────────────────────────────────

/// Every builtin skill catalog, and the class each skill declares. Kept as a
/// table on purpose: a builtin that forgets `.action` falls back to `execute`
/// (fail-closed) and shows up here as a mismatch, instead of silently becoming
/// unreachable under `allow_execute = false`.
const builtin_classes = [_]struct { []const u8, guard_mod.Action }{
    .{ "db.query", .read },
    .{ "entity.lookup", .read },
    .{ "entity.list", .read },
    .{ "entity.create", .execute },
    .{ "entity.update", .execute },
    .{ "command.execute", .execute },
    .{ "report.generate", .read },
    .{ "list_schedulable_tasks", .read },
    .{ "schedule_job", .execute },
    .{ "list_jobs", .read },
    .{ "cancel_job", .execute },
    .{ "notification.send", .propose },
    .{ "kpi.query", .read },
    .{ "approval.submit", .propose },
    .{ "approval.request", .propose },
    .{ "admin.cache.invalidate", .execute },
    .{ "admin.cache.clear", .execute },
    .{ "admin.config.get", .read },
    .{ "admin.config.set", .execute },
    .{ "admin.audit.export", .read },
    .{ "admin.user.manage", .execute },
    .{ "admin.tenant.provision", .execute },
};

fn registerBuiltinCatalog(registry: *SkillRegistry) !void {
    const business = @import("business.zig");
    try business.registerBusinessSkills(registry, &[_]business.EntitySpec{});
    try @import("actions.zig").registerWriteSkills(registry);
    try @import("actions.zig").registerCommandSkills(registry);
    try @import("actions.zig").registerReportSkills(registry);
    try @import("schedule.zig").registerScheduleSkills(registry);
    try @import("notify.zig").registerNotifySkills(registry);
    try @import("kpi.zig").registerKpiSkills(registry);
    try @import("approval.zig").registerApprovalSkills(registry);
    try @import("approval_api.zig").registerApprovalRequestSkills(registry);
    try @import("admin.zig").registerAdminSkills(registry);
}

test "builtin skills declare their action class" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();
    try registerBuiltinCatalog(&reg);

    // 1:1 — an unclassified builtin (defaulting to `.execute`) fails here.
    try std.testing.expectEqual(builtin_classes.len, reg.count());
    for (builtin_classes) |entry| {
        const tool = reg.get(entry[0]) orelse {
            std.debug.print("missing builtin skill: {s}\n", .{entry[0]});
            return error.TestUnexpectedResult;
        };
        if (tool.action != entry[1]) {
            std.debug.print("builtin {s} declares {s}, expected {s}\n", .{
                entry[0], @tagName(tool.action), @tagName(entry[1]),
            });
            return error.TestUnexpectedResult;
        }
    }
}

test "auditPolicy: a read-only policy admits read tools and kills nothing by class" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();
    try registerBuiltinCatalog(&reg);

    // Exactly the policy docs/AGENT_RUNTIME.md §二 recommends: name the read
    // tools, leave execution off.
    var allow: [builtin_classes.len][]const u8 = undefined;
    var n: usize = 0;
    for (builtin_classes) |entry| {
        if (entry[1] == .read) {
            allow[n] = entry[0];
            n += 1;
        }
    }
    const perms = guard_mod.Permissions{ .allow = allow[0..n] }; // allow_execute = false

    // (i) a read tool really is permitted by the guard, and it is read *because*
    //     the builtin declared so.
    try std.testing.expectEqual(guard_mod.Action.read, reg.get("db.query").?.action);
    var guard = guard_mod.Guard.init(perms);
    try std.testing.expectEqual(guard_mod.Decision.allowed, guard.check(.read, "db.query", 0));
    // The class axis only narrows: a propose tool needs its own name, and an
    // unlisted `execute` reports `denied_not_listed` (its class is not yet the
    // binding reason) — see `guard.Permissions.permits`.
    try std.testing.expectEqual(guard_mod.Decision.denied_not_listed, guard.check(.propose, "notification.send", 0));
    try std.testing.expectEqual(guard_mod.Decision.denied_not_listed, guard.check(.execute, "schedule_job", 0));

    // (ii) the audit reports the policy as usable: read tools live, nothing
    //      refused by its own class gate.
    var health = try reg.auditPolicy(allocator, perms);
    defer health.deinit(allocator);
    try std.testing.expectEqual(builtin_classes.len, health.total);
    try std.testing.expectEqual(n, health.allowed);
    try std.testing.expectEqual(@as(usize, 0), health.class_denied);
    try std.testing.expect(!health.hasClassBlindSpot());
    try std.testing.expect(!health.isInert());
    try std.testing.expectEqual(@as(usize, 0), health.class_denied_tools.len);
}

test "auditPolicy: an execute-only allow list is a class blind spot isInert() misses" {
    const allocator = std.testing.allocator;
    var reg = SkillRegistry.init(allocator, std.testing.io);
    defer reg.deinit();
    try registerBuiltinCatalog(&reg);

    // The trap: a policy that *looks* configured but lists only `execute` tools
    // while `allow_execute` is off.
    const perms = guard_mod.Permissions{
        .allow = &.{ "schedule_job", "admin.config.set" },
    };
    try std.testing.expectEqual(guard_mod.Action.execute, reg.get("schedule_job").?.action);

    // `Permissions.isInert()` cannot see it (allow is not empty) …
    try std.testing.expect(!perms.isInert());

    // … the registry-side audit can, and names the tools it refuses.
    var health = try reg.auditPolicy(allocator, perms);
    defer health.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), health.allowed);
    try std.testing.expectEqual(@as(usize, 2), health.class_denied);
    try std.testing.expect(health.hasClassBlindSpot());
    try std.testing.expect(health.isInert());
    try std.testing.expectEqual(@as(usize, 2), health.class_denied_tools.len);
    var saw_job = false;
    for (health.class_denied_tools) |name| {
        if (std.mem.eql(u8, name, "schedule_job")) saw_job = true;
    }
    try std.testing.expect(saw_job);

    // Flipping the switch is the fix, and `deny` still wins over the class gate.
    var switched = try reg.auditPolicy(allocator, .{ .allow = perms.allow, .deny = &.{"schedule_job"}, .allow_execute = true });
    defer switched.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), switched.allowed);
    try std.testing.expectEqual(@as(usize, 1), switched.explicitly_denied);
    try std.testing.expectEqual(@as(usize, 0), switched.class_denied);

    // An empty registry has nothing to judge (`total == 0`) — it must not be
    // reported as an inert policy.
    var empty = SkillRegistry.init(allocator, std.testing.io);
    defer empty.deinit();
    var empty_health = try empty.auditPolicy(allocator, perms);
    defer empty_health.deinit(allocator);
    try std.testing.expect(!empty_health.isInert());
}

fn pingHandler(ctx: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
    _ = ctx;
    return .{ .string = "pong" };
}

fn echoHandler(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
    _ = ctx;
    return args.object.get("text").?;
}

/// Park `read` on `mutex` with a cancel request already placed on its thread, then
/// let it through: the lock wait becomes the cancelation point. `std.Io.Mutex.lock`'s
/// uncontended fast path does not check for cancellation, so it is the contended
/// wait that can come back canceled.
fn readUnderCanceledLockWait(
    comptime T: type,
    target: *T,
    mutex: *std.Io.Mutex,
    io: std.Io,
    comptime read: fn (*T) void,
) !void {
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn run(t: *T) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            read(t);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.entered.store(false, .monotonic);
    Gate.open.store(false, .monotonic);

    try mutex.lock(io);

    var read_fut = try io.concurrent(Gate.run, .{target});
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    while (mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);
}

// The registry's four lock-wait sites, split by whether the caller can be told:
//   - `register` returns `!void`, so the canceled wait is *propagated*
//     (`error.RegistryLockFailed`, the name `dispatchWith`/`auditPolicy` already
//     use) — a silent success would mean a tool the caller believes is registered
//     never reaches the model, and `agent.zig` reads the registry to decide
//     whether a tool even exists before the guard judges it;
//   - `get`, `count` and `names` return `?Tool`/`usize`, where `null`/`0` read as
//     "no such tool"/"empty registry" — the registry cannot fabricate those, and
//     `get`'s signature is fixed by its caller (`agent.zig:481`), so they wait
//     (`lockUncancelable`); each critical section is a map lookup or a walk.
//
// Red evidence: with the old shapes the first assertion below fails —
// `expected error.RegistryLockFailed, found null`, because the canceled `register`
// returned success without registering anything. The `get`/`count`/`names`
// assertions after it are the same lock shape; a `try` ends the test at the first
// failure, so those three are only exercised green.
test "canceled lock wait does not lose a register, get, count or names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var reg = SkillRegistry.init(allocator, io);
    defer reg.deinit();

    const RegisterRead = struct {
        var seen: ?anyerror = null;
        fn read(r: *SkillRegistry) void {
            seen = null;
            r.register(.{
                .name = "ping",
                .description = "Returns pong",
                .parameters = &.{},
                .handler = pingHandler,
            }) catch |err| {
                seen = err;
            };
        }
    };
    RegisterRead.seen = null;
    try readUnderCanceledLockWait(SkillRegistry, &reg, &reg.mutex, io, RegisterRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.RegistryLockFailed), RegisterRead.seen);
    try std.testing.expectEqual(@as(usize, 0), reg.count());

    try reg.register(.{
        .name = "ping",
        .description = "Returns pong",
        .parameters = &.{},
        .handler = pingHandler,
    });

    const GetRead = struct {
        var found: bool = false;
        fn read(r: *SkillRegistry) void {
            found = r.get("ping") != null;
        }
    };
    GetRead.found = false;
    try readUnderCanceledLockWait(SkillRegistry, &reg, &reg.mutex, io, GetRead.read);
    try std.testing.expect(GetRead.found);

    const CountRead = struct {
        var seen: usize = 0;
        fn read(r: *SkillRegistry) void {
            seen = r.count();
        }
    };
    CountRead.seen = 0;
    try readUnderCanceledLockWait(SkillRegistry, &reg, &reg.mutex, io, CountRead.read);
    try std.testing.expectEqual(@as(usize, 1), CountRead.seen);

    const NamesRead = struct {
        var seen: usize = 0;
        fn read(r: *SkillRegistry) void {
            var buf: [4][]const u8 = undefined;
            seen = r.names(&buf);
        }
    };
    NamesRead.seen = 0;
    try readUnderCanceledLockWait(SkillRegistry, &reg, &reg.mutex, io, NamesRead.read);
    try std.testing.expectEqual(@as(usize, 1), NamesRead.seen);
}
