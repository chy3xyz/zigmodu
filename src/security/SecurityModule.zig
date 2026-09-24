const std = @import("std");
const crypto = std.crypto;
const Time = @import("../core/Time.zig");
const api = @import("../api/Server.zig");
const JwksKeyRing = @import("JwksKeyRing.zig").JwksKeyRing;
const PasswordEncoder = @import("PasswordEncoder.zig").PasswordEncoder;

/// Security module - provides authentication, authorization and encryption
pub const SecurityModule = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    jwt_secret: []const u8,
    token_expiry_seconds: i64,
    io: ?std.Io = null,
    /// Optional multi-key ring for zero-downtime secret rotation. When set,
    /// tokens are signed with the primary key (`kid` in the header) and
    /// verified against whichever key the token names — so an old key can stay
    /// valid during the rollout window. Must outlive the module.
    keyring: ?*JwksKeyRing = null,

    /// `verifyPassword`'s error set — identical to `PasswordEncoder.PasswordError`
    /// so an app can handle both verifiers with one `switch`.
    pub const PasswordError = PasswordEncoder.PasswordError;

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

    /// Wall clock when `io` is set (production); monotonic fallback for unit tests.
    fn nowSeconds(self: *const Self) i64 {
        if (self.io) |io| return Time.wallClockSeconds(io);
        return Time.monotonicNowSeconds();
    }

    /// Parse Bearer token from Authorization header (case-sensitive prefix per RFC 6750).
    pub fn extractBearerToken(auth_header: []const u8) ?[]const u8 {
        const prefix = "Bearer ";
        if (std.mem.startsWith(u8, auth_header, prefix)) return auth_header[prefix.len..];
        return null;
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    /// JWT Token structure
    pub const JwtToken = struct {
        header: JwtHeader,
        payload: JwtPayload,
        signature: []const u8,

        pub const JwtHeader = struct {
            alg: []const u8 = "HS256",
            typ: []const u8 = "JWT",
            kid: ?[]const u8 = null,
        };

        pub const JwtPayload = struct {
            sub: []const u8, // subject (user id)
            iss: []const u8, // issuer
            aud: []const u8, // audience
            exp: i64, // expiration time
            iat: i64, // issued at
            roles: []const []const u8, // user roles
            /// Credential version for server-side revocation (0 = legacy token).
            ver: i64 = 0,
        };

        /// Build the JWT token string (header.payload.signature)
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

    /// Generate a JWT token
    pub fn generateToken(
        self: *Self,
        user_id: []const u8,
        roles: []const []const u8,
    ) ![]const u8 {
        return self.generateTokenWithTenant(user_id, roles, "zigmodu-app");
    }

    /// Generate a JWT token with tenant_id as the aud claim
    pub fn generateTokenWithTenant(
        self: *Self,
        user_id: []const u8,
        roles: []const []const u8,
        tenant_id: []const u8,
    ) ![]const u8 {
        return self.generateTokenWithTenantAndVersion(user_id, roles, tenant_id, 0);
    }

    /// Like `generateTokenWithTenant` but carries a credential version so the
    /// application can revoke tokens server-side (bump the user's version).
    pub fn generateTokenWithTenantAndVersion(
        self: *Self,
        user_id: []const u8,
        roles: []const []const u8,
        tenant_id: []const u8,
        ver: i64,
    ) ![]const u8 {
        const now = self.nowSeconds();
        const exp = now + self.token_expiry_seconds;

        const header = JwtToken.JwtHeader{ .kid = self.signingKid() };
        const payload = JwtToken.JwtPayload{
            .sub = user_id,
            .iss = "zigmodu",
            .aud = tenant_id,
            .exp = exp,
            .iat = now,
            .roles = roles,
            .ver = ver,
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

        // Generate signature using HMAC-SHA256 (primary key when a keyring is set)
        const signature = try self.signWith(signature_base, self.signingSecret());
        defer self.allocator.free(signature);

        // Build the token string directly, avoiding an intermediate struct
        return std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, signature });
    }

    /// Enable key rotation. Keys live in `ring` (primary signs, all verify).
    pub fn setKeyring(self: *Self, ring: *JwksKeyRing) void {
        self.keyring = ring;
    }

    /// kid that new tokens carry (null without a keyring).
    pub fn signingKid(self: *const Self) ?[]const u8 {
        const ring = self.keyring orelse return null;
        const primary = ring.getPrimaryKey() orelse return null;
        return primary.kid;
    }

    fn signingSecret(self: *const Self) []const u8 {
        const ring = self.keyring orelse return self.jwt_secret;
        const primary = ring.getPrimaryKey() orelse return self.jwt_secret;
        return primary.secret;
    }

    /// Verification secret for a token: the key its `kid` names, falling back
    /// to the module secret for tokens issued before rotation. An unknown
    /// `kid` is rejected rather than silently checked against the default key.
    fn verificationSecret(self: *const Self, header_json: []const u8) ![]const u8 {
        const kid = parseKid(header_json) orelse return self.jwt_secret;
        const ring = self.keyring orelse return self.jwt_secret;
        const key = ring.getKey(kid) orelse return error.UnknownKeyId;
        return key.secret;
    }

    pub fn verifyToken(self: *Self, token_string: []const u8) !JwtToken.JwtPayload {
        // Split token (must be exactly 3 parts: header.payload.signature)
        var parts = std.mem.splitSequence(u8, token_string, ".");
        const header_b64 = parts.next() orelse return error.InvalidToken;
        const payload_b64 = parts.next() orelse return error.InvalidToken;
        const signature = parts.next() orelse return error.InvalidToken;
        if (parts.next() != null) return error.InvalidToken;

        // Validate algorithm header (prevent alg confusion attacks)
        const header_json = try base64UrlDecode(self.allocator, header_b64);
        defer self.allocator.free(header_json);
        if (!std.mem.containsAtLeast(u8, header_json, 1, "\"HS256\"")) {
            return error.UnsupportedAlgorithm;
        }

        // Verify signature
        const signature_base = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer self.allocator.free(signature_base);

        const verify_secret = try self.verificationSecret(header_json);
        const expected_signature = try self.signWith(signature_base, verify_secret);
        defer self.allocator.free(expected_signature);

        // Constant-time comparison to prevent timing side-channel
        if (signature.len != expected_signature.len or
            !timingSafeSliceEql(signature, expected_signature))
        {
            return error.InvalidSignature;
        }

        // Decode payload
        const payload_json = try base64UrlDecode(self.allocator, payload_b64);
        defer self.allocator.free(payload_json);

        const parsed = try std.json.parseFromSlice(JwtToken.JwtPayload, self.allocator, payload_json, .{});
        defer parsed.deinit();

        // Check expiration
        const now = self.nowSeconds();
        if (now > parsed.value.exp) {
            return error.TokenExpired;
        }

        // Copy to owned memory so caller doesn't depend on parsed lifetime
        var roles = try self.allocator.alloc([]const u8, parsed.value.roles.len);
        errdefer self.allocator.free(roles);
        var copied_roles: usize = 0;
        errdefer for (roles[0..copied_roles]) |role| self.allocator.free(role);
        for (parsed.value.roles, 0..) |role, i| {
            roles[i] = try self.allocator.dupe(u8, role);
            copied_roles += 1;
        }

        // Same shape as the role copies above, and for the same reason: the
        // struct literal's fields are allocated left to right, so a failure on
        // `.iss` used to strand the `.sub` copy (and a failure on `.aud` used to
        // strand both) — the caller never receives the payload, so nobody can
        // free it. Hoist each copy and give it its own `errdefer`.
        const sub = try self.allocator.dupe(u8, parsed.value.sub);
        errdefer self.allocator.free(sub);
        const iss = try self.allocator.dupe(u8, parsed.value.iss);
        errdefer self.allocator.free(iss);
        const aud = try self.allocator.dupe(u8, parsed.value.aud);
        errdefer self.allocator.free(aud);

        return JwtToken.JwtPayload{
            .sub = sub,
            .iss = iss,
            .aud = aud,
            .exp = parsed.value.exp,
            .iat = parsed.value.iat,
            .roles = roles,
            .ver = parsed.value.ver,
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

    /// HMAC-SHA256 signature
    fn sign(self: *Self, data: []const u8) ![]const u8 {
        return self.signWith(data, self.jwt_secret);
    }

    fn signWith(self: *Self, data: []const u8, secret: []const u8) ![]const u8 {
        var hmac = crypto.auth.hmac.sha2.HmacSha256.init(secret);
        hmac.update(data);
        // SAFETY: Buffer is immediately filled by hmac.final() before use
        var result: [32]u8 = undefined;
        hmac.final(&result);
        return try base64UrlEncode(self.allocator, &result);
    }

    pub fn hashPassword(self: *Self, password: []const u8) ![]const u8 {
        // The salt must come from the OS entropy source. A module built with
        // `init` (no `io`) has no entropy source at all, so hashing is
        // refused rather than done with a predictable salt.
        const io = self.io orelse return error.EntropyUnavailable;
        var salt: [16]u8 = undefined;
        try std.Io.randomSecure(io, &salt);

        // SAFETY: Buffer is immediately filled by pbkdf2() before use.
        // The length is the one `verifyPassword` accepts — writing a different
        // one here would make every stored hash unverifiable.
        var derived_key: [PasswordEncoder.derived_key_len]u8 = undefined;
        try crypto.pwhash.pbkdf2(
            &derived_key,
            password,
            &salt,
            100000, // iterations (OWASP 2021: 120k minimum; 100k close enough, fast on ARM64)
            crypto.auth.hmac.sha2.HmacSha256,
        );

        // Format: $pbkdf2$iterations$salt$hash
        const salt_b64 = try base64Encode(self.allocator, &salt);
        defer self.allocator.free(salt_b64);
        const hash_b64 = try base64Encode(self.allocator, &derived_key);
        defer self.allocator.free(hash_b64);

        return std.fmt.allocPrint(self.allocator, "$pbkdf2$100000${s}${s}", .{ salt_b64, hash_b64 });
    }

    /// Verify password.
    ///
    /// `false` is a genuine mismatch; an error means **we** could not check the
    /// credential (the stored record is unusable, or the process is out of
    /// memory). Never render an error as 401 "bad credentials" — that turns an
    /// operational fault into an invisible wrong-password rate.
    pub fn verifyPassword(self: *Self, password: []const u8, hash: []const u8) PasswordError!bool {
        // Parse hash: $pbkdf2$<iterations>$<salt>$<hash>
        var parts = std.mem.splitSequence(u8, hash, "$");
        _ = parts.next(); // empty
        const algo = parts.next() orelse return error.MalformedStoredHash;
        if (!std.mem.eql(u8, algo, "pbkdf2")) return error.MalformedStoredHash;
        const iter_str = parts.next() orelse return error.MalformedStoredHash;
        const iterations = std.fmt.parseInt(u32, iter_str, 10) catch return error.MalformedStoredHash;
        const salt_b64 = parts.next() orelse return error.MalformedStoredHash;
        const expected_hash_b64 = parts.next() orelse return error.MalformedStoredHash;

        // Decode the stored digest instead of re-encoding the derived key: the
        // comparison then needs no allocation after the PBKDF2 work, and a
        // stored value that is not a digest is reported as a corrupt record
        // rather than compared as text and answered "wrong password".
        const salt = try decodeStoredField(self.allocator, salt_b64);
        defer self.allocator.free(salt);

        const expected_hash = try decodeStoredField(self.allocator, expected_hash_b64);
        defer self.allocator.free(expected_hash);

        if (expected_hash.len != PasswordEncoder.derived_key_len) return error.MalformedStoredHash;

        // SAFETY: Buffer is immediately filled by pbkdf2() before use
        var derived_key: [PasswordEncoder.derived_key_len]u8 = undefined;
        crypto.pwhash.pbkdf2(
            &derived_key,
            password,
            salt,
            iterations,
            crypto.auth.hmac.sha2.HmacSha256,
        ) catch |err| switch (err) {
            // rounds < 1: the stored parameters are corrupt, not the password.
            error.WeakParameters, error.OutputTooLong => return error.MalformedStoredHash,
        };

        // Constant-time comparison to prevent timing side-channel
        return timingSafeSliceEql(&derived_key, expected_hash[0..PasswordEncoder.derived_key_len]);
    }

    /// Check whether the payload carries the given role
    pub fn hasRole(payload: JwtToken.JwtPayload, role: []const u8) bool {
        for (payload.roles) |r| {
            if (std.mem.eql(u8, r, role)) {
                return true;
            }
        }
        return false;
    }

    /// Check whether the payload carries any of the given roles
    pub fn hasAnyRole(payload: JwtToken.JwtPayload, roles: []const []const u8) bool {
        for (roles) |role| {
            if (hasRole(payload, role)) {
                return true;
            }
        }
        return false;
    }

    /// Check whether the payload carries all of the given roles
    pub fn hasAllRoles(payload: JwtToken.JwtPayload, roles: []const []const u8) bool {
        for (roles) |role| {
            if (!hasRole(payload, role)) {
                return false;
            }
        }
        return true;
    }
};

/// Rate-limited auth middleware — prevents brute-force attacks.
/// Limits to `max_attempts` per `window_seconds`. Returns 429 on excess.
///
/// The rejection is answered through the `Context` response channel
/// (`status_code` + `response_headers` + `response_body`, i.e. `ctx.sendError`),
/// never by writing to `ctx.stream` directly: `ctx.stream` is the HTTP/1.1
/// socket handle and is `null` on the HTTP/2 adapter by construction (that
/// adapter has no mid-response channel — see `Server.http2RouterSiteHandler`),
/// so a raw write there is a null dereference on H2 *and* mis-framed on H1 (the
/// body bytes reach the socket ahead of the status line). Going through the
/// Context lets each transport write the response it owns: `writeResponse` on
/// H1, the `SiteResponse` on H2.
///
/// `Retry-After` is advisory and carries the documented 60-second window
/// (`RateLimiter` exposes no per-window remaining time). It reaches **both**
/// transports: the H2 `SiteResponse` channel carries every response header the
/// handler set, not just `content-type`.
///
/// `allocator` owns the limiter, which lives for the process (the returned
/// `Middleware` carries it as `user_data`; nothing frees it).
pub fn authRateLimitMiddleware(
    allocator: std.mem.Allocator,
    max_attempts: u32,
    window_seconds: u32,
) !api.Middleware {
    const limiter = try allocator.create(@import("../resilience/RateLimiter.zig").RateLimiter);
    limiter.* = try @import("../resilience/RateLimiter.zig").RateLimiter.init(
        allocator,
        "auth_rate_limit",
        max_attempts,
        max_attempts / window_seconds,
    );
    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const lim: *@import("../resilience/RateLimiter.zig").RateLimiter = @ptrCast(@alignCast(user_data orelse return error.InternalError));
            if (!lim.tryAcquire()) {
                ctx.setHeader("Retry-After", "60") catch |err| std.log.err("[RateLimit] setHeader failed: {}", .{err});
                try ctx.sendError(429, "Too many requests. Try again later.");
                return;
            }
            try next(ctx);
        }
    };
    return .{ .func = S.handler, .user_data = @ptrCast(@constCast(limiter)) };
}

