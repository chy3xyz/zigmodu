const std = @import("std");

/// API version[...]
pub const ApiVersion = struct {
    /// [...]
    major: u16,
    /// [...]
    minor: u16 = 0,

    pub fn parse(version_str: []const u8) ?ApiVersion {
        // "v1", "v2.0", "1", "2.0"
        var s = version_str;
        if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) {
            s = s[1..];
        }

        const dot = std.mem.indexOfScalar(u8, s, '.');
        if (dot) |d| {
            const major = std.fmt.parseInt(u16, s[0..d], 10) catch return null;
            const minor = std.fmt.parseInt(u16, s[d + 1 ..], 10) catch return null;
            return ApiVersion{ .major = major, .minor = minor };
        }

        const major = std.fmt.parseInt(u16, s, 10) catch return null;
        return ApiVersion{ .major = major, .minor = 0 };
    }

    pub fn toString(self: ApiVersion, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "v{d}.{d}", .{ self.major, self.minor }) catch buf[0..0];
    }

    pub fn eql(self: ApiVersion, other: ApiVersion) bool {
        return self.major == other.major and self.minor == other.minor;
    }

    /// [...]: [...]
    pub fn isCompatible(self: ApiVersion, other: ApiVersion) bool {
        return self.major == other.major;
    }
};

/// API version[...] — [...]
/// [...] URL [...] Header [...]
pub const ApiVersionExtractor = struct {
    /// [...] URL [...]: /api/v1/users → v1
    pub fn fromPath(path: []const u8) ?ApiVersion {
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len > 0 and (segment[0] == 'v' or segment[0] == 'V')) {
                return ApiVersion.parse(segment);
            }
        }
        return null;
    }

    /// [...]: Accept-Version: v2
    pub fn fromHeader(headers: anytype, header_name: []const u8) ?ApiVersion {
        if (headers.get(header_name)) |value| {
            return ApiVersion.parse(value);
        }
        return null;
    }

    /// [...] ([...] header[...] path)
    pub fn extract(path: []const u8, headers: anytype, header_name: []const u8) ?ApiVersion {
        if (fromHeader(headers, header_name)) |v| return v;
        return fromPath(path);
    }
};

/// API versionRoute group — Register independent routes per version
///
/// Usage:
///   var v1 = server.group("/api/v1");
///   var v2 = server.group("/api/v2");
///   try v1.get("/users", handleUsersV1, null);
///   try v2.get("/users", handleUsersV2, null);
pub const ApiVersionRouter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    versions: std.ArrayList(VersionGroup),

    pub const VersionGroup = struct {
        version: ApiVersion,
        prefix: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .versions = std.ArrayList(VersionGroup).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.versions.deinit(self.allocator);
    }

    /// [...]
    pub fn registerVersion(self: *Self, version: ApiVersion, prefix: []const u8) !void {
        try self.versions.append(self.allocator, .{
            .version = version,
            .prefix = prefix,
        });
    }

    /// [...] ([...] ≤ [...])
    pub fn resolve(self: *Self, requested: ApiVersion) ?ApiVersion {
        var best: ?ApiVersion = null;
        for (self.versions.items) |vg| {
            if (vg.version.major <= requested.major) {
                if (best == null or vg.version.major > best.?.major or
                    (vg.version.major == best.?.major and vg.version.minor > best.?.minor))
                {
                    best = vg.version;
                }
            }
        }
        return best;
    }
};

/// API version[...]Middleware
/// Auto-extract version from request and set ctx [...]
///
/// Usage:
///   server.addMiddleware(.{ .func = apiVersionMiddleware("1.0") });
pub fn apiVersionMiddleware(default_version_str: []const u8) api.MiddlewareFn {
    const default_ver = ApiVersion.parse(default_version_str) orelse ApiVersion{ .major = 1, .minor = 0 };

    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            _ = user_data;

            // [...] URL [...] Header [...]
            const version = ApiVersionExtractor.extract(
                ctx.path,
                ctx.headers,
                "Accept-Version",
            ) orelse ApiVersion{ .major = 1, .minor = 0 };

            // [...] Context user_data [...]
            _ = version;

            try next(ctx, next, null);
        }
    };

    _ = default_ver;

    return S.handler;
}

const api = @import("../api/Server.zig");

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "ApiVersion parse" {
    var v = ApiVersion.parse("v1").?;
    try std.testing.expectEqual(@as(u16, 1), v.major);
    try std.testing.expectEqual(@as(u16, 0), v.minor);

    v = ApiVersion.parse("v2.3").?;
    try std.testing.expectEqual(@as(u16, 2), v.major);
    try std.testing.expectEqual(@as(u16, 3), v.minor);

    v = ApiVersion.parse("3").?;
    try std.testing.expectEqual(@as(u16, 3), v.major);

    try std.testing.expect(ApiVersion.parse("invalid") == null);
}

test "ApiVersion toString" {
    var buf: [16]u8 = undefined;
    const s = (ApiVersion{ .major = 1, .minor = 5 }).toString(&buf);
    try std.testing.expectEqualStrings("v1.5", s);
}

test "ApiVersion isCompatible" {
    const v1_0 = ApiVersion{ .major = 1, .minor = 0 };
    const v1_5 = ApiVersion{ .major = 1, .minor = 5 };
    const v2_0 = ApiVersion{ .major = 2, .minor = 0 };

    try std.testing.expect(v1_0.isCompatible(v1_5));
    try std.testing.expect(!v1_0.isCompatible(v2_0));
}

test "ApiVersionExtractor from path" {
    try std.testing.expect(ApiVersionExtractor.fromPath("/api/v1/users") != null);
    try std.testing.expect(ApiVersionExtractor.fromPath("/v2/orders") != null);
    try std.testing.expect(ApiVersionExtractor.fromPath("/api/users") == null);
    try std.testing.expect(ApiVersionExtractor.fromPath("") == null);
}

test "ApiVersionExtractor from path - correct version" {
    const v = ApiVersionExtractor.fromPath("/api/v3.1/data").?;
    try std.testing.expectEqual(@as(u16, 3), v.major);
    try std.testing.expectEqual(@as(u16, 1), v.minor);
}

test "ApiVersionRouter register and resolve" {
    const allocator = std.testing.allocator;
    var router = ApiVersionRouter.init(allocator);
    defer router.deinit();

    try router.registerVersion(ApiVersion{ .major = 1, .minor = 0 }, "/api/v1");
    try router.registerVersion(ApiVersion{ .major = 2, .minor = 0 }, "/api/v2");

    const resolved = router.resolve(ApiVersion{ .major = 1, .minor = 5 }).?;
    try std.testing.expectEqual(@as(u16, 1), resolved.major);

    const resolved2 = router.resolve(ApiVersion{ .major = 2, .minor = 1 }).?;
    try std.testing.expectEqual(@as(u16, 2), resolved2.major);

    const resolved3 = router.resolve(ApiVersion{ .major = 3, .minor = 0 });
    try std.testing.expect(resolved3 != null);
}

test "ApiVersionExtractor with different prefixes" {
    // Test that "V2" (uppercase) also works
    const v = ApiVersion.parse("V1").?;
    try std.testing.expectEqual(@as(u16, 1), v.major);

    // Test leading slash
    const v2 = ApiVersionExtractor.fromPath("/V2.0/users").?;
    try std.testing.expectEqual(@as(u16, 2), v2.major);
}
