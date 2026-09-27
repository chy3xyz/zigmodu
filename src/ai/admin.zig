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
const SqlxBackend = @import("../data.zig").SqlxBackend;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const run_audit = @import("run_audit.zig");
const freeValue = @import("skill.zig").freeValue;
const putJsonField = @import("skill.zig").putJsonField;
const json_shape = @import("json_shape.zig");

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
        // Each copy is guarded on its own until the `put` takes it: built as
        // `put` arguments, the key copy was stranded when the value copy
        // failed, and both were stranded when the `put` itself failed.
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.values.put(key_copy, value_copy);
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
    // The key copy needs its own guard: built as the `put` argument it was
    // stranded whenever the map refused the field. The disarmed-by-`return`
    // guard leaves the value's contract alone — a `.string` here is still
    // owned by the caller.
    const k = try allocator.dupe(u8, key);
    errdefer allocator.free(k);
    try obj.put(allocator, k, value);
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
        .action = .execute,
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
                // The string field goes through `putJsonField`, which copies the
                // value itself and frees that copy if the map refuses the field —
                // a `dupe` built as the `put` argument had nothing to guard it.
                // This guard covers the fields already placed, and the `return`
                // below disarms it at the hand-over.
                errdefer freeValue(sctx.allocator, .{ .object = out });
                try putOwned(&out, sctx.allocator, "ok", .{ .bool = true });
                try putJsonField(sctx.allocator, &out, "cache", .{ .string = cache_v.string });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.cache.clear",
        .action = .execute,
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
                // Same contract as the handlers below: `putOwned` leaves a field
                // it cannot place, so a second field's failure used to strand the
                // first one. The `return` disarms the guard at the hand-over.
                errdefer freeValue(sctx.allocator, .{ .object = out });
                try putOwned(&out, sctx.allocator, "ok", .{ .bool = true });
                try putOwned(&out, sctx.allocator, "cleared", .{ .bool = true });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.config.get",
        .action = .read,
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
                errdefer freeValue(sctx.allocator, .{ .object = out });
                try putJsonField(sctx.allocator, &out, "key", .{ .string = key_v.string });
                try putJsonField(sctx.allocator, &out, "value", .{ .string = value });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.config.set",
        .action = .execute,
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
        .action = .read,
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
                const obj = try json_shape.object(args);
                // An unrecognized `kind` used to become `null`, and `null` here
                // means "no kind filter" — so one typo widened the export to
                // every kind. A filter that cannot be honored is refused.
                const kind_str = json_shape.getString(obj, "kind") catch return error.InvalidArguments;
                const kind: ?run_audit.RunKind = if (kind_str) |k|
                    std.meta.stringToEnum(run_audit.RunKind, k) orelse return error.InvalidArguments
                else
                    null;
                const tenant = json_shape.getInt(obj, "tenant_id") catch return error.InvalidArguments;
                // `{"limit":-1}` used to be a checked panic in `@intCast(usize)`
                // (and `{"limit":"x"}` reached `.integer`): a negative limit is
                // not a small limit.
                const limit = (json_shape.getCount(obj, "limit", 100) catch return error.InvalidArguments) orelse 20;
                var store = run_audit.RunAuditStore.init(sctx.allocator, ac.backend);
                var entries = std.ArrayList(run_audit.RunAuditEntry).empty;
                defer {
                    for (entries.items) |e| {
                        sctx.allocator.free(e.run_id);
                        sctx.allocator.free(e.status);
                        // `appendRow` copies `model` too when the row has one —
                        // without this the export leaked it for every run whose
                        // model was captured (the `runs` tree only reports the
                        // other fields).
                        if (e.model) |m| sctx.allocator.free(m);
                    }
                    entries.deinit(sctx.allocator);
                }
                try store.list(sctx.allocator, &entries, kind, tenant, limit);
                var arr = std.json.Array.init(sctx.allocator);
                errdefer freeValue(sctx.allocator, .{ .array = arr });
                for (entries.items) |e| {
                    var rec = std.json.ObjectMap{};
                    // The append is the last statement of the loop body, so this
                    // guard is disarmed exactly when `arr` takes ownership.
                    errdefer freeValue(sctx.allocator, .{ .object = rec });
                    try putJsonField(sctx.allocator, &rec, "run_id", .{ .string = e.run_id });
                    try putJsonField(sctx.allocator, &rec, "kind", .{ .string = @tagName(e.kind) });
                    try putJsonField(sctx.allocator, &rec, "status", .{ .string = e.status });
                    try putOwned(&rec, sctx.allocator, "steps", .{ .integer = @intCast(e.steps) });
                    if (e.tenant_id) |tid| try putOwned(&rec, sctx.allocator, "tenant_id", .{ .integer = tid });
                    try arr.append(.{ .object = rec });
                }
                var out = std.json.ObjectMap{};
                errdefer freeValue(sctx.allocator, .{ .object = out });
                try putOwned(&out, sctx.allocator, "runs", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.user.manage",
        .action = .execute,
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
                const obj = try json_shape.object(args);
                const action = (try json_shape.getString(obj, "action")) orelse return error.InvalidArguments;
                const payload = obj.get("args") orelse .null;
                return handler(sctx.allocator, sctx, action, payload);
            }
        }.h,
    });
    try registry.register(.{
        .name = "admin.tenant.provision",
        .action = .execute,
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
                const obj = try json_shape.object(args);
                const action = (try json_shape.getString(obj, "action")) orelse return error.InvalidArguments;
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
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
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

    // An unrecognized kind used to become `null`, which here means "no kind
    // filter" — one typo away from an export of every kind. A filter that
    // cannot be honored is refused.
    var bad_kind = std.json.ObjectMap{};
    try putOwned(&bad_kind, allocator, "kind", .{ .string = try allocator.dupe(u8, "workflowX") });
    defer freeValue(allocator, .{ .object = bad_kind });
    try std.testing.expectError(error.InvalidArguments, registry.dispatch("admin.audit.export", &sctx, .{ .object = bad_kind }));

    // ...and a limit is a count: `{"limit":-1}` used to abort in
    // `@intCast(usize)`, `{"limit":"many"}` reached `.integer` directly.
    var neg_limit = std.json.ObjectMap{};
    try putOwned(&neg_limit, allocator, "limit", .{ .integer = -1 });
    defer freeValue(allocator, .{ .object = neg_limit });
    try std.testing.expectError(error.InvalidArguments, registry.dispatch("admin.audit.export", &sctx, .{ .object = neg_limit }));

    var str_limit = std.json.ObjectMap{};
    try putOwned(&str_limit, allocator, "limit", .{ .string = try allocator.dupe(u8, "many") });
    defer freeValue(allocator, .{ .object = str_limit });
    try std.testing.expectError(error.InvalidToolArgType, registry.dispatch("admin.audit.export", &sctx, .{ .object = str_limit }));
}

// `checkAllAllocationFailures` walks the key copy, the value copy and the
// map's growth on both the insert and the replace path.
//
// Red before the fix: both copies were built as the `put` arguments, so a
// failed value copy stranded the key copy and a failed `put` stranded both.
test "ConfigStore.set hands back its copies at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(a: std.mem.Allocator) !void {
            const mutable = [_][]const u8{"feature.flag"};
            var store = ConfigStore.init(a, &mutable);
            defer store.deinit();
            try std.testing.expect(try store.set("feature.flag", "dark"));
            try std.testing.expect(try store.set("feature.flag", "light"));
            try std.testing.expectEqualStrings("light", store.get("feature.flag").?);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{});
}

