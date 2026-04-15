const std = @import("std");
const ManagedArrayList = std.array_list.Managed;

/// HTTP 路由器 - 支持 RESTful API
pub const Router = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    routes: ManagedArrayList(Route),
    middlewares: ManagedArrayList(Middleware),
    prefix: []const u8,

    pub const Route = struct {
        method: HttpMethod,
        path: []const u8,
        handler: RequestHandler,
        middlewares: ManagedArrayList(Middleware),
    };

    pub const HttpMethod = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
        HEAD,
        OPTIONS,
    };

    pub const Request = struct {
        method: HttpMethod,
        path: []const u8,
        headers: std.StringHashMap([]const u8),
        query_params: std.StringHashMap([]const u8),
        path_params: std.StringHashMap([]const u8),
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Request {
            return .{
                .method = .GET,
                .path = "",
                .headers = std.StringHashMap([]const u8).init(allocator),
                .query_params = std.StringHashMap([]const u8).init(allocator),
                .path_params = std.StringHashMap([]const u8).init(allocator),
                .body = "",
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Request) void {
            self.headers.deinit();
            self.query_params.deinit();
            self.path_params.deinit();
        }

        pub fn getHeader(self: Request, name: []const u8) ?[]const u8 {
            return self.headers.get(name);
        }

        pub fn getQueryParam(self: Request, name: []const u8) ?[]const u8 {
            return self.query_params.get(name);
        }

        pub fn getPathParam(self: Request, name: []const u8) ?[]const u8 {
            return self.path_params.get(name);
        }
    };

    pub const Response = struct {
        status_code: u16,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Response {
            return .{
                .status_code = 200,
                .headers = std.StringHashMap([]const u8).init(allocator),
                .body = "",
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Response) void {
            var iter = self.headers.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            self.allocator.free(self.body);
        }

        pub fn setStatus(self: *Response, code: u16) void {
            self.status_code = code;
        }

        pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
            const name_copy = try self.allocator.dupe(u8, name);
            const value_copy = try self.allocator.dupe(u8, value);
            try self.headers.put(name_copy, value_copy);
        }

        pub fn setBody(self: *Response, body: []const u8) !void {
            self.body = try self.allocator.dupe(u8, body);
        }

        pub fn json(self: *Response, data: anytype) !void {
            const json_str = try std.fmt.allocPrint(self.allocator, "{any}", .{data});
            defer self.allocator.free(json_str);
            try self.setBody(json_str);
            try self.setHeader("Content-Type", "application/json");
        }

        pub fn text(self: *Response, text_content: []const u8) !void {
            try self.setBody(text_content);
            try self.setHeader("Content-Type", "text/plain");
        }

        pub fn html(self: *Response, html_content: []const u8) !void {
            try self.setBody(html_content);
            try self.setHeader("Content-Type", "text/html");
        }
    };

    pub const RequestHandler = *const fn (Request) anyerror!Response;
    pub const Middleware = *const fn (Request, RequestHandler) anyerror!Response;

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8) Self {
        return .{
            .allocator = allocator,
            .routes = ManagedArrayList(Route).init(allocator),
            .middlewares = ManagedArrayList(Middleware).init(allocator),
            .prefix = prefix,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.routes.items) |route_item| {
            self.allocator.free(route_item.path);
            route_item.middlewares.deinit();
        }
        self.routes.deinit();
        self.middlewares.deinit();
    }

    /// 注册路由
    pub fn route(self: *Self, method: HttpMethod, path: []const u8, handler_fn: RequestHandler) !void {
        const full_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, path });

        try self.routes.append(.{
            .method = method,
            .path = full_path,
            .handler = handler_fn,
            .middlewares = ManagedArrayList(Middleware).init(self.allocator),
        });
    }

    /// 快捷方法
    pub fn get(self: *Self, path: []const u8, handler: RequestHandler) !void {
        try self.route(.GET, path, handler);
    }

    pub fn post(self: *Self, path: []const u8, handler: RequestHandler) !void {
        try self.route(.POST, path, handler);
    }

    pub fn put(self: *Self, path: []const u8, handler: RequestHandler) !void {
        try self.route(.PUT, path, handler);
    }

    pub fn delete(self: *Self, path: []const u8, handler: RequestHandler) !void {
        try self.route(.DELETE, path, handler);
    }

    pub fn patch(self: *Self, path: []const u8, handler: RequestHandler) !void {
        try self.route(.PATCH, path, handler);
    }

    /// 添加全局中间件
    pub fn use(self: *Self, middleware: Middleware) !void {
        try self.middlewares.append(middleware);
    }

    /// 匹配路由
    pub fn match(self: *Self, method: HttpMethod, path: []const u8) ?RouteMatch {
        for (self.routes.items) |route_item| {
            if (route_item.method != method) continue;

            if (self.pathMatches(route_item.path, path)) |params| {
                return RouteMatch{
                    .route = route_item,
                    .path_params = params,
                };
            }
        }
        return null;
    }

    pub const RouteMatch = struct {
        route: Route,
        path_params: std.StringHashMap([]const u8),
    };

    /// 路径匹配（支持参数 :id）
    fn pathMatches(self: *Self, pattern: []const u8, path: []const u8) ?std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var iter = params.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            params.deinit();
        }

        var pattern_parts = std.mem.splitSequence(u8, pattern, "/");
        var path_parts = std.mem.splitSequence(u8, path, "/");

        while (pattern_parts.next()) |pattern_part| {
            const path_part = path_parts.next() orelse return null;

            if (pattern_part.len == 0 and path_part.len == 0) continue;
            if (pattern_part.len == 0) continue;

            if (std.mem.startsWith(u8, pattern_part, ":")) {
                // 参数匹配
                const param_name = pattern_part[1..];
                const param_value = self.allocator.dupe(u8, path_part) catch return null;
                params.put(param_name, param_value) catch {
                    self.allocator.free(param_value);
                    return null;
                };
            } else if (!std.mem.eql(u8, pattern_part, path_part)) {
                return null;
            }
        }

        // 确保路径也结束了
        if (path_parts.next() != null) return null;

        return params;
    }

    /// 执行请求
    pub fn handle(self: *Self, request: Request) !Response {
        const route_match = self.match(request.method, request.path) orelse {
            var response = Response.init(request.allocator);
            response.setStatus(404);
            try response.text("Not Found");
            return response;
        };

        var req = request;
        // 合并路径参数
        var param_iter = route_match.path_params.iterator();
        while (param_iter.next()) |entry| {
            try req.path_params.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // 执行中间件链
        const handler = route_match.route.handler;

        // Note: middleware chain composition in Zig requires a closure-free design.
        // For now, global middlewares are registered but not automatically applied in handle().
        _ = self.middlewares;

        return handler(req);
    }

    /// 创建子路由器
    pub fn group(self: *Self, prefix: []const u8) Router {
        const full_prefix = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, prefix }) catch return Router.init(self.allocator, "");
        return Router.init(self.allocator, full_prefix);
    }
};

