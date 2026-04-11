const std = @import("std");
const zigmodu = @import("zigmodu");
const IdentityModule = @import("identity.zig").IdentityModule;
const AssetModule = @import("asset.zig").AssetModule;

/// ============================================
/// World Module - 虚拟世界渲染与场景管理
/// 管理虚拟世界的创建、渲染和经济系统
/// ============================================

pub const WorldModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "world",
        .description = "Virtual world rendering and scene management",
        .dependencies = &.{"identity", "asset"},
    };
    
    var worlds: std.StringHashMap(VirtualWorld) = undefined;
    var world_counter: u64 = 0;
    var allocator: std.mem.Allocator = undefined;
    
    pub fn init() !void {
        allocator = std.heap.page_allocator;
        worlds = std.StringHashMap(VirtualWorld).init(allocator);
        std.log.info("[world] World module initialized", .{});
    }
    
    pub fn deinit() void {
        worlds.deinit();
        std.log.info("[world] World module cleaned up", .{});
    }
    
    /// 虚拟世界
    pub const VirtualWorld = struct {
        id: u64,
        name: []const u8,
        owner_did: []const u8,
        scenes: std.ArrayList(Scene),
        economy: WorldEconomy,
        visitor_count: u64 = 0,
        total_revenue: u64 = 0,
        created_at: i64,
        
        /// 计算世界价值
        pub fn calculateValue(self: VirtualWorld) u64 {
            // 基于场景复杂度 + 访问量 + 收入
            var value: u64 = 0;
            
            for (self.scenes.items) |scene| {
                value += scene.calculateValue();
            }
            
            value += self.visitor_count * 10;
            value += self.total_revenue;
            
            return value;
        }
    };
    
    /// 场景
    pub const Scene = struct {
        id: u64,
        name: []const u8,
        assets: std.ArrayList(SceneAsset),
        position: [3]f32,  // 世界中的位置
        scale: f32 = 1.0,
        
        const SceneAsset = struct {
            asset_hash: []const u8,
            transform: Transform,
            interactive: bool = false,
        };
        
        const Transform = struct {
            position: [3]f32,
            rotation: [3]f32,
            scale: [3]f32,
        };
        
        pub fn calculateValue(self: Scene) u64 {
            var value: u64 = 0;
            for (self.assets.items) |scene_asset| {
                if (AssetModule.getAsset(scene_asset.asset_hash)) |asset| {
                    value += asset.price;
                }
            }
            return value;
        }
    };
    
    /// 世界经济
    pub const WorldEconomy = struct {
        token_name: []const u8,
        token_symbol: []const u8,
        total_supply: u64,
        entry_fee: u64 = 0,      // 入场费
        transaction_fee: u8 = 2, // 交易手续费 %
        creator_royalty: u8 = 5, // 创作者版税 %
        
        pub fn calculateEntryFee(self: WorldEconomy, visitor_reputation: u32) u64 {
            // 声誉越高，入场费折扣越多
            const discount = @min(visitor_reputation / 1000, 50); // 最高 50% 折扣
            return self.entry_fee * (100 - discount) / 100;
        }
    };
    
    /// 创建虚拟世界
    pub fn createWorld(
        owner_did: []const u8,
        name: []const u8,
        token_name: []const u8,
        token_symbol: []const u8,
    ) !u64 {
        // 验证所有者
        if (IdentityModule.getCreator(owner_did) == null) {
            return error.OwnerNotFound;
        }
        
        world_counter += 1;
        const world_id = world_counter;
        
        const name_copy = try allocator.dupe(u8, name);
        const owner_copy = try allocator.dupe(u8, owner_did);
        const token_name_copy = try allocator.dupe(u8, token_name);
        const token_symbol_copy = try allocator.dupe(u8, token_symbol);
        
        const world = VirtualWorld{
            .id = world_id,
            .name = name_copy,
            .owner_did = owner_copy,
            .scenes = std.ArrayList(Scene).init(allocator),
            .economy = .{
                .token_name = token_name_copy,
                .token_symbol = token_symbol_copy,
                .total_supply = 1000000000, // 10亿代币
            },
            .created_at = std.time.timestamp(),
        };
        
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});
        try worlds.put(key, world);
        
        std.log.info("[world] Virtual world created: {s} (ID: {d})", .{ name, world_id });
        
        return world_id;
    }
    
    /// 添加场景到世界
    pub fn addScene(world_id: u64, name: []const u8, position: [3]f32) !void {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});
        
        var world = worlds.getPtr(key) orelse return error.WorldNotFound;
        
        const scene = Scene{
            .id = world.scenes.items.len + 1,
            .name = try allocator.dupe(u8, name),
            .assets = std.ArrayList(Scene.SceneAsset).init(allocator),
            .position = position,
        };
        
        try world.scenes.append(scene);
        
        std.log.info("[world] Scene added: {s} to world {d} at position [{d:.2}, {d:.2}, {d:.2}]", .{
            name, world_id, position[0], position[1], position[2]
        });
    }
    
    /// 渲染场景描述（文本渲染示例）
    pub fn renderScene(world_id: u64, scene_id: u64, writer: anytype) !void {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});
        
        const world = worlds.get(key) orelse return error.WorldNotFound;
        
        if (scene_id > world.scenes.items.len) return error.SceneNotFound;
        const scene = world.scenes.items[scene_id - 1];
        
        try writer.print(
            \\n            ╔═══════════════════════════════════════════════════════════╗
            ║  METAVERSE SCENE RENDER                                  ║
            ╠═══════════════════════════════════════════════════════════╣
            ║  World: {s:<45} ║
            ║  Scene: {s:<45} ║
            ║  Position: [{d:>6.2}, {d:>6.2}, {d:>6.2}]                 ║
            ╠═══════════════════════════════════════════════════════════╣
            ║  ASSETS:                                                  ║
        , .{
            world.name,
            scene.name,
            scene.position[0],
            scene.position[1],
            scene.position[2],
        });
        
        if (scene.assets.items.len == 0) {
            try writer.print("║    (Empty scene - no assets placed yet)                  ║\n", .{});
        } else {
            for (scene.assets.items) |scene_asset| {
                if (AssetModule.getAsset(scene_asset.asset_hash)) |asset| {
                    try writer.print("║    • {s:<30} [{s}]         ║\n", .{
                        asset.metadata.name,
                        if (scene_asset.interactive) "Interactive" else "Static",
                    });
                }
            }
        }
        
        try writer.print(
            \\╠═══════════════════════════════════════════════════════════╣
            ║  Scene Value: {d:>10} tokens                             ║
            ╚═══════════════════════════════════════════════════════════╝
            \
        , .{scene.calculateValue()});
    }
    
    /// 访问世界
    pub fn visitWorld(world_id: u64, visitor_did: []const u8) !u64 {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});
        
        var world = worlds.getPtr(key) orelse return error.WorldNotFound;
        
        // 获取访问者声誉计算折扣
        var reputation: u32 = 0;
        if (IdentityModule.getCreator(visitor_did)) |visitor| {
            reputation = visitor.reputation_score;
        }
        
        const fee = world.economy.calculateEntryFee(reputation);
        world.visitor_count += 1;
        world.total_revenue += fee;
        
        std.log.info("[world] Visitor {s} entered world {d}, paid {d} tokens", .{
            visitor_did, world_id, fee
        });
        
        return fee;
    }
    
    /// 获取世界统计
    pub fn getWorldStats(world_id: u64) !struct { visitors: u64, revenue: u64, value: u64 } {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});
        
        const world = worlds.get(key) orelse return error.WorldNotFound;
        
        return .{
            .visitors = world.visitor_count,
            .revenue = world.total_revenue,
            .value = world.calculateValue(),
        };
    }
};

test "World module" {
    try IdentityModule.init();
    defer IdentityModule.deinit();
    
    try AssetModule.init();
    defer AssetModule.deinit();
    
    try WorldModule.init();
    defer WorldModule.deinit();
    
    // 注册创作者
    try IdentityModule.registerCreator("did:mv:world_owner", "World Builder", "0x5678");
    
    // 创建虚拟世界
    const world_id = try WorldModule.createWorld(
        "did:mv:world_owner",
        "Cyberpunk City 2077",
        "Neon Coin",
        "NEON",
    );
    
    try std.testing.expectEqual(@as(u64, 1), world_id);
    
    // 添加场景
    try WorldModule.addScene(world_id, "Neon Street", .{ 0.0, 0.0, 0.0 });
    try WorldModule.addScene(world_id, "Sky Lounge", .{ 100.0, 50.0, 0.0 });
    
    // 访问世界
    const fee = try WorldModule.visitWorld(world_id, "did:mv:visitor001");
    try std.testing.expectEqual(@as(u64, 0), fee); // 无入场费
    
    // 获取统计
    const stats = try WorldModule.getWorldStats(world_id);
    try std.testing.expectEqual(@as(u64, 1), stats.visitors);
}