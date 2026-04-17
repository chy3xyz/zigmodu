const std = @import("std");
const zigmodu = @import("zigmodu");
const IdentityModule = @import("identity.zig").IdentityModule;
const AssetModule = @import("asset.zig").AssetModule;
const ArrayList = std.array_list.Managed;

/// ============================================
/// World Module - 虚拟世界渲染与场景管理
/// 管理虚拟世界的创建、渲染和经济系统
/// ============================================
/// NOTE: This module uses global state and is NOT thread-safe.
pub const WorldModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "world",
        .description = "Virtual world rendering and scene management",
        .dependencies = &.{ "identity", "asset" },
    };

    var worlds: std.StringHashMap(VirtualWorld) = undefined;
    var world_counter: u64 = 0;
    var allocator: ?std.mem.Allocator = null;

    pub fn init() !void {
        try initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(alloc: std.mem.Allocator) !void {
        if (allocator != null) return error.AlreadyInitialized;
        
        allocator = alloc;
        worlds = std.StringHashMap(VirtualWorld).init(alloc);
        std.log.info("[world] World module initialized", .{});
    }

    pub fn deinit() void {
        const alloc = allocator orelse return;
        
        var iter = worlds.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        worlds.deinit();
        allocator = null;
        
        std.log.info("[world] World module cleaned up", .{});
    }

    pub const VirtualWorld = struct {
        id: u64,
        name: []const u8,
        owner_did: []const u8,
        scenes: ArrayList(Scene),
        economy: WorldEconomy,
        visitor_count: u64 = 0,
        total_revenue: u64 = 0,
        created_at: i64,

        pub fn deinit(self: *VirtualWorld, alloc: std.mem.Allocator) void {
            alloc.free(self.name);
            alloc.free(self.owner_did);
            self.economy.deinit(alloc);
            for (self.scenes.items) |*scene| {
                scene.deinit(alloc);
            }
            self.scenes.deinit();
        }

        pub fn calculateValue(self: VirtualWorld) u64 {
            var value: u64 = 0;
            for (self.scenes.items) |scene| {
                value = std.math.add(u64, value, scene.calculateValue()) catch return std.math.maxInt(u64);
            }
            value = std.math.add(u64, value, self.visitor_count * 10) catch return std.math.maxInt(u64);
            value = std.math.add(u64, value, self.total_revenue) catch return std.math.maxInt(u64);
            return value;
        }
    };

    pub const Scene = struct {
        id: u64,
        name: []const u8,
        assets: ArrayList(SceneAsset),
        position: [3]f32,
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

        pub fn deinit(self: *Scene, alloc: std.mem.Allocator) void {
            alloc.free(self.name);
            for (self.assets.items) |asset| {
                alloc.free(asset.asset_hash);
            }
            self.assets.deinit();
        }

        pub fn calculateValue(self: Scene) u64 {
            var value: u64 = 0;
            for (self.assets.items) |scene_asset| {
                if (AssetModule.getAsset(scene_asset.asset_hash)) |asset| {
                    value = std.math.add(u64, value, asset.price) catch return std.math.maxInt(u64);
                }
            }
            return value;
        }
    };

    pub const WorldEconomy = struct {
        token_name: []const u8,
        token_symbol: []const u8,
        total_supply: u64,
        entry_fee: u64 = 0,
        transaction_fee: u8 = 2,
        creator_royalty: u8 = 5,

        pub fn deinit(self: *WorldEconomy, alloc: std.mem.Allocator) void {
            alloc.free(self.token_name);
            alloc.free(self.token_symbol);
        }

        pub fn calculateEntryFee(self: WorldEconomy, visitor_reputation: u32) u64 {
            const discount: u64 = @min(visitor_reputation / 1000, 50);
            // Use checked multiplication to prevent overflow
            const multiplier = std.math.sub(u64, 100, discount) catch return 0;
            const result = std.math.mul(u64, self.entry_fee, multiplier) catch return std.math.maxInt(u64);
            return result / 100;
        }
    };

    pub fn createWorld(
        owner_did: []const u8,
        name: []const u8,
        token_name: []const u8,
        token_symbol: []const u8,
    ) !u64 {
        const alloc = allocator orelse return error.NotInitialized;
        
        if (name.len == 0 or name.len > 256) return error.InvalidName;
        if (token_symbol.len == 0 or token_symbol.len > 10) return error.InvalidTokenSymbol;
        if (IdentityModule.getCreator(owner_did) == null) return error.OwnerNotFound;

        world_counter += 1;
        const world_id = world_counter;

        var key_buf: [32]u8 = undefined;
        const key_str = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});
        const key_copy = try alloc.dupe(u8, key_str);
        errdefer alloc.free(key_copy);

        const name_copy = try alloc.dupe(u8, name);
        errdefer alloc.free(name_copy);
        
        const owner_copy = try alloc.dupe(u8, owner_did);
        errdefer alloc.free(owner_copy);
        
        const token_name_copy = try alloc.dupe(u8, token_name);
        errdefer alloc.free(token_name_copy);
        
        const token_symbol_copy = try alloc.dupe(u8, token_symbol);
        errdefer alloc.free(token_symbol_copy);

        const world = VirtualWorld{
            .id = world_id,
            .name = name_copy,
            .owner_did = owner_copy,
            .scenes = ArrayList(Scene).init(alloc),
            .economy = .{
                .token_name = token_name_copy,
                .token_symbol = token_symbol_copy,
                .total_supply = 1000000000,
            },
            .created_at = 0,
        };

        try worlds.put(key_copy, world);

        std.log.info("[world] Virtual world created: {s} (ID: {d})", .{ name, world_id });

        return world_id;
    }

    pub fn deleteWorld(world_id: u64) !void {
        const alloc = allocator orelse return error.NotInitialized;
        
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});
        
        const entry = worlds.getEntry(key) orelse return error.WorldNotFound;
        entry.value_ptr.deinit(alloc);
        alloc.free(entry.key_ptr.*);
        _ = worlds.remove(key);
        
        std.log.info("[world] Virtual world deleted: {d}", .{world_id});
    }

    pub fn addScene(world_id: u64, name: []const u8, position: [3]f32) !void {
        const alloc = allocator orelse return error.NotInitialized;
        
        if (name.len == 0 or name.len > 256) return error.InvalidName;
        
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});

        var world = worlds.getPtr(key) orelse return error.WorldNotFound;

        const name_copy = try alloc.dupe(u8, name);
        errdefer alloc.free(name_copy);

        const scene = Scene{
            .id = world.scenes.items.len + 1,
            .name = name_copy,
            .assets = ArrayList(Scene.SceneAsset).init(alloc),
            .position = position,
        };

        try world.scenes.append(scene);

        std.log.info("[world] Scene added: {s} to world {d} at position [{d:.2}, {d:.2}, {d:.2}]", .{ name, world_id, position[0], position[1], position[2] });
    }

    pub fn removeScene(world_id: u64, scene_id: u64) !void {
        const alloc = allocator orelse return error.NotInitialized;
        
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});
        
        var world = worlds.getPtr(key) orelse return error.WorldNotFound;
        if (scene_id == 0 or scene_id > world.scenes.items.len) return error.SceneNotFound;
        
        const index = scene_id - 1;
        world.scenes.items[index].deinit(alloc);
        _ = world.scenes.orderedRemove(index);
        
        // Re-number remaining scenes
        for (world.scenes.items[index..], 0..) |*scene, i| {
            scene.id = index + 1 + i;
        }
        
        std.log.info("[world] Scene removed: {d} from world {d}", .{ scene_id, world_id });
    }

    pub fn renderScene(alloc: std.mem.Allocator, world_id: u64, scene_id: u64) ![]const u8 {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});

        const world = worlds.get(key) orelse return error.WorldNotFound;

        if (scene_id == 0 or scene_id > world.scenes.items.len) return error.SceneNotFound;
        const scene = world.scenes.items[scene_id - 1];

        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        errdefer buf.deinit(alloc);

        try buf.print(alloc,
            \\n            ╔═══════════════════════════════════════════════════════════╗
            \\║  METAVERSE SCENE RENDER                                  ║
            \\╠═══════════════════════════════════════════════════════════╣
            \\║  World: {s:<45}                          ║
            \\║  Scene: {s:<45}                          ║
            \\║  Position: [{d:>6.2}, {d:>6.2}, {d:>6.2}]                 ║
            \\╠═══════════════════════════════════════════════════════════╣
            \\║  ASSETS:                                                  ║
        , .{
            world.name,
            scene.name,
            scene.position[0],
            scene.position[1],
            scene.position[2],
        });

        if (scene.assets.items.len == 0) {
            try buf.print(alloc, "║    (Empty scene - no assets placed yet)                  ║\n", .{});
        } else {
            for (scene.assets.items) |scene_asset| {
                if (AssetModule.getAsset(scene_asset.asset_hash)) |asset| {
                    try buf.print(alloc, "║    • {s:<30} [{s}]         ║\n", .{
                        asset.metadata.name,
                        if (scene_asset.interactive) "Interactive" else "Static",
                    });
                }
            }
        }

        try buf.print(alloc,
            \\╠═══════════════════════════════════════════════════════════╣
            \\║  Scene Value: {d:>10} tokens                             ║
            \\╚═══════════════════════════════════════════════════════════╝
        , .{scene.calculateValue()});

        return buf.toOwnedSlice(alloc);
    }

    pub fn visitWorld(world_id: u64, visitor_did: []const u8) !u64 {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{world_id});

        var world = worlds.getPtr(key) orelse return error.WorldNotFound;

        var reputation: u32 = 0;
        if (IdentityModule.getCreator(visitor_did)) |visitor| {
            reputation = visitor.reputation_score;
        } else {
            return error.VisitorNotFound;
        }

        const fee = world.economy.calculateEntryFee(reputation);
        world.visitor_count = std.math.add(u64, world.visitor_count, 1) catch return error.Overflow;
        world.total_revenue = std.math.add(u64, world.total_revenue, fee) catch return error.Overflow;

        std.log.info("[world] Visitor {s} entered world {d}, paid {d} tokens", .{ visitor_did, world_id, fee });

        return fee;
    }

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
    
    pub fn getWorldCount() usize {
        return worlds.count();
    }
};