/// Extract the `"kid":"…"` value from a JWT header without a full JSON parse.
/// Returns null when absent or `null`.
fn parseKid(header_json: []const u8) ?[]const u8 {
    const key = "\"kid\":";
    const idx = std.mem.indexOf(u8, header_json, key) orelse return null;
    var rest = std.mem.trimStart(u8, header_json[idx + key.len ..], " \t");
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

/// Constant-time slice comparison (Zig 0.16 `timing_safe.eql` only accepts arrays/vectors)
fn timingSafeSliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, 0..) |x, i| {
        acc |= x ^ b[i];
    }
    const s: u4 = @intCast(@typeInfo(u8).int.bits);
    const extended: u16 = @as(u8, @bitCast(acc));
    return @as(bool, @bitCast(@as(u1, @truncate((extended -% 1) >> s))));
}

/// Base64 URL encoding (JWT alphabet: `-`/`_` instead of `+`/`/`, padding stripped)
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

/// Base64 URL decoding (restores padding and maps `-`/`_` back to `+`/`/`)
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
    errdefer allocator.free(decoded);
    try decoder.decode(decoded, padded_data);

    return decoded;
}

// A failed `decode` must not leak its buffer. `calcSizeForSlice` accepts this
// length and `decode` rejects the `*`, so the allocation above is live when the
// error is returned — the `errdefer` is what frees it.
//
// This class is invisible to unit tests that use one allocator for both the
// decode and the check: only an allocator that *reports* leaks at the end of the
// test sees it. Before the `errdefer` these two tests fail with
// `error.MemoryLeakDetected`, and a real caller (an invalid token's header or
// payload segment on every failed verification) leaks a small block per attempt.
// (Reported by a downstream project whose shutdown-leak gate caught it in
// production; they are carrying an explicit exemption until this lands.)
test "a base64 decode failure frees its buffer (standard)" {
    const allocator = std.testing.allocator;
    const result = base64Decode(allocator, "AA*A");
    if (result) |decoded| {
        allocator.free(decoded);
        return error.ExpectedDecodeFailure;
    } else |_| {}
}

