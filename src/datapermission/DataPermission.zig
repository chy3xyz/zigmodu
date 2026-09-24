const std = @import("std");
const Rbac = @import("../security/Rbac.zig");

const log = std.log.scoped(.data_permission);

/// The fail-closed predicate every rejected scope materializes — the
/// counterpart of zent's `data_scope.deny_pred` (v0.66.0, see `docs/ZENT.md`
/// §14: "空 `dept_ids` 拒绝而非放行"). `1 = 0` matches no row on SQLite,
/// PostgreSQL and MySQL, and carrying no column reference keeps it unambiguous
/// wherever a caller splices it in.
const deny_clause = "1 = 0";

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
        self.* = undefined;
    }

    pub fn fromRoles(allocator: std.mem.Allocator, roles: []const Rbac.Role, self_dept_id: i64, user_id: i64) DataPermissionContext {
        var ctx = DataPermissionContext{ .allocator = allocator, .self_dept_id = self_dept_id, .user_id = user_id };
        if (roles.len == 0) return ctx;
        var widest = roles[0];
        for (roles[1..]) |role| {
            if (@backingInt(role.data_scope) < @backingInt(widest.data_scope)) widest = role;
        }
        ctx.scope = widest.data_scope;
        if (widest.data_scope == .dept_custom) {
            if (widest.data_scope_dept_ids) |json_str| {
                // A list that cannot be read is **not** "no restriction": leave
                // `dept_ids` null and `buildWhere` rejects the scope. Say why
                // here, where the unusable value is still in hand.
                ctx.dept_ids = parseDeptIds(allocator, json_str) catch |err| blk: {
                    log.warn("data permission: role dept scope is not a list of ids ({s}); the .dept_custom scope will match no row", .{@errorName(err)});
                    break :blk null;
                };
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
            // `.all` is the only scope that means "no restriction", so it is the
            // only one that comes back `null` — the single caller-visible way to
            // spell it. Every other scope returns a filter the caller splices,
            // and when one cannot be built it comes back as the fail-closed
            // clause (`reject`), never as `null`.
            .all => return null,
            .dept_custom => {
                // The list names the departments the caller may see. A list that
                // cannot be built — absent, empty, or with an id that failed to
                // parse — names no department at all, so the caller sees no row.
                // `.all` is already a first-class way to lift the restriction;
                // returning `null` here (what this branch used to do) is what
                // handed the caller's query the whole table.
                const ids = self.dept_ids orelse
                    return reject("the .dept_custom role carries no usable dept list");
                if (ids.len == 0) return reject("the .dept_custom dept list is empty");
                const clause = buildInClause(allocator, dept_column, ids) catch
                    return reject("the .dept_custom dept list could not be rendered");
                return DataPermissionFilter{ .clause = clause, .params = ids };
            },
            // The three scopes below bind exactly one param, so that allocation
            // is the only thing that can fail. On failure they deny instead of
            // returning `null`: `null` means "the caller applies no
            // data-permission clause at all", so an allocation failure must not
            // be the way a department- or user-scoped read becomes a full-table
            // read. Failing closed keeps the restriction that the caller asked
            // for; the warn in `reject` is the signal to act on.
            .dept_only => {
                const params = allocator.alloc(i64, 1) catch
                    return reject("the .dept_only scope could not bind its department id");
                params[0] = self.self_dept_id;
                return DataPermissionFilter{ .clause = dept_column ++ " = ?", .params = params };
            },
            .dept_and_child => {
                const params = allocator.alloc(i64, 1) catch
                    return reject("the .dept_and_child scope could not bind its department id");
                params[0] = self.self_dept_id;
                return DataPermissionFilter{ .clause = dept_column ++ " = ?", .params = params };
            },
            .self_ => {
                const params = allocator.alloc(i64, 1) catch
                    return reject("the .self_ scope could not bind the user id");
                params[0] = self.user_id;
                return DataPermissionFilter{ .clause = user_column ++ " = ?", .params = params };
            },
        }
    }
};

/// A restriction the caller splices into its own WHERE clause.
///
/// `params` is owned by the returning scope: borrowed from the
/// `DataPermissionContext` for a well-formed `.dept_custom` (do **not** free),
/// allocated from the interceptor allocator for `.self_` / `.dept_only` /
/// `.dept_and_child`, and empty (`&.{}`, free is a no-op) for a rejected scope.
pub const DataPermissionFilter = struct {
    clause: []const u8,
    params: []const i64,
};

