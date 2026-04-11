const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Identity Module - 去中心化身份管理
/// 管理创作者的 DID、声誉和权限
/// ============================================
pub const IdentityModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "identity",
        .description = "Decentralized identity and reputation management",
        .dependencies = &.{"storage"},
    };

    var identities: std.StringHashMap(CreatorIdentity) = undefined;
    var allocator: std.mem.Allocator = undefined;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        identities = std.StringHashMap(CreatorIdentity).init(allocator);
        std.log.info("[identity] Identity module initialized", .{});
    }

    pub fn deinit() void {
        identities.deinit();
        std.log.info("[identity] Identity module cleaned up", .{});
    }

    /// 创作者身份
    pub const CreatorIdentity = struct {
        did: []const u8, // 去中心化身份标识
        display_name: []const u8,
        wallet_address: []const u8,
        reputation_score: u32 = 0, // 声誉分数 (0-10000)
        created_at: i64,
        verified: bool = false,

        pub fn getReputationLevel(self: CreatorIdentity) ReputationLevel {
            return if (self.reputation_score >= 8000) .legend else if (self.reputation_score >= 6000) .expert else if (self.reputation_score >= 4000) .established else if (self.reputation_score >= 2000) .rising else .novice;
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
        const identity = CreatorIdentity{
            .did = did,
            .display_name = name,
            .wallet_address = wallet,
            .created_at = std.time.timestamp(),
        };

        try identities.put(did, identity);

        // 发布身份创建事件
        std.log.info("[identity] Creator registered: {s} ({s})", .{ name, did });
    }

    /// 获取创作者信息
    pub fn getCreator(did: []const u8) ?CreatorIdentity {
        return identities.get(did);
    }

    /// 更新声誉分数
    pub fn updateReputation(did: []const u8, delta: i32) !void {
        var identity = identities.getPtr(did) orelse return error.IdentityNotFound;

        const current: i64 = @intCast(identity.reputation_score);
        const new_score = std.math.clamp(current + delta, 0, 10000);
        identity.reputation_score = @intCast(new_score);

        const level = identity.getReputationLevel();
        std.log.info("[identity] Reputation updated: {s} -> {d} ({s})", .{ did, identity.reputation_score, @tagName(level) });
    }

    /// 验证创作者
    pub fn verifyCreator(did: []const u8) !void {
        var identity = identities.getPtr(did) orelse return error.IdentityNotFound;
        identity.verified = true;
        std.log.info("[identity] Creator verified: {s}", .{did});
    }
};

test "Identity module" {
    try IdentityModule.init();
    defer IdentityModule.deinit();

    // 注册创作者
    try IdentityModule.registerCreator("did:mv:creator001", "Alice Meta", "0x1234567890abcdef");

    // 获取创作者
    const creator = IdentityModule.getCreator("did:mv:creator001").?;
    try std.testing.expectEqualStrings("Alice Meta", creator.display_name);
    try std.testing.expectEqual(false, creator.verified);

    // 更新声誉
    try IdentityModule.updateReputation("did:mv:creator001", 2500);
    const updated = IdentityModule.getCreator("did:mv:creator001").?;
    try std.testing.expectEqual(@as(u32, 2500), updated.reputation_score);
    try std.testing.expectEqual(.rising, updated.getReputationLevel());

    // 验证
    try IdentityModule.verifyCreator("did:mv:creator001");
    const verified = IdentityModule.getCreator("did:mv:creator001").?;
    try std.testing.expect(verified.verified);
}