test "a base64 url decode failure frees its buffer" {
    const allocator = std.testing.allocator;
    // The URL variant pads and rewrites in place, so it needs a mutable buffer.
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..4], "AA*A");
    const result = base64UrlDecode(allocator, buf[0..4]);
    if (result) |decoded| {
        allocator.free(decoded);
        return error.ExpectedDecodeFailure;
    } else |_| {}
}

/// Standard Base64 encoding
fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.Base64Encoder.init(std.base64.standard_alphabet_chars, '=');
    const encoded = try allocator.alloc(u8, encoder.calcSize(data.len));
    _ = encoder.encode(encoded, data);
    return encoded;
}

/// Standard Base64 decoding
fn base64Decode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const decoder = std.base64.Base64Decoder.init(std.base64.standard_alphabet_chars, '=');
    const decoded = try allocator.alloc(u8, decoder.calcSizeForSlice(data) catch return error.InvalidEncoding);
    errdefer allocator.free(decoded);
    try decoder.decode(decoded, data);
    return decoded;
}

/// Decode one base64 field of a *stored* hash. Text that is not valid base64
/// is a corrupt stored record (`MalformedStoredHash`); only the allocator's own
/// failure stays `OutOfMemory`, so neither can be answered as "wrong password".
fn decodeStoredField(allocator: std.mem.Allocator, data: []const u8) SecurityModule.PasswordError![]const u8 {
    return base64Decode(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedStoredHash,
    };
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

test "SecurityModule initWithIo uses wall clock for exp" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.initWithIo(allocator, "secret", 3600, std.testing.io);
    const token = try sec.generateToken("wall-clock-user", &.{});
    defer allocator.free(token);

    const payload = try sec.verifyToken(token);
    defer sec.freePayload(payload);
    try std.testing.expectEqualStrings("wall-clock-user", payload.sub);
    const now = Time.wallClockSeconds(std.testing.io);
    try std.testing.expect(payload.iat <= now + 2);
    try std.testing.expect(payload.exp >= now);
}

