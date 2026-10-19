//! Built-in business skills registration (ops layer).
//!
//! This lived in `skill.zig`, which made the core registry import the whole
//! business-operations package just to offer a convenience registration. It
//! moved here with the ops package: core `skill.zig` now imports no ops module,
//! and an application that wants the built-ins calls
//! `ai.ops.builtin.registerBuiltinCatalog(&registry)`.

const std = @import("std");
const skill_mod = @import("../skill.zig");
const SkillRegistry = skill_mod.SkillRegistry;
const guard_mod = @import("../guard.zig");

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

pub fn registerBuiltinCatalog(registry: *SkillRegistry) !void {
    const business = @import("business.zig");
    try business.registerBusinessSkills(registry, &[_]business.EntitySpec{});
    try @import("actions.zig").registerWriteSkills(registry);
    try @import("actions.zig").registerCommandSkills(registry);
    try @import("actions.zig").registerReportSkills(registry);
    try @import("schedule.zig").registerScheduleSkills(registry);
    try @import("notify.zig").registerNotifySkills(registry);
    try @import("kpi.zig").registerKpiSkills(registry);
    try @import("../approval.zig").registerApprovalSkills(registry);
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

    // Exactly the policy docs/reference/AGENT_RUNTIME.md §二 recommends: name the read
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
