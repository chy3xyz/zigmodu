const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");

pub fn WorldApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            try group.post("/worlds", createWorld, @ptrCast(@alignCast(self)));
            try group.post("/worlds/feature", feature, @ptrCast(@alignCast(self)));
            try group.post("/worlds/visit", visit, @ptrCast(@alignCast(self)));
            try group.get("/worlds", getWorld, @ptrCast(@alignCast(self)));
        }

        fn createWorld(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const owner = ctx.queryParam("owner_did") orelse {
                try ctx.json(400, "{\"error\":\"missing owner_did\"}");
                return;
            };
            const name = ctx.queryParam("name") orelse {
                try ctx.json(400, "{\"error\":\"missing name\"}");
                return;
            };
            const symbol = ctx.queryParam("symbol") orelse "MV";
            const fee = std.fmt.parseInt(i64, ctx.queryParam("entry_fee_cents") orelse "100", 10) catch 100;
            const id = self.svc.create(owner, name, symbol, fee) catch |err| {
                try ctx.json(400, try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}));
                return;
            };
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"id\":{d}}}", .{id});
            defer ctx.allocator.free(body);
            try ctx.json(201, body);
        }

        fn feature(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const wid = try std.fmt.parseInt(i64, ctx.queryParam("world_id") orelse "0", 10);
            const cid = try std.fmt.parseInt(i64, ctx.queryParam("creative_id") orelse "0", 10);
            try self.svc.feature(wid, cid);
            try ctx.json(200, "{\"ok\":true}");
        }

        fn visit(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const wid = try std.fmt.parseInt(i64, ctx.queryParam("world_id") orelse "0", 10);
            const did = ctx.queryParam("visitor_did") orelse {
                try ctx.json(400, "{\"error\":\"missing visitor_did\"}");
                return;
            };
            const fee = self.svc.visitWorld(wid, did) catch |err| {
                try ctx.json(400, try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}));
                return;
            };
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"fee_cents\":{d}}}", .{fee});
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }

        fn getWorld(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const id = try std.fmt.parseInt(i64, ctx.queryParam("id") orelse "0", 10);
            const w = (try self.svc.get(id)) orelse {
                try ctx.json(404, "{\"error\":\"not found\"}");
                return;
            };
            defer self.svc.free(w);
            const body = try std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{d},"name":"{s}","owner_did":"{s}","visitors":{d},"revenue_cents":{d},"featured_creative_id":{d}}}
            , .{ w.id, w.name, w.owner_did, w.visitor_count, w.revenue_cents, w.featured_creative_id });
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }
    };
}