/// API 版本管理
pub const ApiVersion = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn init(major: u32, minor: u32, patch: u32) ApiVersion {
        return .{
            .major = major,
            .minor = minor,
            .patch = patch,
        };
    }

    pub fn toString(self: ApiVersion, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "v{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }

    pub fn toPathPrefix(self: ApiVersion, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "/api/v{d}", .{self.major});
    }
};

/// 路由组
pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,
    middlewares: std.ArrayList(Router.Middleware),

    pub fn init(router: *Router, prefix: []const u8) RouteGroup {
        return .{
            .router = router,
            .prefix = prefix,
            .middlewares = std.ArrayList(Router.Middleware).init(router.allocator),
        };
    }

    pub fn deinit(self: *RouteGroup) void {
        self.middlewares.deinit(self.router.allocator);
    }

    pub fn use(self: *RouteGroup, middleware: Router.Middleware) !void {
        try self.middlewares.append(self.router.allocator, middleware);
    }

    pub fn get(self: *RouteGroup, path: []const u8, handler: Router.RequestHandler) !void {
        const full_path = try std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.router.allocator.free(full_path);
        try self.router.get(full_path, handler);
    }

    pub fn post(self: *RouteGroup, path: []const u8, handler: Router.RequestHandler) !void {
        const full_path = try std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.router.allocator.free(full_path);
        try self.router.post(full_path, handler);
    }

    pub fn put(self: *RouteGroup, path: []const u8, handler: Router.RequestHandler) !void {
        const full_path = try std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.router.allocator.free(full_path);
        try self.router.put(full_path, handler);
    }

    pub fn delete(self: *RouteGroup, path: []const u8, handler: Router.RequestHandler) !void {
        const full_path = try std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, path });
        defer self.router.allocator.free(full_path);
        try self.router.delete(full_path, handler);
    }
};

test "Router route matching and params" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator, "/api");
    defer router.deinit();

    const handler = struct {
        fn h(req: Router.Request) anyerror!Router.Response {
            var res = Router.Response.init(req.allocator);
            try res.text("ok");
            return res;
        }
    }.h;

    try router.get("/users/:id", handler);

    var match = router.match(.GET, "/api/users/42").?;
    defer {
        var iter = match.path_params.iterator();
        while (iter.next()) |entry| {
            router.allocator.free(entry.value_ptr.*);
        }
        match.path_params.deinit();
    }
    try std.testing.expectEqualStrings("42", match.path_params.get("id").?);

    const no_match = router.match(.POST, "/api/users/42");
    try std.testing.expect(no_match == null);
}

test "Router handle 404" {
    const allocator = std.testing.allocator;
    var router = Router.init(allocator, "");
    defer router.deinit();

    var req = Router.Request.init(allocator);
    defer req.deinit();
    req.method = .GET;
    req.path = "/notfound";

    var res = try router.handle(req);
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 404), res.status_code);
}

test "Router response helpers" {
    const allocator = std.testing.allocator;
    var res = Router.Response.init(allocator);
    defer res.deinit();

    try res.json(.{ .id = 1 });
    try std.testing.expectEqualStrings("application/json", res.headers.get("Content-Type").?);
    try std.testing.expect(std.mem.containsAtLeast(u8, res.body, 1, "id"));
}

test "ApiVersion" {
    const v = ApiVersion.init(1, 2, 3);
    const s = try v.toString(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("v1.2.3", s);
}