fn noopCacheDelete(_: *anyopaque, _: []const u8) void {}
fn noopCacheClear(_: *anyopaque) void {}

// The four cache/config/audit handlers build their answer field-by-field on the
// caller's allocator. The scan walks every allocation point: the key copy, the
// value copy and the map growth inside `putOwned` / `putJsonField`, plus the
// `freeValue` of a partially built tree.
test "admin.cache.invalidate hands back its tree at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    const handles = [_]CacheHandle{.{
        .name = "orders",
        .delete = noopCacheDelete,
        .clear = noopCacheClear,
        .userdata = &dummy,
    }};
    var admin_ctx = AdminCtx{ .backend = undefined, .caches = &handles };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerAdminSkills(&registry);

    var args_map = std.json.ObjectMap{};
    defer freeValue(allocator, .{ .object = args_map });
    try putOwned(&args_map, allocator, "cache", .{ .string = try allocator.dupe(u8, "orders") });
    try putOwned(&args_map, allocator, "key", .{ .string = try allocator.dupe(u8, "order:1") });

    const Scan = struct {
        const perms = [_][]const u8{"admin:cache"};
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, ac: *AdminCtx, args: std.json.ObjectMap) !void {
            var sctx = SkillContext{ .allocator = a, .userdata = ac, .permissions = &perms };
            const res = try reg.dispatch("admin.cache.invalidate", &sctx, .{ .object = args });
            defer freeValue(a, res);
            try std.testing.expect(res.object.get("ok").?.bool);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &admin_ctx, args_map });
}