test "World module basic operations" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();

    try AssetModule.initWithAllocator(allocator);
    defer AssetModule.deinit();

    try WorldModule.initWithAllocator(allocator);
    defer WorldModule.deinit();

    try IdentityModule.registerCreator("did:mv:world_owner", "World Builder", "0x5678");

    const world_id = try WorldModule.createWorld(
        "did:mv:world_owner",
        "Cyberpunk City 2077",
        "Neon Coin",
        "NEON",
    );
    try std.testing.expectEqual(@as(u64, 1), world_id);
    try std.testing.expectEqual(@as(usize, 1), WorldModule.getWorldCount());

    // Add multiple scenes (this was the crash bug with stack keys)
    try WorldModule.addScene(world_id, "Neon Street", .{ 0.0, 0.0, 0.0 });
    try WorldModule.addScene(world_id, "Sky Lounge", .{ 100.0, 50.0, 0.0 });
    try std.testing.expectEqual(@as(usize, 2), WorldModule.getWorldCount());

    // Visit
    try IdentityModule.registerCreator("did:mv:visitor001", "Visitor", "0x9999");
    const fee = try WorldModule.visitWorld(world_id, "did:mv:visitor001");
    try std.testing.expectEqual(@as(u64, 0), fee);

    // Stats
    const stats = try WorldModule.getWorldStats(world_id);
    try std.testing.expectEqual(@as(u64, 1), stats.visitors);
    
    // Remove scene
    try WorldModule.removeScene(world_id, 1);
    const stats2 = try WorldModule.getWorldStats(world_id);
    _ = stats2;
    
    // Delete world
    try WorldModule.deleteWorld(world_id);
    try std.testing.expectEqual(@as(usize, 0), WorldModule.getWorldCount());
}

