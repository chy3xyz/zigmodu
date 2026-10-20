//! Internal runtime route registrar (phase B of the RouteGroup removal).
//!
//! **Not public API**: `http.zig` does not re-export this, `Server` has no
//! `group()` any more, and new code registers runtime routes through
//! `http.Router.scope(prefix).get/post/…/ws` (`ComptimeRouter.Scoped`). The
//! only callers left are framework-owned runtime registration (dashboard,
//! profiles, static files, SSE) and tests that need a prefix without building
//! a whole `Router(AppState)`.
//!
//! Semantics are unchanged from the old `RouteGroup`: join the prefix, attach
//! the scope middleware, register through `Server.addRoute` (or
//! `ws_handlers`). Routes registered here are *runtime* routes and stay
//! outside the comptime catalog — the caveat is documented on
//! `ComptimeRouter.Scoped.get`.

const std = @import("std");
const server_mod = @import("Server.zig");

const Server = server_mod.Server;
const Middleware = server_mod.Middleware;
const HandlerFn = server_mod.HandlerFn;
const Method = server_mod.Method;
const WsConnectFn = server_mod.WsConnectFn;
const WsMessageFn = server_mod.WsMessageFn;
const WsCloseFn = server_mod.WsCloseFn;

pub const RouteRegistrar = struct {
    server: *Server,
    prefix: []const u8,
    /// Scope-local middleware applied to routes registered through this registrar.
    middleware: []const Middleware = &.{},

    pub fn init(server: *Server, prefix: []const u8) RouteRegistrar {
        return .{ .server = server, .prefix = prefix };
    }

    /// Append scope-local middleware (allocates on server; freed in Server.deinit).
    pub fn use(self: RouteRegistrar, mw: Middleware) !RouteRegistrar {
        const extended = try self.server.allocator.alloc(Middleware, self.middleware.len + 1);
        @memcpy(extended[0..self.middleware.len], self.middleware);
        extended[self.middleware.len] = mw;
        try self.server.owned_route_mw.append(self.server.allocator, extended);
        return .{
            .server = self.server,
            .prefix = self.prefix,
            .middleware = extended,
        };
    }

    fn joinPath(self: *const RouteRegistrar, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const pfx = std.mem.trim(u8, self.prefix, "/");
        const rel = std.mem.trim(u8, path, "/");
        if (pfx.len == 0) return allocator.dupe(u8, rel);
        if (rel.len == 0) return allocator.dupe(u8, pfx);
        return allocator.print("{s}/{s}", .{ pfx, rel });
    }

    fn add(self: *RouteRegistrar, method: Method, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        const full_path = try self.joinPath(self.server.allocator, path);
        defer self.server.allocator.free(full_path);

        try self.server.addRoute(.{
            .method = method,
            .path = full_path,
            .handler = handler,
            .middleware = self.middleware,
            .user_data = user_data,
        });
    }

    pub fn get(self: *RouteRegistrar, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.GET, path, handler, user_data);
    }
    pub fn post(self: *RouteRegistrar, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.POST, path, handler, user_data);
    }
    pub fn put(self: *RouteRegistrar, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.PUT, path, handler, user_data);
    }
    pub fn delete(self: *RouteRegistrar, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.DELETE, path, handler, user_data);
    }
    pub fn patch(self: *RouteRegistrar, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.PATCH, path, handler, user_data);
    }
    pub fn head(self: *RouteRegistrar, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.HEAD, path, handler, user_data);
    }
    pub fn options(self: *RouteRegistrar, path: []const u8, handler: HandlerFn, user_data: ?*anyopaque) !void {
        try self.add(.OPTIONS, path, handler, user_data);
    }

    /// Register a WebSocket upgrade endpoint.
    pub fn ws(self: *RouteRegistrar, path: []const u8, on_connect: WsConnectFn, on_message: WsMessageFn, on_close: WsCloseFn, user_data: ?*anyopaque) !void {
        const full_path = try self.joinPath(self.server.allocator, path);
        defer self.server.allocator.free(full_path);

        const norm_path = if (full_path.len > 0 and full_path[0] == '/') full_path[1..] else full_path;
        const dup_path = try self.server.allocator.dupe(u8, norm_path);
        try self.server.ws_handlers.put(dup_path, .{
            .on_connect = on_connect,
            .on_message = on_message,
            .on_close = on_close,
            .user_data = user_data,
        });
    }
};
