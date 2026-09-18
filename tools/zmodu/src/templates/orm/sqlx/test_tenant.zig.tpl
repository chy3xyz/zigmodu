
/// Index of the `nth` route with `method`. `routeIndex` above only finds the
/// first one, and this test needs both GETs — `list` then `get`.
fn routeIndexNth(comptime method: http.Method, comptime nth: usize) usize {
    var seen: usize = 0;
    inline for (Api.routes, 0..) |route, index| {
        if (route.method == method) {
            if (seen == nth) return index;
            seen += 1;
        }
    }
    @compileError(std.fmt.comptimePrint("route #{d} with method {s} missing from {s}", .{ nth, @tagName(method), @typeName(Api) }));
}

test "<<MODULE_NAME>>: one tenant cannot read or write another tenant's rows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try openTestDb(allocator, io, Row);
    defer client.deinit();

    const backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
    var store = persistence.<<PASCAL_MODULE>>Persistence.init(backend);
    var svc = Service.init(&store);
    var state = Api.init(&svc);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = http.Server.init(io, arena, 0);
    defer server.deinit();

    const AppState = struct {};
    var app_state: AppState = .{};
    var router = http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();
    var scope = router.scope("/api");
    try scope.mount(Api, &state);

    // Tenant 2 owns a row, written through the tenant-scoped service method.
    var theirs = sampleRow();
    theirs.<<TENANT_COLUMN>> = 2;
    const b_row = try svc.create<<MODEL_NAME>>ByTenant(2, theirs);
    const b_id = b_row.id orelse return error.MissingGeneratedId;

    // Tenant 1 posts a row whose body *claims* tenant 2. The tenant column of a
    // request body is attacker-controlled input; the handler must take the
    // tenant from the request identity instead, so the claim has to be
    // overwritten before the row is written.
    var claimed = sampleRow();
    claimed.<<TENANT_COLUMN>> = 2;
    const body = try std.json.Stringify.valueAlloc(allocator, claimed, .{});
    defer allocator.free(body);

    var create_buf: [256]u8 = undefined;
    var created = try http.Testkit.dispatchOpts(&server, .POST, try routePath(&create_buf, comptime routeIndexNth(.POST, 0)), .{
        .body = body,
        .attrs = &.{.{ "tenant_id", "1" }},
    });
    defer created.deinit(arena);
    try std.testing.expectEqual(@as(u16, 200), created.status_code);

    const created_json = try std.json.parseFromSlice(std.json.Value, allocator, created.body, .{});
    defer created_json.deinit();
    const created_row = created_json.value.object.get("data").?;
    try std.testing.expectEqual(@as(i64, 1), created_row.object.get("<<TENANT_COLUMN>>").?.integer);

    // Tenant 1 lists: it sees the row it just created and nothing else. A
    // handler that fell back to an unscoped query would return both rows.
    var list_buf: [256]u8 = undefined;
    const list_path = try routePath(&list_buf, comptime routeIndexNth(.GET, 0));
    var listed = try http.Testkit.dispatchOpts(&server, .GET, list_path, .{ .attrs = &.{.{ "tenant_id", "1" }} });
    defer listed.deinit(arena);

    const listed_json = try std.json.parseFromSlice(std.json.Value, allocator, listed.body, .{});
    defer listed_json.deinit();
    const data = listed_json.value.object.get("data").?;
    try std.testing.expectEqual(@as(i64, 1), data.object.get("total").?.integer);
    const rows = data.object.get("list").?.array;
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqual(@as(i64, 1), rows.items[0].object.get("<<TENANT_COLUMN>>").?.integer);

    // Guessing the other tenant's row id with tenant 1's identity yields the
    // not-found envelope — not the row.
    var get_buf: [256]u8 = undefined;
    const get_path = try routePath(&get_buf, comptime routeIndexNth(.GET, 1));
    const probe = try std.fmt.allocPrint(allocator, "{s}?id={d}", .{ get_path, b_id });
    defer allocator.free(probe);

    var guessed = try http.Testkit.dispatchOpts(&server, .GET, probe, .{ .attrs = &.{.{ "tenant_id", "1" }} });
    defer guessed.deinit(arena);
    const guessed_json = try std.json.parseFromSlice(std.json.Value, allocator, guessed.body, .{});
    defer guessed_json.deinit();
    try std.testing.expectEqual(@as(i64, 404), guessed_json.value.object.get("code").?.integer);

    // No tenant at all (the auth middleware is not on this router) is a
    // rejection, not a fallback: nothing above has an unscoped call to reach.
    var anonymous = try http.Testkit.dispatchOpts(&server, .GET, list_path, .{});
    defer anonymous.deinit(arena);
    const anonymous_json = try std.json.parseFromSlice(std.json.Value, allocator, anonymous.body, .{});
    defer anonymous_json.deinit();
    try std.testing.expectEqual(@as(i64, 401), anonymous_json.value.object.get("code").?.integer);

    // Writing is the other half of the same isolation, and it needs its own
    // assertion: a tenant-scoped UPDATE/DELETE matches nothing for a foreign
    // row, which returns `rows_affected == 0`. A handler that ignores that
    // count answers 200 for a write that never happened, so the client cannot
    // tell "I changed it" from "that row is not mine". The payload below
    // rewrites every string column to a sentinel, so an accepted cross-tenant
    // write cannot hide behind identical bytes.
    var stolen = sampleRow();
    stolen.id = b_id;
    stolen.<<TENANT_COLUMN>> = 2;
    inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |name, FieldType| {
        if (FieldType == []const u8) @field(stolen, name) = "stolen";
    }
    const stolen_body = try std.json.Stringify.valueAlloc(allocator, stolen, .{});
    defer allocator.free(stolen_body);

    var update_buf: [256]u8 = undefined;
    var stolen_update = try http.Testkit.dispatchOpts(&server, .PUT, try routePath(&update_buf, comptime routeIndexNth(.PUT, 0)), .{
        .body = stolen_body,
        .attrs = &.{.{ "tenant_id", "1" }},
    });
    defer stolen_update.deinit(arena);
    const stolen_update_json = try std.json.parseFromSlice(std.json.Value, allocator, stolen_update.body, .{});
    defer stolen_update_json.deinit();
    try std.testing.expectEqual(@as(i64, 404), stolen_update_json.value.object.get("code").?.integer);

    var delete_buf: [256]u8 = undefined;
    const stolen_delete_path = try std.fmt.allocPrint(allocator, "{s}?id={d}", .{
        try routePath(&delete_buf, comptime routeIndexNth(.DELETE, 0)),
        b_id,
    });
    defer allocator.free(stolen_delete_path);
    var stolen_delete = try http.Testkit.dispatchOpts(&server, .DELETE, stolen_delete_path, .{ .attrs = &.{.{ "tenant_id", "1" }} });
    defer stolen_delete.deinit(arena);
    const stolen_delete_json = try std.json.parseFromSlice(std.json.Value, allocator, stolen_delete.body, .{});
    defer stolen_delete_json.deinit();
    try std.testing.expectEqual(@as(i64, 404), stolen_delete_json.value.object.get("code").?.integer);

    // A 404 is only honest if the row really survived untouched: tenant 2 still
    // owns it, and none of the sentinel values were written into it.
    const untouched = (try svc.get<<MODEL_NAME>>ByTenant(b_id, 2)) orelse return error.RowMissing;
    defer zigmodu.data.sqlx.freeScanned(allocator, Row, untouched);
    inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |name, FieldType| {
        if (FieldType == []const u8) {
            try std.testing.expectEqualStrings(@field(theirs, name), @field(untouched, name));
        }
    }
}