/// Fail-closed result for a restricting scope that could not be built.
///
/// Two things make a scope unbuildable: a `.dept_custom` list that names no
/// department (absent, empty, unparseable) and an allocation failure while
/// binding the param of `.self_` / `.dept_only` / `.dept_and_child`.
///
/// The point of this shape is that it is a **filter**: it comes back as a
/// clause the caller already splices and applies, so "could not build the
/// restriction" cannot reach the query as "no restriction". `null` stays
/// reserved for `.all`, and only `.all`.
fn reject(why: []const u8) DataPermissionFilter {
    log.warn(
        "data permission: {s}; matching no row instead of being read as unrestricted (use the `.all` scope to lift the restriction)",
        .{why},
    );
    return .{ .clause = deny_clause, .params = &.{} };
}

/// Data-permission SQL interceptor — mirrors `TenantInterceptor`: produces
/// the scope clause ("AND {col} = ?" / "AND {col} IN (?,…)") so handlers apply
/// data permission at the SQL layer instead of hand-writing filters.
/// NOTE: the returned clause is comptime static for `.all`/`.self_`/`.dept_only`
/// (do NOT free) and for a rejected scope (`"1 = 0"`, including one rejected
/// because binding its param failed to allocate); a well-formed `.dept_custom`
/// is the only shape that allocates from the interceptor allocator.
pub const DataPermissionInterceptor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DataPermissionInterceptor {
        return .{ .allocator = allocator };
    }

    /// Scope clause for the current context.
    ///
    /// `null` means "everything allowed" and is produced by **one** scope only:
    /// `.all`. A restricting scope that cannot be built — a `.dept_custom` list
    /// that names no department, or a `.self_` / `.dept_only` / `.dept_and_child`
    /// whose param allocation failed — comes back as a filter that matches no
    /// row, never as `null`, which a caller splices as "no data-permission
    /// clause at all".
    pub fn andWhere(
        self: *DataPermissionInterceptor,
        ctx: *const DataPermissionContext,
        comptime dept_column: []const u8,
        comptime user_column: []const u8,
    ) !?DataPermissionFilter {
        return ctx.buildWhere(self.allocator, dept_column, user_column);
    }
};

fn buildInClause(allocator: std.mem.Allocator, comptime col: []const u8, ids: []const i64) ![]const u8 {
    // Size the buffer from the list instead of rendering into a fixed one: the
    // count is data (a role's dept list), and the clause it produces is
    // `3 * n + col.len + 4` bytes for n ids — the fixed `[256]u8` this used to
    // write into fit 81 ids for a 7-char column and wrote past the array from the
    // 82nd on: a bounds trap in Debug, a clobbered frame in ReleaseFast.
    const separators: usize = if (ids.len > 0) (ids.len - 1) * 2 else 0;
    const clause = try allocator.alloc(u8, col.len + 5 + ids.len + separators + 1);
    var pos: usize = 0;
    @memcpy(clause[pos..][0..col.len], col);
    pos += col.len;
    @memcpy(clause[pos..][0..5], " IN (");
    pos += 5;
    for (ids, 0..) |_, i| {
        if (i > 0) {
            clause[pos] = ',';
            clause[pos + 1] = ' ';
            pos += 2;
        }
        clause[pos] = '?';
        pos += 1;
    }
    clause[pos] = ')';
    pos += 1;
    std.debug.assert(pos == clause.len);
    return clause;
}

/// Parse the `data_scope_dept_ids` column: `[1, 2]`, `[1,2]`, `1,2`, `[]`.
///
/// Strict on purpose — a token that is not an integer fails the whole list
/// (`error.InvalidDeptId`) instead of being skipped, so a role row the admin
/// form wrote wrongly cannot silently narrow the scope it was meant to name.
/// The caller turns that failure into a rejection (`reject`).
fn parseDeptIds(alloc: std.mem.Allocator, input: []const u8) ![]const i64 {
    var list = std.ArrayList(i64).empty;
    errdefer list.deinit(alloc);
    var body = std.mem.trim(u8, input, " \t\n\r");
    if (body.len > 0 and body[0] == '[') {
        body = body[1..];
        if (body.len > 0 and body[body.len - 1] == ']') body = body[0 .. body.len - 1];
    }
    var it = std.mem.tokenizeScalar(u8, body, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\n\r[]");
        if (trimmed.len == 0) continue;
        const id = std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidDeptId;
        try list.append(alloc, id);
    }
    return list.toOwnedSlice(alloc);
}

