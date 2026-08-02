//! Admin / ops skills ("AI 管理运维"): app-registered, whitelisted and
//! **off by default** — these tools must be explicitly added to an Agent's
//! allowlist to be reachable, and each requires a permission code.
//!
//!   - `admin.cache.invalidate` / `admin.cache.clear` — whitelisted caches
//!     only; keys reject wildcards (`*`/`?`); `all=true` is the explicit
//!     opt-in for a full clear (never implicit);
//!   - `admin.config.get` / `admin.config.set` — whitelisted config keys,
//!     `set` only for mutable keys;
//!   - `admin.audit.export` — query the durable run-audit store
//!     (`RunAuditStore`) with optional kind/tenant filters;
//!   - `admin.user.manage` / `admin.tenant.provision` — app callbacks
//!     (framework never implements business user/tenant logic).

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const run_audit = @import("run_audit.zig");
const freeValue = @import("skill.zig").freeValue;

pub const CacheHandle = struct {
    name: []const u8,
    delete: *const fn (userdata: *anyopaque, key: []const u8) void,
    clear: *const fn (userdata: *anyopaque) void,
    userdata: *anyopaque,
};

/// In-memory config store; `set` respects the mutable-keys whitelist.
pub const ConfigStore = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    values: std.StringHashMap([]const u8),
    mutable: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, mutable: []const []const u8) Self {
        return .{ .allocator = allocator, .values = std.StringHashMap([]const u8).init(allocator), .mutable = mutable };
    }

    pub fn deinit(self: *Self) void {
        var it = self.values.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.values.deinit();
        self.* = undefined;
    }

    pub fn set(self: *Self, key: []const u8, value: []const u8) !bool {
        var mutable = false;
        for (self.mutable) |k| {
            if (std.mem.eql(u8, k, key)) {
                mutable = true;
                break;
            }
        }
        if (!mutable) return false;
        if (self.values.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.values.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
        return true;
    }

    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }
};

/// App callback for `admin.user.manage` / `admin.tenant.provision`.
/// Returns a JSON value the skill forwards to the caller.
pub const AppAdminFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    action: []const u8,
    args: std.json.Value,
) anyerror!std.json.Value;

pub const AdminCtx = struct {
    backend: *SqlxBackend,
    caches: []const CacheHandle = &.{},
    config: ?*ConfigStore = null,
    user_handler: ?AppAdminFn = null,
    tenant_handler: ?AppAdminFn = null,
};

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

fn hasWildcard(key: []const u8) bool {
    return std.mem.indexOfAny(u8, key, "*?") != null;
}

