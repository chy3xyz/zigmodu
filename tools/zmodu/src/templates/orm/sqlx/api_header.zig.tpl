//! @initialized by zmodu — AI may modify freely
//!
//! HTTP API for module: <<MODULE_NAME>>

const std = @import("std");
const http = @import("zigmodu").http;
const service = @import("service.zig");
const model = @import("model.zig");
const R = @import("<<SHARED_IMPORT>>response.zig");

pub const <<PASCAL_MODULE>>Api = struct {
    service: *service.<<PASCAL_MODULE>>Service,

    pub fn init(svc: *service.<<PASCAL_MODULE>>Service) <<PASCAL_MODULE>>Api {
        return .{ .service = svc };
    }

    fn resolve(ctx: *http.Context) *<<PASCAL_MODULE>>Api {
        return @ptrCast(@alignCast(ctx.user_data orelse unreachable));
    }

    pub fn registerRoutes(self: *<<PASCAL_MODULE>>Api, group: *http.RouteGroup) !void {
