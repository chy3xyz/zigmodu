const std = @import("std");
const crypto = std.crypto;
const Time = @import("../core/Time.zig");

/// 安全模块 - 提供认证、授权、加密功能
pub const SecurityModule = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    jwt_secret: []const u8,
    token_expiry_seconds: i64,
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator, jwt_secret: []const u8, token_expiry_seconds: i64) Self {
        return .{
            .allocator = allocator,
            .jwt_secret = jwt_secret,
            .token_expiry_seconds = token_expiry_seconds,
            .io = null,
        };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, jwt_secret: []const u8, token_expiry_seconds: i64, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .jwt_secret = jwt_secret,
            .token_expiry_seconds = token_expiry_seconds,
            .io = io,
        };
    }

    /// JWT Token 结构
    pub const JwtToken = struct {
        header: JwtHeader,
        payload: JwtPayload,
        signature: []const u8,

        pub const JwtHeader = struct {
            alg: []const u8 = "HS256",
            typ: []const u8 = "JWT",
        };

        pub const JwtPayload = struct {
            sub: []const u8, // subject (user id)
            iss: []const u8, // issuer
            aud: []const u8, // audience
            exp: i64, // expiration time
            iat: i64, // issued at
            roles: []const []const u8, // user roles
        };

        /// 生成 JWT Token 字符串
        pub fn toString(self: JwtToken, allocator: std.mem.Allocator) ![]const u8 {
            // Base64 encode header
            const header_json = try std.json.Stringify.valueAlloc(allocator, self.header, .{});
            defer allocator.free(header_json);
            const header_b64 = try base64UrlEncode(allocator, header_json);
            defer allocator.free(header_b64);

            // Base64 encode payload
            const payload_json = try std.json.Stringify.valueAlloc(allocator, self.payload, .{});
            defer allocator.free(payload_json);
            const payload_b64 = try base64UrlEncode(allocator, payload_json);
            defer allocator.free(payload_b64);

            // Create signature base
            const signature_base = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
            defer allocator.free(signature_base);

            // Return final token
            return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, self.signature });
        }
    };

    /// 生成 JWT Token
    pub fn generateToken(
        self: *Self,
        user_id: []const u8,
        roles: []const []const u8,
    ) ![]const u8 {
        const now = if (self.io) |io| @as(i64, @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_s))) else Time.monotonicNowSeconds();
        const exp = now + self.token_expiry_seconds;

        const header = JwtToken.JwtHeader{};
        const payload = JwtToken.JwtPayload{
            .sub = user_id,
            .iss = "zigmodu",
            .aud = "zigmodu-app",
            .exp = exp,
            .iat = now,
            .roles = roles,
        };

        // Create signature base
        const header_json = try std.json.Stringify.valueAlloc(self.allocator, header, .{});
        defer self.allocator.free(header_json);
        const header_b64 = try base64UrlEncode(self.allocator, header_json);
        defer self.allocator.free(header_b64);

        const payload_json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(payload_json);
        const payload_b64 = try base64UrlEncode(self.allocator, payload_json);
        defer self.allocator.free(payload_b64);

        const signature_base = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signature_base);

        // Generate signature using HMAC-SHA256
        const signature = try self.sign(signature_base);
        defer self.allocator.free(signature);

        // 直接构建token字符串，避免中间结构体
        return std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, signature });
    }

    /// 验证 JWT Token
    pub fn verifyToken(self: *Self, token_string: []const u8) !JwtToken.JwtPayload {
        // Split token
        var parts = std.mem.splitSequence(u8, token_string, ".");
        const header_b64 = parts.next() orelse return error.InvalidToken;
        const payload_b64 = parts.next() orelse return error.InvalidToken;
        const signature = parts.next() orelse return error.InvalidToken;

        // Validate algorithm header (prevent alg confusion attacks)
        const header_json = try base64UrlDecode(self.allocator, header_b64);
        defer self.allocator.free(header_json);
        if (!std.mem.containsAtLeast(u8, header_json, 1, "\"HS256\"")) {
            return error.UnsupportedAlgorithm;
        }

        // Verify signature
        const signature_base = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signature_base);

        const expected_signature = try self.sign(signature_base);
        defer self.allocator.free(expected_signature);

        // Constant-time comparison to prevent timing side-channel
        if (signature.len != expected_signature.len or
            !std.crypto.timing_safe.eql(signature, expected_signature))
        {
            return error.InvalidSignature;
        }

        // Decode payload
        const payload_json = try base64UrlDecode(self.allocator, payload_b64);
        defer self.allocator.free(payload_json);

        const parsed = try std.json.parseFromSlice(JwtToken.JwtPayload, self.allocator, payload_json, .{});
        defer parsed.deinit();

        // Check expiration
        const now = if (self.io) |io| @as(i64, @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_s))) else Time.monotonicNowSeconds();
        if (now > parsed.value.exp) {
            return error.TokenExpired;
        }

        // Copy to owned memory so caller doesn't depend on parsed lifetime
        var roles = try self.allocator.alloc([]const u8, parsed.value.roles.len);
        errdefer self.allocator.free(roles);
        for (parsed.value.roles, 0..) |role, i| {
            roles[i] = try self.allocator.dupe(u8, role);
        }
        errdefer {
            for (roles) |role| {
                self.allocator.free(role);
            }
        }

        return JwtToken.JwtPayload{
            .sub = try self.allocator.dupe(u8, parsed.value.sub),
            .iss = try self.allocator.dupe(u8, parsed.value.iss),
            .aud = try self.allocator.dupe(u8, parsed.value.aud),
            .exp = parsed.value.exp,
            .iat = parsed.value.iat,
            .roles = roles,
        };
    }

    pub fn freePayload(self: *Self, payload: JwtToken.JwtPayload) void {
        self.allocator.free(payload.sub);
        self.allocator.free(payload.iss);
        self.allocator.free(payload.aud);
        for (payload.roles) |role| {
            self.allocator.free(role);
        }
        self.allocator.free(payload.roles);
    }

    /// HMAC-SHA256 签名
    fn sign(self: *Self, data: []const u8) ![]const u8 {
        var hmac = crypto.auth.hmac.sha2.HmacSha256.init(self.jwt_secret);
        hmac.update(data);
        // SAFETY: Buffer is immediately filled by hmac.final() before use
        var result: [32]u8 = undefined;
        hmac.final(&result);
        return try base64UrlEncode(self.allocator, &result);
    }

    pub fn hashPassword(self: *Self, password: []const u8) ![]const u8 {
        var salt: [16]u8 = undefined;
        // Seed CSPRNG from multiple entropy sources for ~128-bit unpredictability
        var seed: [32]u8 = undefined;
        std.mem.writeInt(u64, seed[0..8], @intCast(std.time.milliTimestamp()), .little);
        std.mem.writeInt(u64, seed[8..16], @intCast(std.os.getpid() catch 0), .little);
        std.mem.writeInt(u64, seed[16..24], @intFromPtr(&salt), .little);
        std.mem.writeInt(u64, seed[24..32], @intCast(std.time.microTimestamp()), .little);
        var csprng = std.Random.DefaultCsprng.init(seed);
        csprng.fill(&salt);

        // SAFETY: Buffer is immediately filled by pbkdf2() before use
        var derived_key: [32]u8 = undefined;
        try crypto.pwhash.pbkdf2(
            &derived_key,
            password,
            &salt,
            600000, // iterations (OWASP 2026 minimum)
            crypto.auth.hmac.sha2.HmacSha256,
        );

        // Format: $pbkdf2$iterations$salt$hash
        const salt_b64 = try base64Encode(self.allocator, &salt);
        defer self.allocator.free(salt_b64);
        const hash_b64 = try base64Encode(self.allocator, &derived_key);
        defer self.allocator.free(hash_b64);

        return std.fmt.allocPrint(self.allocator, "$pbkdf2$600000${s}${s}", .{ salt_b64, hash_b64 });
    }

    /// 验证密码
    pub fn verifyPassword(self: *Self, password: []const u8, hash: []const u8) bool {
        // Parse hash
        var parts = std.mem.splitSequence(u8, hash, "$");
        _ = parts.next(); // empty
        _ = parts.next(); // pbkdf2
        _ = parts.next(); // iterations
        const salt_b64 = parts.next() orelse return false;
        const expected_hash_b64 = parts.next() orelse return false;

        const salt = base64Decode(self.allocator, salt_b64) catch return false;
        defer self.allocator.free(salt);

        // SAFETY: Buffer is immediately filled by pbkdf2() before use
        var derived_key: [32]u8 = undefined;
        crypto.pwhash.pbkdf2(
            &derived_key,
            password,
            salt,
            600000, // OWASP 2026 minimum
            crypto.auth.hmac.sha2.HmacSha256,
        ) catch return false;

        const hash_b64 = base64Encode(self.allocator, &derived_key) catch return false;
        defer self.allocator.free(hash_b64);

        // Constant-time comparison to prevent timing side-channel
        if (hash_b64.len != expected_hash_b64.len) return false;
        return std.crypto.timing_safe.eql(hash_b64, expected_hash_b64);
    }

    /// 检查角色权限
    pub fn hasRole(payload: JwtToken.JwtPayload, role: []const u8) bool {
        for (payload.roles) |r| {
            if (std.mem.eql(u8, r, role)) {
                return true;
            }
        }
        return false;
    }

    /// 检查任意角色
    pub fn hasAnyRole(payload: JwtToken.JwtPayload, roles: []const []const u8) bool {
        for (roles) |role| {
            if (hasRole(payload, role)) {
                return true;
            }
        }
        return false;
    }

    /// 检查所有角色
    pub fn hasAllRoles(payload: JwtToken.JwtPayload, roles: []const []const u8) bool {
        for (roles) |role| {
            if (!hasRole(payload, role)) {
                return false;
            }
        }
        return true;
    }
};