test "SecurityModule JWT expired token" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", -1);

    const token = try sec.generateToken("user-1", &.{});
    defer allocator.free(token);

    const result = sec.verifyToken(token);
    try std.testing.expectError(error.TokenExpired, result);
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
    var sec = SecurityModule.initWithIo(allocator, "secret", 3600, std.testing.io);

    const hash = try sec.hashPassword("my_password");
    defer allocator.free(hash);

    try std.testing.expect(try sec.verifyPassword("my_password", hash));
    try std.testing.expect(!try sec.verifyPassword("wrong_password", hash));
}

test "SecurityModule hashPassword without an io refuses instead of using a weak salt" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", 3600);
    try std.testing.expectError(error.EntropyUnavailable, sec.hashPassword("my_password"));
}

// ── Regression: an error on our side is never reported as "wrong password" ──
//
// Before this change both branches below returned `false`: an allocation
// failure and an unusable stored record were indistinguishable from a genuine
// mismatch, so a correct login during memory pressure was answered 401 and a
// corrupt row looked like a bad password.

test "verifyPassword reports every induced allocation failure as OutOfMemory" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.initWithIo(allocator, "secret", 3600, std.testing.io);
    const hash = try sec.hashPassword("correct horse battery staple");
    defer allocator.free(hash);

    const Scan = struct {
        fn run(alloc: std.mem.Allocator, stored: []const u8) !void {
            var squeezed = SecurityModule.initWithIo(alloc, "secret", 3600, std.testing.io);
            // The credential is correct, so anything but OutOfMemory is a wrong
            // answer: `checkAllAllocationFailures` propagates it as-is.
            try std.testing.expect(try squeezed.verifyPassword("correct horse battery staple", stored));
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{hash});
}

