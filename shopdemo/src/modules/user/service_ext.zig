//! User service extension — custom business logic (survives regeneration).
//! AI Context: module=user | layer=business extension | extends=service.zig

const std = @import("std");
const zigmodu = @import("zigmodu");
const user_svc = @import("service.zig");
const model = @import("model.zig");

pub const UserServiceExt = struct {
    svc: *user_svc.UserService;
    backend: zigmodu.SqlxBackend;

    pub fn init(svc: *user_svc.UserService, backend: zigmodu.SqlxBackend) UserServiceExt {
        return .{ .svc = svc, .backend = backend };
    }

    pub fn registerWithReferral(self: *UserServiceExt, user: model.ZmoduUser, referee_id: ?i64) !model.ZmoduUser {
        const created = try self.svc.createZmoduUser(user);
        if (referee_id) |ref_id| { std.log.info("[user] {d} referred by {d}", .{ created.user_id, ref_id }); _ = ref_id; }
        return created;
    }

    pub fn addPoints(self: *UserServiceExt, user_id: i64, points: i64, reason: []const u8) !void {
        _ = try self.svc.getZmoduUser(user_id) orelse return error.NotFound;
        std.log.info("[user] {d}: +{d} points ({s})", .{ user_id, points, reason });
    }

    pub fn isActiveAgent(self: *UserServiceExt, user_id: i64) !bool {
        _ = try self.svc.getZmoduUser(user_id) orelse return error.NotFound;
        return true;
    }
};
