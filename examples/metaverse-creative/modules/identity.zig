const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Identity Module - 去中心化身份管理
/// 管理创作者的 DID、声誉和权限
/// ============================================
/// NOTE: This module uses global state and is NOT thread-safe.
///       For concurrent access, external synchronization is required.
pub const IdentityModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "identity",
        .description = "Decentralized identity and reputation management",
        .dependencies = &.{},
    };

    var identities: std.StringHashMap(CreatorIdentity) = undefined;
    var allocator: ?std.mem.Allocator = null;

    pub fn init() !void {
        try initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(alloc: std.mem.Allocator) !void {
        if (allocator != null) return error.AlreadyInitialized;
        
        allocator = alloc;
        identities = std.StringHashMap(CreatorIdentity).init(alloc);
        std.log.info("[identity] Identity module initialized", .{});
    }

    pub fn deinit() void {
        const alloc = allocator orelse return;
        
        var iter = identities.iterator();
        while (iter.next()) |entry| {
            // Free the hash map key (we duplicated it on put)
            alloc.free(entry.key_ptr.*);
            // Free all strings inside the value
            entry.value_ptr.deinit(alloc);
        }
        identities.deinit();
        allocator = null;
        
        std.log.info("[identity] Identity module cleaned up", .{});
    }

    /// 创作者身份
    pub const CreatorIdentity = struct {
        did: []const u8,
        display_name: []const u8,
        wallet_address: []const u8,
        reputation_score: u32 = 0, // 声誉分数 (0-10000)
        created_at: i64,
        verified: bool = false,

        pub fn deinit(self: *CreatorIdentity, alloc: std.mem.Allocator) void {
            alloc.free(self.did);
            alloc.free(self.display_name);
            alloc.free(self.wallet_address);
        }

        pub fn getReputationLevel(self: CreatorIdentity) ReputationLevel {
            return if (self.reputation_score >= 8000) .legend
                else if (self.reputation_score >= 6000) .expert
                else if (self.reputation_score >= 4000) .established
                else if (self.reputation_score >= 2000) .rising
                else .novice;
        }
    };

    pub const ReputationLevel = enum {
        novice, // 新手
        rising, // 崛起中
        established, // 已建立
        expert, // 专家
        legend, // 传奇

        pub fn getMultiplier(self: ReputationLevel) f64 {
            return switch (self) {
                .novice => 1.0,
                .rising => 1.2,
                .established => 1.5,
                .expert => 2.0,
                .legend => 3.0,
            };
        }
    };

    /// 注册新创作者
    pub fn registerCreator(did: []const u8, name: []const u8, wallet: []const u8) !void {
        const alloc = allocator orelse return error.NotInitialized;
        
        // Input validation
        if (did.len == 0 or did.len > 256) return error.InvalidDID;
        if (name.len == 0 or name.len > 256) return error.InvalidName;
        if (wallet.len == 0 or wallet.len > 256) return error.InvalidWallet;
        if (identities.contains(did)) return error.DuplicateDID;

        const did_copy = try alloc.dupe(u8, did);
        errdefer alloc.free(did_copy);
        
        const name_copy = try alloc.dupe(u8, name);
        errdefer alloc.free(name_copy);
        
        const wallet_copy = try alloc.dupe(u8, wallet);
        errdefer alloc.free(wallet_copy);

        const identity = CreatorIdentity{
            .did = did_copy,
            .display_name = name_copy,
            .wallet_address = wallet_copy,
            .created_at = 0,
        };

        try identities.put(did_copy, identity);

        std.log.info("[identity] Creator registered: {s} ({s})", .{ name, did });
    }

    /// 获取创作者信息
    pub fn getCreator(did: []const u8) ?CreatorIdentity {
        return identities.get(did);
    }

    /// 更新声誉分数
    pub fn updateReputation(did: []const u8, delta: i32) !void {
        const alloc = allocator orelse return error.NotInitialized;
        _ = alloc;
        
        if (did.len == 0) return error.InvalidDID;
        
        var identity = identities.getPtr(did) orelse return error.IdentityNotFound;

        const current: i64 = @intCast(identity.reputation_score);
        const new_score = std.math.clamp(current + delta, 0, 10000);
        identity.reputation_score = @intCast(new_score);

        const level = identity.getReputationLevel();
        std.log.info("[identity] Reputation updated: {s} -> {d} ({s})", .{ did, identity.reputation_score, @tagName(level) });
    }

    /// 验证创作者
    pub fn verifyCreator(did: []const u8) !void {
        if (did.len == 0) return error.InvalidDID;
        
        var identity = identities.getPtr(did) orelse return error.IdentityNotFound;
        identity.verified = true;
        std.log.info("[identity] Creator verified: {s}", .{did});
    }
    
    /// 注销创作者
    pub fn unregisterCreator(did: []const u8) !void {
        const alloc = allocator orelse return error.NotInitialized;
        if (did.len == 0) return error.InvalidDID;
        
        const entry = identities.getEntry(did) orelse return error.IdentityNotFound;
        
        // Free the value's strings and the key
        entry.value_ptr.deinit(alloc);
        alloc.free(entry.key_ptr.*);
        
        _ = identities.remove(did);
        std.log.info("[identity] Creator unregistered: {s}", .{did});
    }
    
    /// 获取已注册创作者数量
    pub fn getCreatorCount() usize {
        return identities.count();
    }
};