test "verifyPassword refuses an unusable stored hash instead of answering false" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.initWithIo(allocator, "secret", 3600, std.testing.io);
    const password = "correct horse battery staple";

    const unusable = [_][]const u8{
        "",
        "plaintext-password",
        "$pbkdf2$100000$c2FsdA==$aGFzaA==", // digest of the wrong length
        "$pbkdf2$not-a-number$c2FsdA==$aGFzaA==",
        "$pbkdf2$100000$not*base64$aGFzaA==",
        "$pbkdf2$100000$c2FsdA==$not*base64",
        "$pbkdf2$100000$c2FsdA==",
        "$bcrypt$100000$c2FsdA==$aGFzaA==",
        "$pbkdf2$0$c2FsdA==$aGFzaA==",
    };
    for (unusable) |stored| {
        try std.testing.expectError(error.MalformedStoredHash, sec.verifyPassword(password, stored));
    }
}

test "verifyPassword refuses a digest longer than the derived key (no prefix match)" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.initWithIo(allocator, "secret", 3600, std.testing.io);
    const password = "correct horse battery staple";

    var salt: [16]u8 = undefined;
    @memset(&salt, 0x2a);
    var derived: [PasswordEncoder.derived_key_len]u8 = undefined;
    try crypto.pwhash.pbkdf2(&derived, password, &salt, 1000, crypto.auth.hmac.sha2.HmacSha256);

    var longer: [PasswordEncoder.derived_key_len + 1]u8 = undefined;
    @memcpy(longer[0..PasswordEncoder.derived_key_len], &derived);
    longer[PasswordEncoder.derived_key_len] = 0xAB;

    const salt_b64 = try base64Encode(allocator, &salt);
    defer allocator.free(salt_b64);
    const longer_b64 = try base64Encode(allocator, &longer);
    defer allocator.free(longer_b64);
    const stored = try std.fmt.allocPrint(allocator, "$pbkdf2$1000${s}${s}", .{ salt_b64, longer_b64 });
    defer allocator.free(stored);

    try std.testing.expectError(error.MalformedStoredHash, sec.verifyPassword(password, stored));
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