fn findCache(caches: []const CacheHandle, name: []const u8) ?CacheHandle {
    for (caches) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

pub fn registerAdminSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "admin.cache.invalidate",
        .description = "Delete one key from a whitelisted cache; wildcards are rejected (use admin.cache.clear with all=true for a full clear)",
        .required_permission = "admin:cache",
        .parameters = &.{
            .{ .name = "cache", .type = .string, .description = "Whitelisted cache name", .required = true },
            .{ .name = "key", .type = .string, .description = "Exact cache key (no * or ?)", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *AdminCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.AdminNotConfigured));
                const obj = args.object;
                const cache_v = obj.get("cache") orelse return error.InvalidArguments;
                const key_v = obj.get("key") orelse return error.InvalidArguments;
                if (cache_v != .string or key_v != .string) return error.InvalidArguments;
                if (hasWildcard(key_v.string)) return error.WildcardForbidden;
                const handle = findCache(ac.caches, cache_v.string) orelse return error.CacheNotAllowed;
                handle.delete(handle.userdata, key_v.string);
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "ok", .{ .bool = true });
                try putOwned(&out, sctx.allocator, "cache", .{ .string = try sctx.allocator.dupe(u8, cache_v.string) });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.cache.clear",
        .description = "Fully clear a whitelisted cache (requires explicit all=true)",
        .required_permission = "admin:cache",
        .parameters = &.{
            .{ .name = "cache", .type = .string, .description = "Whitelisted cache name", .required = true },
            .{ .name = "all", .type = .boolean, .description = "Must be true", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *AdminCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.AdminNotConfigured));
                const obj = args.object;
                const cache_v = obj.get("cache") orelse return error.InvalidArguments;
                const all_v = obj.get("all") orelse return error.InvalidArguments;
                if (cache_v != .string or all_v != .bool or !all_v.bool) return error.InvalidArguments;
                const handle = findCache(ac.caches, cache_v.string) orelse return error.CacheNotAllowed;
                handle.clear(handle.userdata);
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "ok", .{ .bool = true });
                try putOwned(&out, sctx.allocator, "cleared", .{ .bool = true });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.config.get",
        .description = "Read a whitelisted configuration value",
        .required_permission = "admin:config",
        .parameters = &.{
            .{ .name = "key", .type = .string, .description = "Config key", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *AdminCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.AdminNotConfigured));
                const store = ac.config orelse return error.ConfigNotConfigured;
                const obj = args.object;
                const key_v = obj.get("key") orelse return error.InvalidArguments;
                if (key_v != .string) return error.InvalidArguments;
                const value = store.get(key_v.string) orelse return error.ConfigKeyNotFound;
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "key", .{ .string = try sctx.allocator.dupe(u8, key_v.string) });
                try putOwned(&out, sctx.allocator, "value", .{ .string = try sctx.allocator.dupe(u8, value) });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.config.set",
        .description = "Set a mutable configuration value (mutable-keys whitelist)",
        .required_permission = "admin:config",
        .parameters = &.{
            .{ .name = "key", .type = .string, .description = "Config key", .required = true },
            .{ .name = "value", .type = .string, .description = "New value", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *AdminCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.AdminNotConfigured));
                const store = ac.config orelse return error.ConfigNotConfigured;
                const obj = args.object;
                const key_v = obj.get("key") orelse return error.InvalidArguments;
                const value_v = obj.get("value") orelse return error.InvalidArguments;
                if (key_v != .string or value_v != .string) return error.InvalidArguments;
                if (!try store.set(key_v.string, value_v.string)) return error.ConfigKeyReadOnly;
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "ok", .{ .bool = true });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.audit.export",
        .description = "Query the durable AI run-audit store (optional kind/tenant filters)",
        .required_permission = "admin:audit",
        .parameters = &.{
            .{ .name = "kind", .type = .string, .description = "workflow | agent | approval (optional)", .required = false },
            .{ .name = "tenant_id", .type = .number, .description = "Tenant filter (optional)", .required = false },
            .{ .name = "limit", .type = .number, .description = "Max rows (default 20)", .required = false },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *AdminCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.AdminNotConfigured));
                const obj = args.object;
                const kind = if (obj.get("kind")) |k| std.meta.stringToEnum(run_audit.RunKind, k.string) else null;
                const tenant = if (obj.get("tenant_id")) |t| t.integer else null;
                const limit: usize = if (obj.get("limit")) |l| @intCast(@min(l.integer, 100)) else 20;
                var store = run_audit.RunAuditStore.init(sctx.allocator, ac.backend);
                var entries = std.ArrayList(run_audit.RunAuditEntry).empty;
                defer {
                    for (entries.items) |e| {
                        sctx.allocator.free(e.run_id);
                        sctx.allocator.free(e.status);
                    }
                    entries.deinit(sctx.allocator);
                }
                try store.list(sctx.allocator, &entries, kind, tenant, limit);
                var arr = std.json.Array.init(sctx.allocator);
                for (entries.items) |e| {
                    var rec = std.json.ObjectMap{};
                    try putOwned(&rec, sctx.allocator, "run_id", .{ .string = try sctx.allocator.dupe(u8, e.run_id) });
                    try putOwned(&rec, sctx.allocator, "kind", .{ .string = try sctx.allocator.dupe(u8, @tagName(e.kind)) });
                    try putOwned(&rec, sctx.allocator, "status", .{ .string = try sctx.allocator.dupe(u8, e.status) });
                    try putOwned(&rec, sctx.allocator, "steps", .{ .integer = @intCast(e.steps) });
                    if (e.tenant_id) |tid| try putOwned(&rec, sctx.allocator, "tenant_id", .{ .integer = tid });
                    try arr.append(.{ .object = rec });
                }
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "runs", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.user.manage",
        .description = "Delegate a user-management action to the application handler",
        .required_permission = "admin:user",
        .parameters = &.{
            .{ .name = "action", .type = .string, .description = "Application-defined action", .required = true },
            .{ .name = "args", .type = .object, .description = "Application-defined arguments", .required = false },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *AdminCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.AdminNotConfigured));
                const handler = ac.user_handler orelse return error.UserHandlerNotConfigured;
                const obj = args.object;
                const action = (obj.get("action") orelse return error.InvalidArguments).string;
                const payload = obj.get("args") orelse .null;
                return handler(sctx.allocator, sctx, action, payload);
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.tenant.provision",
        .description = "Delegate a tenant-provisioning action to the application handler",
        .required_permission = "admin:tenant",
        .parameters = &.{
            .{ .name = "action", .type = .string, .description = "Application-defined action", .required = true },
            .{ .name = "args", .type = .object, .description = "Application-defined arguments", .required = false },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const ac: *AdminCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.AdminNotConfigured));
                const handler = ac.tenant_handler orelse return error.TenantHandlerNotConfigured;
                const obj = args.object;
                const action = (obj.get("action") orelse return error.InvalidArguments).string;
                const payload = obj.get("args") orelse .null;
                return handler(sctx.allocator, sctx, action, payload);
            }
        }.h,
    });
}