test "World module validation" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();
    try AssetModule.initWithAllocator(allocator);
    defer AssetModule.deinit();
    try WorldModule.initWithAllocator(allocator);
    defer WorldModule.deinit();
    
    // Invalid owner
    try std.testing.expectError(error.OwnerNotFound, WorldModule.createWorld("did:none", "X", "Y", "Z"));
    
    // Empty name
    try std.testing.expectError(error.InvalidName, WorldModule.createWorld("did:mv:owner", "", "Y", "Z"));
    
    // Empty token symbol
    try std.testing.expectError(error.InvalidTokenSymbol, WorldModule.createWorld("did:mv:owner", "X", "Y", ""));
    
    // World not found
    try std.testing.expectError(error.WorldNotFound, WorldModule.addScene(999, "Scene", .{ 0, 0, 0 }));
    try std.testing.expectError(error.WorldNotFound, WorldModule.getWorldStats(999));
    
    // Scene not found
    try IdentityModule.registerCreator("did:mv:owner", "Owner", "0x1234");
    const wid = try WorldModule.createWorld("did:mv:owner", "Test", "Token", "TKN");
    try std.testing.expectError(error.SceneNotFound, WorldModule.removeScene(wid, 1));
}

test "World module calculateEntryFee overflow safety" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();
    try AssetModule.initWithAllocator(allocator);
    defer AssetModule.deinit();
    try WorldModule.initWithAllocator(allocator);
    defer WorldModule.deinit();
    
    try IdentityModule.registerCreator("did:mv:owner", "Owner", "0x1234");
    const wid = try WorldModule.createWorld("did:mv:owner", "Test", "Token", "TKN");
    
    // Set an extremely high entry fee that could overflow
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "{d}", .{wid});
    var world = WorldModule.worlds.getPtr(key).?;
    world.economy.entry_fee = std.math.maxInt(u64);
    
    // Should not panic, should return maxInt
    const fee = world.economy.calculateEntryFee(0);
    try std.testing.expectEqual(std.math.maxInt(u64), fee);
}