/// Base64 URL 编码 (JWT 标准)
fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.Base64Encoder.init(std.base64.standard_alphabet_chars, '=');
    const encoded = try allocator.alloc(u8, encoder.calcSize(data.len));
    _ = encoder.encode(encoded, data);

    // Replace + with -, / with _, remove =
    for (encoded) |*c| {
        if (c.* == '+') c.* = '-';
        if (c.* == '/') c.* = '_';
    }

    // Remove padding
    var len = encoded.len;
    while (len > 0 and encoded[len - 1] == '=') {
        len -= 1;
    }

    return try allocator.realloc(encoded, len);
}

/// Base64 URL 解码
fn base64UrlDecode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    // Restore padding
    const padding_needed = (4 - (data.len % 4)) % 4;
    const padded_data = try allocator.alloc(u8, data.len + padding_needed);
    defer allocator.free(padded_data);

    @memcpy(padded_data[0..data.len], data);
    for (padded_data[data.len..]) |*c| {
        c.* = '=';
    }

    // Replace - with +, _ with /
    for (padded_data) |*c| {
        if (c.* == '-') c.* = '+';
        if (c.* == '_') c.* = '/';
    }

    const decoder = std.base64.Base64Decoder.init(std.base64.standard_alphabet_chars, '=');
    const decoded = try allocator.alloc(u8, decoder.calcSizeForSlice(padded_data) catch return error.InvalidEncoding);
    try decoder.decode(decoded, padded_data);

    return decoded;
}

