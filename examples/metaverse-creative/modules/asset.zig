const std = @import("std");
const zigmodu = @import("zigmodu");
const IdentityModule = @import("identity.zig").IdentityModule;

/// ============================================
/// Asset Module - 创意资产管理
/// 管理 3D 模型、场景、头像等创意资产的铸造、组合和授权
/// ============================================
pub const AssetModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "asset",
        .description = "Creative asset management (3D models, scenes, avatars)",
        .dependencies = &.{ "identity", "storage" },
    };

    var assets: std.StringHashMap(CreativeAsset) = undefined;
    var asset_counter: u64 = 0;
    var allocator: std.mem.Allocator = undefined;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        assets = std.StringHashMap(CreativeAsset).init(allocator);
        std.log.info("[asset] Asset module initialized", .{});
    }

    pub fn deinit() void {
        var iter = assets.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.metadata.name);
            allocator.free(entry.value_ptr.metadata.description);
            allocator.free(entry.value_ptr.creator_did);
        }
        assets.deinit();
        std.log.info("[asset] Asset module cleaned up", .{});
    }

    /// 资产类型
    pub const AssetType = enum {
        model_3d, // 3D 模型
        scene, // 虚拟场景
        avatar, // 虚拟化身
        texture, // 纹理贴图
        audio, // 音频
        interaction, // 交互逻辑
        composition, // 组合资产

        pub fn getDisplayName(self: AssetType) []const u8 {
            return switch (self) {
                .model_3d => "3D Model",
                .scene => "Scene",
                .avatar => "Avatar",
                .texture => "Texture",
                .audio => "Audio",
                .interaction => "Interaction",
                .composition => "Composition",
            };
        }
    };

    /// 创意资产
    pub const CreativeAsset = struct {
        id: u64,
        asset_type: AssetType,
        metadata: AssetMetadata,
        creator_did: []const u8,
        created_at: i64,
        minted: bool = false,
        token_id: ?[]const u8 = null,
        price: u64 = 0,
        royalty_percent: u8 = 10, // 默认 10% 版税
        components: std.ArrayList(u64), // 组合资产的子组件

        /// 计算稀有度分数
        pub fn calculateRarity(self: CreativeAsset) u32 {
            var score: u32 = 0;

            score += @as(u32, @intCast(self.components.items.len)) * 10;

            // 基于创作者声誉
            if (IdentityModule.getCreator(self.creator_did)) |creator| {
                score += @intCast(creator.reputation_score / 100);
            }

            return score;
        }
    };

    pub const AssetMetadata = struct {
        name: []const u8,
        description: []const u8,
        tags: std.ArrayList([]const u8),
        file_hash: []const u8,
        file_size: u64,
        dimensions: ?[3]f32, // 3D 尺寸 [x, y, z]

        pub fn deinit(self: *AssetMetadata, alloc: std.mem.Allocator) void {
            alloc.free(self.name);
            alloc.free(self.description);
            for (self.tags.items) |tag| {
                alloc.free(tag);
            }
            self.tags.deinit();
        }
    };

    /// 铸造新资产
    pub fn mintAsset(
        creator_did: []const u8,
        asset_type: AssetType,
        name: []const u8,
        description: []const u8,
        file_hash: []const u8,
        file_size: u64,
    ) !u64 {
        // 验证创作者存在
        if (IdentityModule.getCreator(creator_did) == null) {
            return error.CreatorNotFound;
        }

        asset_counter += 1;
        const asset_id = asset_counter;

        const name_copy = try allocator.dupe(u8, name);
        const desc_copy = try allocator.dupe(u8, description);
        const did_copy = try allocator.dupe(u8, creator_did);

        const asset = CreativeAsset{
            .id = asset_id,
            .asset_type = asset_type,
            .metadata = .{
                .name = name_copy,
                .description = desc_copy,
                .tags = std.ArrayList([]const u8).init(allocator),
                .file_hash = file_hash,
                .file_size = file_size,
                .dimensions = null,
            },
            .creator_did = did_copy,
            .created_at = std.time.timestamp(),
            .minted = true,
            .components = std.ArrayList(u64).init(allocator),
        };

        try assets.put(file_hash, asset);

        std.log.info("[asset] Asset minted: {s} (ID: {d}, Type: {s})", .{ name, asset_id, asset_type.getDisplayName() });

        return asset_id;
    }

    /// 组合资产 - 将多个资产组合成新资产
    pub fn composeAssets(
        creator_did: []const u8,
        name: []const u8,
        description: []const u8,
        component_ids: []const u64,
    ) !u64 {
        if (component_ids.len < 2) {
            return error.InsufficientComponents;
        }

        // 验证所有组件存在
        for (component_ids) |id| {
            var found = false;
            var iter = assets.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.id == id) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.ComponentNotFound;
        }

        // 计算组合资产的文件哈希（简化）
        var hash_buf: [64]u8 = undefined;
        const hash = try std.fmt.bufPrint(&hash_buf, "composed_{d}", .{asset_counter + 1});

        const asset_id = try mintAsset(
            creator_did,
            .composition,
            name,
            description,
            hash,
            0, // 组合资产没有独立文件大小
        );

        // 添加组件引用
        var asset = assets.getPtr(hash).?;
        for (component_ids) |id| {
            try asset.components.append(id);
        }

        // 计算并设置价格（组件价格之和 + 创作溢价）
        var total_price: u64 = 0;
        for (component_ids) |id| {
            var iter = assets.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.id == id) {
                    total_price += entry.value_ptr.price;
                }
            }
        }
        asset.price = total_price + total_price / 5; // 20% 创作溢价

        std.log.info("[asset] Composition created: {s} with {d} components, price: {d}", .{ name, component_ids.len, asset.price });

        return asset_id;
    }

    /// 获取资产
    pub fn getAsset(file_hash: []const u8) ?CreativeAsset {
        return assets.get(file_hash);
    }

    /// 设置资产价格
    pub fn setAssetPrice(file_hash: []const u8, price: u64) !void {
        var asset = assets.getPtr(file_hash) orelse return error.AssetNotFound;
        asset.price = price;
        std.log.info("[asset] Price updated: {s} -> {d} tokens", .{ asset.metadata.name, price });
    }

    /// 列出创作者的所有资产
    pub fn listCreatorAssets(creator_did: []const u8, buf: []CreativeAsset) []CreativeAsset {
        var count: usize = 0;
        var iter = assets.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.creator_did, creator_did) and count < buf.len) {
                buf[count] = entry.value_ptr.*;
                count += 1;
            }
        }
        return buf[0..count];
    }
};

test "Asset module" {
    try IdentityModule.init();
    defer IdentityModule.deinit();

    try AssetModule.init();
    defer AssetModule.deinit();

    // 注册创作者
    try IdentityModule.registerCreator("did:mv:creator001", "Alice", "0x1234");

    // 铸造单个资产
    const asset_id = try AssetModule.mintAsset(
        "did:mv:creator001",
        .model_3d,
        "Cyberpunk Building",
        "A futuristic building model",
        "hash123",
        1024000,
    );

    try std.testing.expectEqual(@as(u64, 1), asset_id);

    // 铸造更多资产用于组合
    const asset2 = try AssetModule.mintAsset(
        "did:mv:creator001",
        .texture,
        "Neon Texture",
        "Glowing neon texture",
        "hash456",
        512000,
    );

    // 设置价格
    try AssetModule.setAssetPrice("hash123", 1000);
    try AssetModule.setAssetPrice("hash456", 500);

    // 组合资产
    const components = [_]u64{ asset_id, asset2 };
    const composed_id = try AssetModule.composeAssets(
        "did:mv:creator001",
        "Cyberpunk Scene",
        "Complete cyberpunk environment",
        &components,
    );

    try std.testing.expectEqual(@as(u64, 3), composed_id);
}
