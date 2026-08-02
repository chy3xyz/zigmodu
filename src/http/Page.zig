//! Paged-response helpers: parse page/page_size query params with clamping
//! (a `page_size=0` must never select the whole table) and emit a paged JSON
//! envelope. Belongs to the HTTP layer — the data layer (zent `paged()` /
//! sqlx) stays engine-specific.

const std = @import("std");
const server_mod = @import("../api/Server.zig");
const Context = server_mod.Context;

pub const PageOpts = struct {
    default_page_size: usize = 20,
    max_page_size: usize = 100,
};

pub const PageParams = struct {
    page: usize = 1,
    page_size: usize = 20,

    /// Parse `page` / `page_size` query params with clamping:
    /// page >= 1, 1 <= page_size <= max_page_size.
    pub fn parse(ctx: *const Context, opts: PageOpts) PageParams {
        const page = @max(ctx.queryInt(usize, "page", 1), 1);
        const raw_size = ctx.queryInt(usize, "page_size", opts.default_page_size);
        const page_size = @min(@max(raw_size, 1), opts.max_page_size);
        return .{ .page = page, .page_size = page_size };
    }
};

pub const Envelope = enum {
    /// `{ "list": [...], "total": N, "page": P, "pageSize": S }`
    plain,
    /// RuoYi-style `{ "code": 0, "msg": "ok", "data": { list, total, page, pageSize } }`
    ruoyi,
    /// ZigModu codegen style `{ "code": 0, "items": [...], "total": N }`
    items,
};

/// Emit a paged JSON envelope. `items` is any serializable value (slice of
/// structs, ArrayList.items, …).
pub fn sendPaged(
    ctx: *Context,
    items: anytype,
    total: usize,
    params: PageParams,
    envelope: Envelope,
) !void {
    const page_data = .{ .list = items, .total = total, .page = params.page, .pageSize = params.page_size };
    switch (envelope) {
        .plain => try ctx.jsonStruct(200, page_data),
        .ruoyi => try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = page_data }),
        .items => try ctx.jsonStruct(200, .{ .code = 0, .items = items, .total = total }),
    }
}

// ── tests ─────────────────────────────────────────────────────────────────

test "PageParams clamps page_size and page" {
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "/");
    defer ctx.deinit();
    // Context.init does not parse the URL query — populate like the request
    // parser does for a real request.
    try ctx.query.put(try allocator.dupe(u8, "page"), try allocator.dupe(u8, "0"));
    try ctx.query.put(try allocator.dupe(u8, "page_size"), try allocator.dupe(u8, "0"));
    const p = PageParams.parse(&ctx, .{ .max_page_size = 50 });
    try std.testing.expectEqual(@as(usize, 1), p.page);
    try std.testing.expectEqual(@as(usize, 1), p.page_size);

    var ctx2 = try Context.init(allocator, .GET, "/");
    defer ctx2.deinit();
    try ctx2.query.put(try allocator.dupe(u8, "page"), try allocator.dupe(u8, "999"));
    try ctx2.query.put(try allocator.dupe(u8, "page_size"), try allocator.dupe(u8, "10000"));
    const p2 = PageParams.parse(&ctx2, .{ .max_page_size = 50 });
    try std.testing.expectEqual(@as(usize, 999), p2.page);
    try std.testing.expectEqual(@as(usize, 50), p2.page_size);
}
