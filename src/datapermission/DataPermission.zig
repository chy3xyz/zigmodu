const std = @import("std");
const Rbac = @import("../security/Rbac.zig");

pub const DataPermissionContext = struct {
    allocator: std.mem.Allocator,
    scope: Rbac.DataScope = .self_,
    dept_ids: ?[]const i64 = null,
    self_dept_id: i64 = 0,
    user_id: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) DataPermissionContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DataPermissionContext) void {
        if (self.dept_ids) |ids| self.allocator.free(ids);
    }

    pub fn fromRoles(allocator: std.mem.Allocator, roles: []const Rbac.Role, self_dept_id: i64, user_id: i64) DataPermissionContext {
        var ctx = DataPermissionContext{ .allocator = allocator, .self_dept_id = self_dept_id, .user_id = user_id };
        if (roles.len == 0) return ctx;
        var widest = roles[0];
        for (roles[1..]) |role| {
            if (@intFromEnum(role.data_scope) < @intFromEnum(widest.data_scope)) widest = role;
        }
        ctx.scope = widest.data_scope;
        if (widest.data_scope == .dept_custom) {
            if (widest.data_scope_dept_ids) |json_str| {
                ctx.dept_ids = parseDeptIds(allocator, json_str) catch null;
            }
        }
        return ctx;
    }

    pub fn buildWhere(
        self: *const DataPermissionContext,
        allocator: std.mem.Allocator,
        comptime dept_column: []const u8,
        comptime user_column: []const u8,
    ) ?DataPermissionFilter {
        switch (self.scope) {
            .all => return null,
            .dept_custom => {
                if (self.dept_ids) |ids| {
                    if (ids.len == 0) return null;
                    const clause = buildInClause(allocator, dept_column, ids) catch return null;
                    return DataPermissionFilter{ .clause = clause, .params = ids };
                }
                return null;
            },
            .dept_only => {
                const params = allocator.alloc(i64, 1) catch return null;
                params[0] = self.self_dept_id;
                return DataPermissionFilter{ .clause = dept_column ++ " = ?", .params = params };
            },
            .dept_and_child => {
                const params = allocator.alloc(i64, 1) catch return null;
                params[0] = self.self_dept_id;
                return DataPermissionFilter{ .clause = dept_column ++ " = ?", .params = params };
            },
            .self_ => {
                const params = allocator.alloc(i64, 1) catch return null;
                params[0] = self.user_id;
                return DataPermissionFilter{ .clause = user_column ++ " = ?", .params = params };
            },
        }
    }
};

pub const DataPermissionFilter = struct {
    clause: []const u8,
    params: []const i64,
};

fn buildInClause(allocator: std.mem.Allocator, comptime col: []const u8, ids: []const i64) ![]const u8 {
    var buf: [256]u8 = undefined;
    var pos: usize = col.len + 5; // "col IN ("
    @memcpy(buf[0..col.len], col);
    @memcpy(buf[col.len..pos], " IN (");
    for (ids, 0..) |_, i| {
        if (i > 0) { buf[pos] = ','; buf[pos+1] = ' '; pos += 2; }
        buf[pos] = '?'; pos += 1;
    }
    buf[pos] = ')'; pos += 1;
    return allocator.dupe(u8, buf[0..pos]);
}

fn parseDeptIds(allocator: std.mem.Allocator, input: []const u8) ![]const i64 {
    var list = std.ArrayList(i64).init(allocator);
    const cleaned = if (input.len > 0 and input[0] == '[') input[1..input.len-1] else input;
    var it = std.mem.tokenizeScalar(u8, cleaned, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\n\r[]");
        if (trimmed.len == 0) continue;
        const id = std.fmt.parseInt(i64, trimmed, 10) catch continue;
        try list.append(id);
    }
    return list.toOwnedSlice();
}

test "DataPermissionContext init and default" {
    const allocator = std.testing.allocator;
    var ctx = DataPermissionContext.init(allocator);
    defer ctx.deinit();
    try std.testing.expect(!ctx.is_admin);
    try std.testing.expectEqual(@as(i64, 0), ctx.user_id);
}

test "DataPermissionFilter buildWhere" {
    const allocator = std.testing.allocator;
    var ctx = DataPermissionContext.init(allocator);
    defer ctx.deinit();
    ctx.user_id = 42;

    const filter = DataPermissionFilter{ .column = "user_id", .scope = .self_ };
    const where = try filter.buildWhere(allocator, ctx);
    defer allocator.free(where);
    try std.testing.expect(where.len > 0);
}