test "DataPermissionContext init and default" {
    const allocator = std.testing.allocator;
    var ctx = DataPermissionContext.init(allocator);
    defer ctx.deinit();
    try std.testing.expectEqual(Rbac.DataScope.self_, ctx.scope);
    try std.testing.expectEqual(@as(i64, 0), ctx.user_id);
}

test "DataPermissionFilter buildWhere" {
    const allocator = std.testing.allocator;
    var ctx = DataPermissionContext.init(allocator);
    defer ctx.deinit();
    ctx.user_id = 42;

    const where = ctx.buildWhere(allocator, "dept_id", "user_id") orelse return error.UnexpectedNull;
    defer allocator.free(where.params);
    try std.testing.expect(where.clause.len > 0);
}

test "DataPermissionInterceptor injects scope clause at SQL layer" {
    const allocator = std.testing.allocator;
    var ctx = DataPermissionContext.init(allocator);
    defer ctx.deinit();
    ctx.scope = .self_;
    ctx.user_id = 42;

    var interceptor = DataPermissionInterceptor.init(allocator);
    const filter = try interceptor.andWhere(&ctx, "region", "owner_id") orelse return error.UnexpectedNull;
    defer allocator.free(filter.params);
    // .self_ clause is comptime static: "owner_id = ?"
    try std.testing.expectEqualStrings("owner_id = ?", filter.clause);
    try std.testing.expectEqual(@as(i64, 42), filter.params[0]);

    // .all scope → null (everything allowed)
    var wide = DataPermissionContext.init(allocator);
    defer wide.deinit();
    wide.scope = .all;
    try std.testing.expect((try interceptor.andWhere(&wide, "region", "owner_id")) == null);
}

test "only the .all scope can yield a null filter" {
    const allocator = std.testing.allocator;
    var interceptor = DataPermissionInterceptor.init(allocator);
    for (std.enums.values(Rbac.DataScope)) |scope| {
        var ctx = DataPermissionContext.init(allocator);
        defer ctx.deinit();
        ctx.scope = scope;
        ctx.user_id = 7;
        ctx.self_dept_id = 3;
        const filter = try interceptor.andWhere(&ctx, "dept_id", "owner_id");
        if (scope == .all) {
            try std.testing.expect(filter == null);
            continue;
        }
        // Every other scope restricts: `null` would be spliced by the caller as
        // "no data-permission clause at all".
        try std.testing.expect(filter != null);
        try std.testing.expect(filter.?.clause.len > 0);
        if (filter.?.params.len > 0) allocator.free(filter.?.params);
    }
}