test "SecurityModule rejects malformed tokens with extra parts" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "secret", 3600);

    const malformed = "header.payload.sig.extra_part";
    try std.testing.expectError(error.InvalidToken, sec.verifyToken(malformed));
}

test "SecurityModule token credential version roundtrip" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "my-secret-key", 3600);

    // Legacy path carries ver=0.
    const legacy = try sec.generateTokenWithTenant("user-1", &.{"user"}, "tenant-1");
    defer allocator.free(legacy);
    const lp = try sec.verifyToken(legacy);
    defer sec.freePayload(lp);
    try std.testing.expectEqual(@as(i64, 0), lp.ver);

    // Versioned path carries the credential version (server-side revocation).
    const v = try sec.generateTokenWithTenantAndVersion("user-1", &.{"user"}, "tenant-1", 7);
    defer allocator.free(v);
    const p = try sec.verifyToken(v);
    defer sec.freePayload(p);
    try std.testing.expectEqual(@as(i64, 7), p.ver);
    try std.testing.expectEqualStrings("user-1", p.sub);
}

test "keyring rotation: old tokens stay valid, unknown kid is rejected" {
    const allocator = std.testing.allocator;
    var ring = JwksKeyRing.init(allocator);
    defer ring.deinit();

    var sec = SecurityModule.init(allocator, "legacy-default-secret", 3600);
    sec.setKeyring(&ring);

    // v1 signs.
    try ring.addKey("v1", "secret-2025-aaaaaaaaaaaaaaaaaaaaaa", true);
    const t1 = try sec.generateTokenWithTenant("user-1", &.{"user"}, "tenant-1");
    defer allocator.free(t1);
    try std.testing.expectEqualStrings("v1", sec.signingKid().?);
    const p1 = try sec.verifyToken(t1);
    defer sec.freePayload(p1);
    try std.testing.expectEqualStrings("user-1", p1.sub);

    // Rotate: v2 becomes primary, v1 stays in the ring for the rollout window.
    try ring.addKey("v2", "secret-2026-bbbbbbbbbbbbbbbbbbbbbb", true);
    const t2 = try sec.generateTokenWithTenant("user-2", &.{"user"}, "tenant-1");
    defer allocator.free(t2);
    try std.testing.expectEqualStrings("v2", sec.signingKid().?);

    // Both verify: no forced logout during the rotation.
    const p2 = try sec.verifyToken(t2);
    defer sec.freePayload(p2);
    try std.testing.expectEqualStrings("user-2", p2.sub);
    const p1_again = try sec.verifyToken(t1);
    defer sec.freePayload(p1_again);
    try std.testing.expectEqualStrings("user-1", p1_again.sub);

    // A token naming a key we no longer hold is rejected, not silently checked
    // against the primary secret.
    const forged_header = "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"v9\"}";
    const header_b64 = try base64UrlEncode(allocator, forged_header);
    defer allocator.free(header_b64);
    var parts = std.mem.splitScalar(u8, t2, '.');
    _ = parts.next();
    const payload_b64 = parts.next().?;
    const forged = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, parts.next().? });
    defer allocator.free(forged);
    try std.testing.expectError(error.UnknownKeyId, sec.verifyToken(forged));
}