// Red before the guard was added: with two fields and no `errdefer`, a failure
// on the second one stranded the first.
test "admin.cache.clear hands back its tree at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    const handles = [_]CacheHandle{.{
        .name = "orders",
        .delete = noopCacheDelete,
        .clear = noopCacheClear,
        .userdata = &dummy,
    }};
    var admin_ctx = AdminCtx{ .backend = undefined, .caches = &handles };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerAdminSkills(&registry);

    var args_map = std.json.ObjectMap{};
    defer freeValue(allocator, .{ .object = args_map });
    try putOwned(&args_map, allocator, "cache", .{ .string = try allocator.dupe(u8, "orders") });
    try putOwned(&args_map, allocator, "all", .{ .bool = true });

    const Scan = struct {
        const perms = [_][]const u8{"admin:cache"};
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, ac: *AdminCtx, args: std.json.ObjectMap) !void {
            var sctx = SkillContext{ .allocator = a, .userdata = ac, .permissions = &perms };
            const res = try reg.dispatch("admin.cache.clear", &sctx, .{ .object = args });
            defer freeValue(a, res);
            try std.testing.expect(res.object.get("cleared").?.bool);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &admin_ctx, args_map });
}

test "admin.config.get hands back its tree at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    const mutable = [_][]const u8{"feature.flag"};
    var store = ConfigStore.init(allocator, &mutable);
    defer store.deinit();
    try std.testing.expect(try store.set("feature.flag", "dark"));
    var admin_ctx = AdminCtx{ .backend = undefined, .config = &store };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerAdminSkills(&registry);

    var args_map = std.json.ObjectMap{};
    defer freeValue(allocator, .{ .object = args_map });
    try putOwned(&args_map, allocator, "key", .{ .string = try allocator.dupe(u8, "feature.flag") });

    const Scan = struct {
        const perms = [_][]const u8{"admin:config"};
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, ac: *AdminCtx, args: std.json.ObjectMap) !void {
            var sctx = SkillContext{ .allocator = a, .userdata = ac, .permissions = &perms };
            const res = try reg.dispatch("admin.config.get", &sctx, .{ .object = args });
            defer freeValue(a, res);
            try std.testing.expectEqualStrings("dark", res.object.get("value").?.string);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &admin_ctx, args_map });
}

// The row copies (`RunAuditStore.list` takes the handler's allocator) and the
// record tree both go through the failing allocator; the driver's own storage
// does not — the client is built on the test allocator, as in the scan for
// `RunAuditStore.list` itself.
test "admin.audit.export hands back its tree at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = run_audit.RunAuditStore.init(allocator, &backend);
    try store.migrate();
    // A row with a `model` — the field the export's cleanup used to miss.
    try store.record(.{ .run_id = "r1", .kind = .workflow, .status = "completed", .tenant_id = 1, .steps = 2, .duration_ms = 3, .model = "deepseek-v4" });

    var admin_ctx = AdminCtx{ .backend = &backend };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerAdminSkills(&registry);

    var args_map = std.json.ObjectMap{};
    defer freeValue(allocator, .{ .object = args_map });
    try putOwned(&args_map, allocator, "limit", .{ .integer = 5 });

    const Scan = struct {
        const perms = [_][]const u8{"admin:audit"};
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, ac: *AdminCtx, args: std.json.ObjectMap) !void {
            var sctx = SkillContext{ .allocator = a, .userdata = ac, .permissions = &perms };
            const res = try reg.dispatch("admin.audit.export", &sctx, .{ .object = args });
            defer freeValue(a, res);
            try std.testing.expectEqual(@as(usize, 1), res.object.get("runs").?.array.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &admin_ctx, args_map });
}

// The map refuses the field only when it cannot grow; the key copy built as
// the `put` argument used to be stranded on exactly that failure.
test "putOwned hands back its key copy at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(a: std.mem.Allocator) !void {
            var map = std.json.ObjectMap{};
            defer freeValue(a, .{ .object = map });
            try putOwned(&map, a, "k", .{ .integer = 7 });
            try std.testing.expectEqual(@as(i64, 7), map.get("k").?.integer);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{});
}