test "an allocation failure while building a restricting filter matches no row (sqlite)" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec("CREATE TABLE doc (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, dept_id INTEGER NOT NULL)", &.{});
    _ = try client.exec("INSERT INTO doc (id, owner_id, dept_id) VALUES (1, 7, 3), (2, 7, 4)", &.{});

    const Doc = struct { id: i64 };
    // Every restricting scope allocates its bound params. Fail that allocation
    // and splice the result exactly the way the real caller does
    // (`examples/zmsaas/backend/src/shard.zig`): a `null` filter means "no
    // data-permission clause at all", so acquiring one here would hand the
    // query the whole table.
    for ([_]Rbac.DataScope{ .self_, .dept_only, .dept_and_child }) |scope| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        var ctx = DataPermissionContext.init(allocator);
        defer ctx.deinit();
        ctx.scope = scope;
        ctx.user_id = 7;
        ctx.self_dept_id = 3;
        var interceptor = DataPermissionInterceptor.init(failing.allocator());

        const filter = try interceptor.andWhere(&ctx, "dept_id", "owner_id");
        try std.testing.expect(filter != null);
        try std.testing.expectEqualStrings("1 = 0", filter.?.clause);
        try std.testing.expectEqual(@as(usize, 0), filter.?.params.len);

        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(allocator);
        try sql.appendSlice(allocator, "SELECT id FROM doc WHERE owner_id = ?");
        var args: [2]data.sqlx.Value = undefined;
        var arg_count: usize = 0;
        args[arg_count] = .{ .int = 7 };
        arg_count += 1;
        if (filter) |f| {
            try sql.appendSlice(allocator, " AND ");
            try sql.appendSlice(allocator, f.clause);
            for (f.params) |p| {
                args[arg_count] = .{ .int = p };
                arg_count += 1;
            }
        }
        var rows = try client.queryRows(Doc, sql.items, args[0..arg_count]);
        defer rows.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 0), rows.items.len);
    }

    // Control: with a working allocator the very same scope still restricts to
    // its own department — the fix above is "deny on failure", not "always deny".
    var ok_ctx = DataPermissionContext.init(allocator);
    defer ok_ctx.deinit();
    ok_ctx.scope = .dept_only;
    ok_ctx.self_dept_id = 3;
    var ok_interceptor = DataPermissionInterceptor.init(allocator);
    const ok_filter = (try ok_interceptor.andWhere(&ok_ctx, "dept_id", "owner_id")) orelse
        return error.UnexpectedNull;
    defer allocator.free(ok_filter.params);
    try std.testing.expectEqualStrings("dept_id = ?", ok_filter.clause);
    try std.testing.expectEqual(@as(i64, 3), ok_filter.params[0]);
    var ok_rows = try client.queryRows(Doc, "SELECT id FROM doc WHERE owner_id = ? AND dept_id = ?", &.{ .{ .int = 7 }, .{ .int = 3 } });
    defer ok_rows.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ok_rows.items.len);
    try std.testing.expectEqual(@as(i64, 1), ok_rows.items[0].id);
}

test ".dept_custom rejects an empty or absent dept list instead of allowing everything" {
    const allocator = std.testing.allocator;
    var interceptor = DataPermissionInterceptor.init(allocator);

    const good = try allocator.alloc(i64, 2);
    good[0] = 3;
    good[1] = 4;
    defer allocator.free(good);
    const cases = [_]struct { ids: ?[]const i64, clause: []const u8 }{
        .{ .ids = null, .clause = "1 = 0" },
        .{ .ids = &.{}, .clause = "1 = 0" },
        .{ .ids = good, .clause = "dept_id IN (?, ?)" },
    };
    for (cases) |case| {
        var ctx = DataPermissionContext.init(allocator);
        ctx.scope = .dept_custom;
        // `dept_ids` is owned by the context: hand it its own allocation (as
        // `fromRoles` does), never a static slice.
        ctx.dept_ids = if (case.ids) |ids| try allocator.dupe(i64, ids) else null;
        defer ctx.deinit();
        const filter = try interceptor.andWhere(&ctx, "dept_id", "owner_id") orelse
            return error.RejectedScopeCameBackAsUnrestricted;
        try std.testing.expectEqualStrings(case.clause, filter.clause);
        if (std.mem.eql(u8, case.clause, "1 = 0")) {
            try std.testing.expectEqual(@as(usize, 0), filter.params.len);
        } else {
            defer allocator.free(filter.clause);
            try std.testing.expectEqualSlices(i64, good, filter.params);
        }
    }
}

test "a .dept_custom list longer than a fixed clause buffer still renders" {
    const allocator = std.testing.allocator;
    // A role can legitimately name hundreds of departments; the clause grows with
    // the list, so rendering it into a fixed-size buffer is a size bug waiting on
    // data (the old `[256]u8` fit only 81 ids for this column).
    const n: usize = 300;
    const ids = try allocator.alloc(i64, n);
    for (ids, 0..) |*id, i| id.* = @intCast(i + 1);

    var ctx = DataPermissionContext.init(allocator);
    defer ctx.deinit();
    ctx.scope = .dept_custom;
    ctx.dept_ids = ids; // owned by ctx, freed by ctx.deinit()
    var interceptor = DataPermissionInterceptor.init(allocator);
    const filter = (try interceptor.andWhere(&ctx, "dept_id", "owner_id")) orelse
        return error.RejectedScopeCameBackAsUnrestricted;
    defer allocator.free(filter.clause);
    try std.testing.expectEqual(@as(usize, n), filter.params.len);
    try std.testing.expectEqual("dept_id IN (".len + n + 2 * (n - 1) + 1, filter.clause.len);
    try std.testing.expect(std.mem.startsWith(u8, filter.clause, "dept_id IN (?, "));
    try std.testing.expect(std.mem.endsWith(u8, filter.clause, "?)"));
}