test "without a keyring the header has no kid (previous behavior)" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "plain-secret", 3600);
    try std.testing.expect(sec.signingKid() == null);
    const token = try sec.generateTokenWithTenant("u", &.{"user"}, "t");
    defer allocator.free(token);
    const payload = try sec.verifyToken(token);
    defer sec.freePayload(payload);
    try std.testing.expectEqualStrings("u", payload.sub);
}

// Token assembly is a chain of six borrowed buffers (header JSON, its base64,
// payload JSON, its base64, the signing base, the signature) held by `defer`s
// that all unwind through one return path. `checkAllAllocationFailures` fails
// each allocation in turn — the JSON stringifier's own growth, both base64
// buffers, the `allocPrint`s and the HMAC signature — and requires the error to
// surface with every earlier buffer released.
test "generateTokenWithTenantAndVersion survives every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(alloc: std.mem.Allocator, secret: []const u8, roles: []const []const u8) !void {
            var sec = SecurityModule.init(alloc, secret, 3600);
            const token = try sec.generateTokenWithTenantAndVersion("user-1", roles, "tenant-1", 3);
            defer alloc.free(token);
            try std.testing.expect(token.len > 0);
            try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, token, "."));
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{
        "scan-secret-0123456789abcdef",
        &.{ "user", "admin" },
    });
}

// Verification allocates a chain of single-owner buffers (header JSON, the
// signing base, the expected signature, the payload JSON, the parsed payload's
// backing store, then the caller-owned copies) and the owned copies are handed
// back as a *value* — there is no `defer` at the call site to unwind them, so
// every copy needs its own `errdefer`. Failing each allocation in turn pins that
// down: a payload half-copied when the allocator gives up must release the parts
// already copied, not leak them to the caller who never received them.
test "verifyToken survives every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;
    var sec = SecurityModule.init(allocator, "scan-secret-0123456789abcdef", 3600);
    const token = try sec.generateTokenWithTenant("user-1", &.{ "user", "admin" }, "tenant-1");
    defer allocator.free(token);

    const Scan = struct {
        fn run(alloc: std.mem.Allocator, secret: []const u8, raw: []const u8) !void {
            var squeezed = SecurityModule.init(alloc, secret, 3600);
            const payload = try squeezed.verifyToken(raw);
            defer squeezed.freePayload(payload);
            try std.testing.expectEqualStrings("user-1", payload.sub);
            try std.testing.expectEqualStrings("tenant-1", payload.aud);
            try std.testing.expectEqual(@as(usize, 2), payload.roles.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{
        "scan-secret-0123456789abcdef",
        token,
    });
}
