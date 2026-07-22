//! JWKS / Multi-Key Manager for Key Rotation and JWT Verification.
//! Supports signing with the active key (primary_kid) and verifying with any valid key in the keyring.

const std = @import("std");

pub const KeyInfo = struct {
    kid: []const u8,
    secret: []const u8,
    algorithm: []const u8 = "HS256",
    is_active: bool = true,
};

pub const JwksKeyRing = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    keys: std.StringHashMap(KeyInfo),
    primary_kid: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .keys = std.StringHashMap(KeyInfo).init(allocator),
            .primary_kid = null,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.keys.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.secret);
            self.allocator.free(entry.value_ptr.algorithm);
        }
        if (self.primary_kid) |pk| {
            self.allocator.free(pk);
        }
        self.keys.deinit();
        self.* = undefined;
    }

    /// Register a key into the KeyRing. If mark_primary is true, set as active signing key.
    pub fn addKey(self: *Self, kid: []const u8, secret: []const u8, mark_primary: bool) !void {
        const kid_copy = try self.allocator.dupe(u8, kid);
        errdefer self.allocator.free(kid_copy);

        const secret_copy = try self.allocator.dupe(u8, secret);
        errdefer self.allocator.free(secret_copy);

        const alg_copy = try self.allocator.dupe(u8, "HS256");
        errdefer self.allocator.free(alg_copy);

        const key_info = KeyInfo{
            .kid = kid_copy,
            .secret = secret_copy,
            .algorithm = alg_copy,
            .is_active = true,
        };

        const res = try self.keys.getOrPut(kid_copy);
        if (res.found_existing) {
            self.allocator.free(kid_copy);
            self.allocator.free(res.value_ptr.secret);
            self.allocator.free(res.value_ptr.algorithm);
            res.value_ptr.* = key_info;
        } else {
            res.value_ptr.* = key_info;
        }

        if (mark_primary or self.primary_kid == null) {
            if (self.primary_kid) |pk| {
                self.allocator.free(pk);
            }
            self.primary_kid = try self.allocator.dupe(u8, kid);
        }
    }

    /// Retrieve key by kid for verification.
    pub fn getKey(self: *const Self, kid: []const u8) ?KeyInfo {
        return self.keys.get(kid);
    }

    /// Get primary key for signing new tokens.
    pub fn getPrimaryKey(self: *const Self) ?KeyInfo {
        if (self.primary_kid) |pk| {
            return self.keys.get(pk);
        }
        return null;
    }

    /// Total count of keys registered.
    pub fn count(self: *const Self) usize {
        return self.keys.count();
    }
};

test "JwksKeyRing basic rotation" {
    const allocator = std.testing.allocator;
    var ring = JwksKeyRing.init(allocator);
    defer ring.deinit();

    try ring.addKey("v1-key", "secret-2025", true);
    try std.testing.expectEqualStrings("v1-key", ring.getPrimaryKey().?.kid);

    try ring.addKey("v2-key", "secret-2026", true);
    try std.testing.expectEqualStrings("v2-key", ring.getPrimaryKey().?.kid);

    // Old key still retrievable for verification during rotation grace period
    const old_key = ring.getKey("v1-key");
    try std.testing.expect(old_key != null);
    try std.testing.expectEqualStrings("secret-2025", old_key.?.secret);
}