test "fromRoles rejects a data_scope_dept_ids that is empty or not a list of ids" {
    const allocator = std.testing.allocator;
    var interceptor = DataPermissionInterceptor.init(allocator);

    const unreadable = [_]?[]const u8{ null, "", "[]", "[ ]", "[\"a\"]", "[1,abc]", "not json", "1,2,oops" };
    for (unreadable) |json| {
        var ctx = DataPermissionContext.fromRoles(allocator, &.{deptRole(.dept_custom, json)}, 3, 7);
        defer ctx.deinit();
        const filter = try interceptor.andWhere(&ctx, "dept_id", "owner_id") orelse
            return error.RejectedScopeCameBackAsUnrestricted;
        try std.testing.expectEqualStrings("1 = 0", filter.clause);
        try std.testing.expectEqual(@as(usize, 0), filter.params.len);
    }

    // A well-formed list still filters by exactly the ids it names.
    var ok = DataPermissionContext.fromRoles(allocator, &.{deptRole(.dept_custom, "[7, 9]")}, 3, 7);
    defer ok.deinit();
    const filter = try interceptor.andWhere(&ok, "dept_id", "owner_id") orelse
        return error.UnexpectedNull;
    defer allocator.free(filter.clause);
    try std.testing.expectEqualStrings("dept_id IN (?, ?)", filter.clause);
    try std.testing.expectEqualSlices(i64, &.{ 7, 9 }, filter.params);
}

fn deptRole(scope: Rbac.DataScope, dept_ids: ?[]const u8) Rbac.Role {
    return .{
        .id = 1,
        .name = "r",
        .code = "r",
        .sort = 0,
        .status = 1,
        .type = 1,
        .remark = "",
        .data_scope = scope,
        .data_scope_dept_ids = dept_ids,
        .tenant_id = 1,
    };
}

test "a rejected .dept_custom scope spliced by the caller matches no row (sqlite)" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    var client = try data.Client.open(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    _ = try client.exec("CREATE TABLE doc (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, dept_id INTEGER NOT NULL)", &.{});
    _ = try client.exec("INSERT INTO doc (id, owner_id, dept_id) VALUES (1, 7, 3), (2, 7, 4)", &.{});

    const Doc = struct { id: i64 };
    // The caller shape from `examples/zmsaas/backend/src/shard.zig`: the filter
    // comes back as a clause to append, or as nothing at all.
    var interceptor = DataPermissionInterceptor.init(allocator);
    var ctx = DataPermissionContext.init(allocator);
    defer ctx.deinit();
    ctx.scope = .dept_custom; // role row: data_scope=2 with dept_ids = '[]'

    const filter = try interceptor.andWhere(&ctx, "dept_id", "owner_id");
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SELECT id FROM doc WHERE owner_id = ?");
    if (filter) |f| {
        try sql.appendSlice(allocator, " AND ");
        try sql.appendSlice(allocator, f.clause);
    }
    var denied = try client.queryRows(Doc, sql.items, &.{.{ .int = 7 }});
    defer denied.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), denied.items.len);

    // Control: the same splice with a usable list returns exactly its dept.
    const ids = try allocator.alloc(i64, 1);
    ids[0] = 4;
    ctx.dept_ids = ids; // freed by ctx.deinit()
    const ok_filter = (try interceptor.andWhere(&ctx, "dept_id", "owner_id")).?;
    defer allocator.free(ok_filter.clause);
    var ok_sql = std.ArrayList(u8).empty;
    defer ok_sql.deinit(allocator);
    try ok_sql.appendSlice(allocator, "SELECT id FROM doc WHERE owner_id = ?");
    try ok_sql.appendSlice(allocator, " AND ");
    try ok_sql.appendSlice(allocator, ok_filter.clause);
    var allowed = try client.queryRows(Doc, ok_sql.items, &.{ .{ .int = 7 }, .{ .int = 4 } });
    defer allowed.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), allowed.items.len);
    try std.testing.expectEqual(@as(i64, 2), allowed.items[0].id);
}