test "Identity module basic operations" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();

    // 注册创作者
    try IdentityModule.registerCreator("did:mv:creator001", "Alice Meta", "0x1234567890abcdef");
    try std.testing.expectEqual(@as(usize, 1), IdentityModule.getCreatorCount());

    // 获取创作者
    const creator = IdentityModule.getCreator("did:mv:creator001").?;
    try std.testing.expectEqualStrings("Alice Meta", creator.display_name);
    try std.testing.expectEqual(false, creator.verified);
    try std.testing.expectEqual(.novice, creator.getReputationLevel());

    // 更新声誉
    try IdentityModule.updateReputation("did:mv:creator001", 2500);
    const updated = IdentityModule.getCreator("did:mv:creator001").?;
    try std.testing.expectEqual(@as(u32, 2500), updated.reputation_score);
    try std.testing.expectEqual(.rising, updated.getReputationLevel());

    // 验证
    try IdentityModule.verifyCreator("did:mv:creator001");
    const verified = IdentityModule.getCreator("did:mv:creator001").?;
    try std.testing.expect(verified.verified);
    
    // 注销
    try IdentityModule.unregisterCreator("did:mv:creator001");
    try std.testing.expectEqual(@as(usize, 0), IdentityModule.getCreatorCount());
    try std.testing.expect(IdentityModule.getCreator("did:mv:creator001") == null);
}

test "Identity module validation" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();
    
    // 空 DID 应该失败
    try std.testing.expectError(error.InvalidDID, IdentityModule.registerCreator("", "Alice", "0x1234"));
    
    // 空名字应该失败
    try std.testing.expectError(error.InvalidName, IdentityModule.registerCreator("did:1", "", "0x1234"));
    
    // 重复注册应该失败
    try IdentityModule.registerCreator("did:mv:dup", "Alice", "0x1234");
    try std.testing.expectError(error.DuplicateDID, IdentityModule.registerCreator("did:mv:dup", "Bob", "0x5678"));
    
    // 不存在的 DID
    try std.testing.expectError(error.IdentityNotFound, IdentityModule.updateReputation("did:mv:nonexistent", 100));
}

test "Identity module reputation clamping" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();
    
    try IdentityModule.registerCreator("did:mv:rep", "Test", "0x1234");
    
    // 声誉上限 10000
    try IdentityModule.updateReputation("did:mv:rep", 15000);
    const creator = IdentityModule.getCreator("did:mv:rep").?;
    try std.testing.expectEqual(@as(u32, 10000), creator.reputation_score);
    try std.testing.expectEqual(.legend, creator.getReputationLevel());
    
    // 声誉下限 0
    try IdentityModule.updateReputation("did:mv:rep", -20000);
    const creator2 = IdentityModule.getCreator("did:mv:rep").?;
    try std.testing.expectEqual(@as(u32, 0), creator2.reputation_score);
    try std.testing.expectEqual(.novice, creator2.getReputationLevel());
}
