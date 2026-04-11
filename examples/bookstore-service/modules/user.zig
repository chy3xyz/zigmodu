const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// User Module - 用户管理模块
/// 提供用户注册、认证、JWT 令牌管理等功能
/// ============================================
pub const UserModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "user",
        .description = "User management with authentication and JWT",
        .dependencies = &.{"database"},
    };

    var users: std.ArrayList(User) = undefined;
    var sessions: std.StringHashMap(Session) = undefined;
    var allocator: std.mem.Allocator = undefined;
    var user_id_counter: u64 = 1;

    // JWT secret (in production, load from environment)
    const JWT_SECRET = "your-secret-key-change-in-production";
    const TOKEN_EXPIRY_SECONDS = 86400; // 24 hours

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        users = std.ArrayList(User){};
        sessions = std.StringHashMap(Session).init(allocator);
        std.log.info("[user] User module initialized", .{});
    }

    pub fn deinit() void {
        for (users.items) |*user| {
            user.deinit(allocator);
        }
        users.deinit(allocator);

        var session_iter = sessions.iterator();
        while (session_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        sessions.deinit();

        std.log.info("[user] User module cleaned up", .{});
    }

    /// 用户实体
    pub const User = struct {
        id: u64,
        username: []const u8,
        email: []const u8,
        password_hash: []const u8,
        role: Role,
        created_at: i64,
        updated_at: i64,
        is_active: bool,

        pub const Role = enum {
            customer,
            admin,
            moderator,
        };

        pub fn deinit(self: *User, alloc: std.mem.Allocator) void {
            alloc.free(self.username);
            alloc.free(self.email);
            alloc.free(self.password_hash);
        }
    };

    /// 会话信息
    pub const Session = struct {
        user_id: u64,
        token: []const u8,
        created_at: i64,
        expires_at: i64,
    };

    /// 注册请求
    pub const RegisterRequest = struct {
        username: []const u8,
        email: []const u8,
        password: []const u8,
        role: User.Role = .customer,
    };

    /// 登录请求
    pub const LoginRequest = struct {
        username: []const u8,
        password: []const u8,
    };

    /// 认证响应
    pub const AuthResponse = struct {
        user: User,
        token: []const u8,
        expires_at: i64,
    };

    /// 注册用户
    pub fn register(request: RegisterRequest) !User {
        // Check if username exists
        if (findUserByUsername(request.username) != null) {
            return error.UsernameExists;
        }

        // Check if email exists
        if (findUserByEmail(request.email) != null) {
            return error.EmailExists;
        }

        const now = std.time.timestamp();
        const password_hash = try hashPassword(request.password);

        const user = User{
            .id = user_id_counter,
            .username = try allocator.dupe(u8, request.username),
            .email = try allocator.dupe(u8, request.email),
            .password_hash = password_hash,
            .role = request.role,
            .created_at = now,
            .updated_at = now,
            .is_active = true,
        };

        user_id_counter += 1;
        try users.append(allocator, user);

        std.log.info("[user] Registered user: {s} (id={d})", .{ user.username, user.id });

        return user;
    }

    /// 用户登录
    pub fn login(request: LoginRequest) !AuthResponse {
        const user = findUserByUsername(request.username) orelse {
            return error.InvalidCredentials;
        };

        if (!verifyPassword(request.password, user.password_hash)) {
            return error.InvalidCredentials;
        }

        if (!user.is_active) {
            return error.AccountDisabled;
        }

        // Generate JWT token
        const token = try generateToken(user.id);
        const now = std.time.timestamp();

        // Store session
        const session = Session{
            .user_id = user.id,
            .token = token,
            .created_at = now,
            .expires_at = now + TOKEN_EXPIRY_SECONDS,
        };

        try sessions.put(try allocator.dupe(u8, token), session);

        std.log.info("[user] User logged in: {s}", .{user.username});

        return AuthResponse{
            .user = user.*,
            .token = token,
            .expires_at = session.expires_at,
        };
    }

    /// 验证令牌
    pub fn verifyToken(token: []const u8) !?User {
        const session = sessions.get(token) orelse return null;

        const now = std.time.timestamp();
        if (now > session.expires_at) {
            _ = sessions.remove(token);
            return null;
        }

        return findUserById(session.user_id);
    }

    /// 登出
    pub fn logout(token: []const u8) !void {
        if (sessions.fetchRemove(token)) |entry| {
            allocator.free(entry.key);
            std.log.info("[user] User logged out (id={d})", .{entry.value.user_id});
        }
    }

    /// 根据 ID 查找用户
    pub fn findUserById(id: u64) ?User {
        for (users.items) |user| {
            if (user.id == id) {
                return user;
            }
        }
        return null;
    }

    /// 根据用户名查找用户
    fn findUserByUsername(username: []const u8) ?*User {
        for (users.items) |*user| {
            if (std.mem.eql(u8, user.username, username)) {
                return user;
            }
        }
        return null;
    }

    /// 根据邮箱查找用户
    fn findUserByEmail(email: []const u8) ?*User {
        for (users.items) |*user| {
            if (std.mem.eql(u8, user.email, email)) {
                return user;
            }
        }
        return null;
    }

    /// 获取所有用户
    pub fn getAllUsers() []User {
        return users.items;
    }

    /// 更新用户信息
    pub fn updateUser(id: u64, email: ?[]const u8, is_active: ?bool) !?User {
        for (users.items) |*user| {
            if (user.id == id) {
                const now = std.time.timestamp();

                if (email) |new_email| {
                    allocator.free(user.email);
                    user.email = try allocator.dupe(u8, new_email);
                }

                if (is_active) |active| {
                    user.is_active = active;
                }

                user.updated_at = now;

                std.log.info("[user] Updated user: {s} (id={d})", .{ user.username, user.id });
                return user.*;
            }
        }
        return null;
    }

    /// 密码哈希（简化版，生产环境使用 bcrypt/argon2）
    fn hashPassword(password: []const u8) ![]const u8 {
        // Simple hash for demo - use proper hashing in production
        var hash: [32]u8 = undefined;
        const salt = "somesalt";

        var hasher = std.crypto.hash.sha3.Sha3_256.init(.{});
        hasher.update(password);
        hasher.update(salt);
        hasher.final(&hash);

        const hex_hash = std.fmt.bytesToHex(hash, .lower);
        return try std.fmt.allocPrint(allocator, "{s}", .{&hex_hash});
    }

    /// 验证密码
    fn verifyPassword(password: []const u8, hash: []const u8) bool {
        const computed_hash = hashPassword(password) catch return false;
        defer allocator.free(computed_hash);
        return std.mem.eql(u8, computed_hash, hash);
    }

    /// 生成 JWT 令牌（简化版）
    fn generateToken(user_id: u64) ![]const u8 {
        const now = std.time.timestamp();
        const expires = now + TOKEN_EXPIRY_SECONDS;

        // Simple token format: user_id:expiry:signature
        const token = try std.fmt.allocPrint(
            allocator,
            "{d}:{d}:{s}",
            .{ user_id, expires, JWT_SECRET },
        );

        return token;
    }

    /// 添加示例用户
    pub fn seedData() !void {
        const sample_users = [_]RegisterRequest{
            .{
                .username = "admin",
                .email = "admin@bookstore.com",
                .password = "admin123",
                .role = .admin,
            },
            .{
                .username = "customer1",
                .email = "customer1@example.com",
                .password = "password123",
                .role = .customer,
            },
            .{
                .username = "customer2",
                .email = "customer2@example.com",
                .password = "password123",
                .role = .customer,
            },
        };

        for (sample_users) |user| {
            _ = register(user) catch |err| {
                if (err == error.UsernameExists or err == error.EmailExists) {
                    continue;
                }
                return err;
            };
        }

        std.log.info("[user] Seeded {d} sample users", .{sample_users.len});
    }
};

test "User module" {
    try UserModule.init();
    defer UserModule.deinit();

    // Register a user
    const user = try UserModule.register(.{
        .username = "testuser",
        .email = "test@example.com",
        .password = "password123",
    });

    try std.testing.expectEqualStrings("testuser", user.username);
    try std.testing.expect(user.is_active);

    // Login
    const auth = try UserModule.login(.{
        .username = "testuser",
        .password = "password123",
    });

    try std.testing.expectEqual(user.id, auth.user.id);
    try std.testing.expect(auth.token.len > 0);

    // Verify token
    const verified_user = try UserModule.verifyToken(auth.token);
    try std.testing.expect(verified_user != null);
    try std.testing.expectEqual(user.id, verified_user.?.id);

    // Logout
    try UserModule.logout(auth.token);
    const after_logout = try UserModule.verifyToken(auth.token);
    try std.testing.expect(after_logout == null);
}
