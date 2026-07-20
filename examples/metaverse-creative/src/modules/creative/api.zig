const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");
const model = @import("model.zig");

pub fn CreativeApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.post("/creatives", createDraft, @ptrCast(@alignCast(self)));
            try group.post("/creatives/publish", publish, @ptrCast(@alignCast(self)));
            try group.get("/creatives", listPublished, @ptrCast(@alignCast(self)));
        }

        fn createDraft(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const d = try parseDraft(ctx);
            const id = self.svc.draft(d) catch |err| {
                try ctx.json(400, try errJson(ctx, err));
                return;
            };
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id});
            defer ctx.allocator.free(body);
            try ctx.json(201, body);
        }

        fn publish(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const id = try std.fmt.parseInt(i64, ctx.queryParam("id") orelse "0", 10);
            const price = try std.fmt.parseInt(i64, ctx.queryParam("price_cents") orelse "0", 10);
            self.svc.publish(id, price) catch |err| {
                try ctx.json(400, try errJson(ctx, err));
                return;
            };
            try ctx.json(200, "{\"ok\":true}");
        }

        fn listPublished(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const rows = try self.svc.listPublished();
            defer self.svc.freeList(rows);
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"creatives\":[");
            for (rows, 0..) |r, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"title":"{s}","owner_did":"{s}","price_cents":{d}}}
                , .{ r.id, r.title, r.owner_did, r.price_cents });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn parseDraft(ctx: *http.Context) !model.CreativeDraft {
            return .{
                .owner_did = ctx.queryParam("owner_did") orelse return error.InvalidInput,
                .title = ctx.queryParam("title") orelse return error.InvalidInput,
                .slug = ctx.queryParam("slug") orelse return error.InvalidInput,
                .problem = ctx.queryParam("problem") orelse "",
                .solution = ctx.queryParam("solution") orelse "",
                .world = ctx.queryParam("world") orelse "",
                .price_cents = std.fmt.parseInt(i64, ctx.queryParam("price_cents") orelse "0", 10) catch 0,
            };
        }

        fn errJson(ctx: *http.Context, err: anyerror) ![]const u8 {
            return try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
        }
    };
}