test "admin.cache.invalidate rejects wildcards and unknown caches" {
    const allocator = std.testing.allocator;
    const State = struct {
        var deleted: usize = 0;
        var cleared: usize = 0;
    };
    var dummy: u8 = 0;
    const handles = [_]CacheHandle{
        .{
            .name = "orders",
            .delete = struct {
                fn f(_: *anyopaque, _: []const u8) void {
                    State.deleted += 1;
                }
            }.f,
            .clear = struct {
                fn f(_: *anyopaque) void {
                    State.cleared += 1;
                }
            }.f,
            .userdata = &dummy,
        },
    };
    var admin_ctx = AdminCtx{ .backend = undefined, .caches = &handles };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerAdminSkills(&registry);
    const perms = [_][]const u8{"admin:cache"};
    var sctx = SkillContext{ .allocator = allocator, .userdata = &admin_ctx, .permissions = &perms };

    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "cache", .{ .string = try allocator.dupe(u8, "orders") });
    try putOwned(&args_map, allocator, "key", .{ .string = try allocator.dupe(u8, "order:1") });
    const res = try registry.dispatch("admin.cache.invalidate", &sctx, .{ .object = args_map });
    defer freeValue(allocator, res);
    defer freeValue(allocator, .{ .object = args_map });
    try std.testing.expectEqual(@as(usize, 1), State.deleted);

    // Wildcard rejected.
    var bad_map = std.json.ObjectMap{};
    try putOwned(&bad_map, allocator, "cache", .{ .string = try allocator.dupe(u8, "orders") });
    try putOwned(&bad_map, allocator, "key", .{ .string = try allocator.dupe(u8, "order:*") });
    defer freeValue(allocator, .{ .object = bad_map });
    try std.testing.expectError(error.WildcardForbidden, registry.dispatch("admin.cache.invalidate", &sctx, .{ .object = bad_map }));
}

test "admin.config.set respects the mutable whitelist" {
    const allocator = std.testing.allocator;
    const mutable = [_][]const u8{"feature.flag"};
    var store = ConfigStore.init(allocator, &mutable);
    defer store.deinit();
    var admin_ctx = AdminCtx{ .backend = undefined, .config = &store };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerAdminSkills(&registry);
    const perms = [_][]const u8{"admin:config"};
    var sctx = SkillContext{ .allocator = allocator, .userdata = &admin_ctx, .permissions = &perms };

    var ok_map = std.json.ObjectMap{};
    try putOwned(&ok_map, allocator, "key", .{ .string = try allocator.dupe(u8, "feature.flag") });
    try putOwned(&ok_map, allocator, "value", .{ .string = try allocator.dupe(u8, "true") });
    defer freeValue(allocator, .{ .object = ok_map });
    const res = try registry.dispatch("admin.config.set", &sctx, .{ .object = ok_map });
    defer freeValue(allocator, res);
    try std.testing.expectEqualStrings("true", store.get("feature.flag").?);

    // Immutable key rejected.
    var bad_map = std.json.ObjectMap{};
    try putOwned(&bad_map, allocator, "key", .{ .string = try allocator.dupe(u8, "db.url") });
    try putOwned(&bad_map, allocator, "value", .{ .string = try allocator.dupe(u8, "x") });
    defer freeValue(allocator, .{ .object = bad_map });
    try std.testing.expectError(error.ConfigKeyReadOnly, registry.dispatch("admin.config.set", &sctx, .{ .object = bad_map }));
}

test "admin.audit.export lists runs with filters" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = run_audit.RunAuditStore.init(allocator, &backend);
    try store.migrate();
    try store.record(.{ .run_id = "r1", .kind = .workflow, .status = "completed", .tenant_id = 1, .steps = 2, .duration_ms = 3 });
    try store.record(.{ .run_id = "r2", .kind = .agent, .status = "completed", .tenant_id = 2, .steps = 1, .duration_ms = 1 });

    var admin_ctx = AdminCtx{ .backend = &backend };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerAdminSkills(&registry);
    const perms = [_][]const u8{"admin:audit"};
    var sctx = SkillContext{ .allocator = allocator, .userdata = &admin_ctx, .permissions = &perms };

    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "kind", .{ .string = try allocator.dupe(u8, "workflow") });
    defer freeValue(allocator, .{ .object = args_map });
    const res = try registry.dispatch("admin.audit.export", &sctx, .{ .object = args_map });
    defer freeValue(allocator, res);
    try std.testing.expectEqual(@as(usize, 1), res.object.get("runs").?.array.items.len);
    try std.testing.expectEqualStrings("r1", res.object.get("runs").?.array.items[0].object.get("run_id").?.string);
}