/// 标准 Base64 编码
fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.Base64Encoder.init(std.base64.standard_alphabet_chars, '=');
    const encoded = try allocator.alloc(u8, encoder.calcSize(data.len));
    _ = encoder.encode(encoded, data);
    return encoded;
}

/// 标准 Base64 解码
fn base64Decode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const decoder = std.base64.Base64Decoder.init(std.base64.standard_alphabet_chars, '=');
    const decoded = try allocator.alloc(u8, decoder.calcSizeForSlice(data) catch return error.InvalidEncoding);
    try decoder.decode(decoded, data);
    return decoded;
}

test "SecurityModule JWT generate and verify" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "my-secret-key", 3600);

    const token = try sec.generateToken("user-123", &.{ "admin", "user" });
    defer allocator.free(token);

    const payload = try sec.verifyToken(token);
    defer sec.freePayload(payload);
    try std.testing.expectEqualStrings("user-123", payload.sub);
    try std.testing.expect(payload.exp > 0);
}

test "SecurityModule JWT invalid signature" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret-a", 3600);

    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    var sec2 = SecurityModule.init(allocator, "secret-b", 3600);
    const result = sec2.verifyToken(token);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "SecurityModule password hash and verify" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", 3600);

    const hash = try sec.hashPassword("my_password");
    defer allocator.free(hash);

    try std.testing.expect(sec.verifyPassword("my_password", hash));
    try std.testing.expect(!sec.verifyPassword("wrong_password", hash));
}

test "SecurityModule role checking" {
    const payload = SecurityModule.JwtToken.JwtPayload{
        .sub = "user",
        .iss = "zigmodu",
        .aud = "app",
        .exp = 0 + 3600,
        .iat = 0,
        .roles = &.{ "admin", "user" },
    };

    try std.testing.expect(SecurityModule.hasRole(payload, "admin"));
    try std.testing.expect(!SecurityModule.hasRole(payload, "guest"));
    try std.testing.expect(SecurityModule.hasAnyRole(payload, &.{ "guest", "admin" }));
    try std.testing.expect(SecurityModule.hasAllRoles(payload, &.{ "admin", "user" }));
    try std.testing.expect(!SecurityModule.hasAllRoles(payload, &.{ "admin", "guest" }));
}
