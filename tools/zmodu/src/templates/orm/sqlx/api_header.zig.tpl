//! @initialized by zmodu — AI may modify freely
//!
//! HTTP API for module: <<MODULE_NAME>>
//! ComptimeRouter: `pub const routes` + `http.Router.scope(...).mount` (docs/ROUTE_TABLE.md)

const std = @import("std");
const http = @import("zigmodu").http;
const service = @import("service.zig");
const model = @import("model.zig");
const R = @import("<<SHARED_IMPORT>>response.zig");

pub const <<PASCAL_MODULE>>Api = struct {
    service: *service.<<PASCAL_MODULE>>Service,

    pub const module_name = "<<GATE_NAME>>";
    pub const nest = <<NEST>>;
    pub const State = @This();

    pub fn init(svc: *service.<<PASCAL_MODULE>>Service) <<PASCAL_MODULE>>Api {
        return .{ .service = svc };
    }

    pub const routes = [_]http.RouteSpec(State){
