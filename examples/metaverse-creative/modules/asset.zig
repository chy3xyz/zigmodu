const std = @import("std");
const zigmodu = @import("zigmodu");
const IdentityModule = @import("identity.zig").IdentityModule;
const ArrayList = std.array_list.Managed;

/// ============================================
/// Asset Module - 创意资产管理
/// 管理 3D 模型、场景、头像等创意资产的铸造、组合和授权
/// ============================================
/// NOTE: This module uses global state and is NOT thread-safe.
pub const AssetModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "asset",
        .description = "Creative asset management (3D models, scenes, avatars)",
        .dependencies = &.{ "identity"},
    };

    var assets: std.StringHashMap(CreativeAsset) = undefined;
    var assets_by_id: std.AutoHashMap(u64, []const u8) = undefined; // id -> file_hash index
    var asset_counter: u64 = 0;
    var allocator: ?std.mem.Allocator = null;

    pub fn init() !void {
        try initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(alloc: std.mem.Allocator) !void {
        if (allocator != null) return error.AlreadyInitialized;
        
        allocator = alloc;
        assets = std.StringHashMap(CreativeAsset).init(alloc);
        assets_by_id = std.AutoHashMap(u64, []const u8).init(alloc);
        std.log.info("[asset] Asset module initialized", .{});
    }

    pub fn deinit() void {
        const alloc = allocator orelse return;
        
        var iter = assets.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        assets.deinit();
        
        // assets_by_id values point to asset keys, already freed above
        assets_by_id.deinit();
        allocator = null;
        
        std.log.info("[asset] Asset module cleaned up", .{});
    }

    pub const AssetType = enum {
        model_3d,
        scene,
        avatar,
        texture,
        audio,
        interaction,
        composition,

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

    pub const CreativeAsset = struct {
        id: u64,
        asset_type: AssetType,
        metadata: AssetMetadata,
        creator_did: []const u8,
        created_at: i64,
        minted: bool = false,
        token_id: ?[]const u8 = null,
        price: u64 = 0,
        royalty_percent: u8 = 10,
        components: ArrayList(u64),

        pub fn deinit(self: *CreativeAsset, alloc: std.mem.Allocator) void {
            self.metadata.deinit(alloc);
            alloc.free(self.creator_did);
            if (self.token_id) |token| {
                alloc.free(token);
            }
            self.components.deinit();
        }

        pub fn calculateRarity(self: CreativeAsset) u32 {
            var score: u32 = @as(u32, @intCast(self.components.items.len)) * 10;
            if (IdentityModule.getCreator(self.creator_did)) |creator| {
                score += @intCast(creator.reputation_score / 100);
            }
            return score;
        }
    };

    pub const AssetMetadata = struct {
        name: []const u8,
        description: []const u8,
        tags: ArrayList([]const u8),
        file_hash: []const u8,
        file_size: u64,
        dimensions: ?[3]f32,

        pub fn deinit(self: *AssetMetadata, alloc: std.mem.Allocator) void {
            alloc.free(self.name);
            alloc.free(self.description);
            for (self.tags.items) |tag| {
                alloc.free(tag);
            }
            self.tags.deinit();
        }
    };

    pub fn mintAsset(
        creator_did: []const u8,
        asset_type: AssetType,
        name: []const u8,
        description: []const u8,
        file_hash: []const u8,
        file_size: u64,
    ) !u64 {
        const alloc = allocator orelse return error.NotInitialized;
        
        // Validation
        if (file_hash.len == 0 or file_hash.len > 256) return error.InvalidFileHash;
        if (name.len == 0 or name.len > 256) return error.InvalidName;
        if (assets.contains(file_hash)) return error.DuplicateAsset;
        if (IdentityModule.getCreator(creator_did) == null) return error.CreatorNotFound;

        asset_counter += 1;
        const asset_id = asset_counter;

        const hash_copy = try alloc.dupe(u8, file_hash);
        errdefer alloc.free(hash_copy);

        const name_copy = try alloc.dupe(u8, name);
        errdefer alloc.free(name_copy);

        const desc_copy = try alloc.dupe(u8, description);
        errdefer alloc.free(desc_copy);

        const did_copy = try alloc.dupe(u8, creator_did);
        errdefer alloc.free(did_copy);

        const asset = CreativeAsset{
            .id = asset_id,
            .asset_type = asset_type,
            .metadata = .{
                .name = name_copy,
                .description = desc_copy,
                .tags = ArrayList([]const u8).init(alloc),
                .file_hash = hash_copy,
                .file_size = file_size,
                .dimensions = null,
            },
            .creator_did = did_copy,
            .created_at = 0,
            .minted = true,
            .components = ArrayList(u64).init(alloc),
        };

        try assets.put(hash_copy, asset);
        
        // Update id index
        const hash_for_index = try alloc.dupe(u8, file_hash);
        errdefer alloc.free(hash_for_index);
        try assets_by_id.put(asset_id, hash_for_index);

        std.log.info("[asset] Asset minted: {s} (ID: {d}, Type: {s})", .{ name, asset_id, asset_type.getDisplayName() });

        return asset_id;
    }

    pub fn composeAssets(
        creator_did: []const u8,
        name: []const u8,
        description: []const u8,
        component_ids: []const u64,
    ) !u64 {
        const alloc = allocator orelse return error.NotInitialized;
        
        if (component_ids.len < 2) return error.InsufficientComponents;
        if (name.len == 0) return error.InvalidName;
        if (IdentityModule.getCreator(creator_did) == null) return error.CreatorNotFound;

        // Validate all components exist using O(1) index lookup
        for (component_ids) |id| {
            if (!assets_by_id.contains(id)) return error.ComponentNotFound;
        }

        // Generate hash for composed asset
        var hash_buf: [64]u8 = undefined;
        const hash = try std.fmt.bufPrint(&hash_buf, "composed_{d}", .{asset_counter + 1});
        const hash_copy = try alloc.dupe(u8, hash);
        errdefer alloc.free(hash_copy);

        // Calculate price from components using O(1) lookups
        var total_price: u64 = 0;
        for (component_ids) |id| {
            const component_hash = assets_by_id.get(id).?;
            const component = assets.get(component_hash).?;
            total_price = std.math.add(u64, total_price, component.price) catch return error.PriceOverflow;
        }

        const asset_id = try mintAsset(
            creator_did,
            .composition,
            name,
            description,
            hash_copy,
            0,
        );
        errdefer _ = removeAsset(asset_id) catch {};

        // Add component references
        var asset = assets.getPtr(hash_copy).?;
        for (component_ids) |id| {
            try asset.components.append(id);
        }

        // Set price with 20% markup, checking for overflow
        const markup = total_price / 5;
        asset.price = std.math.add(u64, total_price, markup) catch return error.PriceOverflow;

        std.log.info("[asset] Composition created: {s} with {d} components, price: {d}", .{ name, component_ids.len, asset.price });

        return asset_id;
    }

    pub fn getAssetById(id: u64) ?CreativeAsset {
        const hash = assets_by_id.get(id) orelse return null;
        return assets.get(hash);
    }

    pub fn getAsset(file_hash: []const u8) ?CreativeAsset {
        return assets.get(file_hash);
    }

    pub fn setAssetPrice(file_hash: []const u8, price: u64) !void {
        if (file_hash.len == 0) return error.InvalidFileHash;
        var asset = assets.getPtr(file_hash) orelse return error.AssetNotFound;
        asset.price = price;
        std.log.info("[asset] Price updated: {s} -> {d} tokens", .{ asset.metadata.name, price });
    }

    pub fn removeAsset(id: u64) !void {
        const alloc = allocator orelse return error.NotInitialized;
        
        const hash_entry = assets_by_id.getEntry(id) orelse return error.AssetNotFound;
        const hash = hash_entry.value_ptr.*;
        
        const asset_entry = assets.getEntry(hash) orelse return error.AssetNotFound;
        asset_entry.value_ptr.deinit(alloc);
        alloc.free(asset_entry.key_ptr.*);
        
        _ = assets.remove(hash);
        alloc.free(hash_entry.value_ptr.*);
        _ = assets_by_id.remove(id);
    }

    pub fn listCreatorAssets(creator_did: []const u8, out_buf: []CreativeAsset) []CreativeAsset {
        var count: usize = 0;
        var iter = assets.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.creator_did, creator_did) and count < out_buf.len) {
                out_buf[count] = entry.value_ptr.*;
                count += 1;
            }
        }
        return out_buf[0..count];
    }
    
    pub fn getAssetCount() usize {
        return assets.count();
    }
};

test "Asset module basic operations" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();
    
    try AssetModule.initWithAllocator(allocator);
    defer AssetModule.deinit();

    try IdentityModule.registerCreator("did:mv:creator001", "Alice", "0x1234");

    const asset_id = try AssetModule.mintAsset(
        "did:mv:creator001",
        .model_3d,
        "Cyberpunk Building",
        "A futuristic building model",
        "hash123",
        1024000,
    );
    try std.testing.expectEqual(@as(u64, 1), asset_id);
    try std.testing.expectEqual(@as(usize, 1), AssetModule.getAssetCount());

    // Lookup by ID
    const asset = AssetModule.getAssetById(asset_id).?;
    try std.testing.expectEqualStrings("Cyberpunk Building", asset.metadata.name);

    // Set price
    try AssetModule.setAssetPrice("hash123", 1000);
    const updated = AssetModule.getAsset("hash123").?;
    try std.testing.expectEqual(@as(u64, 1000), updated.price);

    // Composition
    const asset2 = try AssetModule.mintAsset(
        "did:mv:creator001",
        .texture,
        "Neon Texture",
        "Glowing neon texture",
        "hash456",
        512000,
    );
    try AssetModule.setAssetPrice("hash456", 500);

    const components = [_]u64{ asset_id, asset2 };
    const composed_id = try AssetModule.composeAssets(
        "did:mv:creator001",
        "Cyberpunk Scene",
        "Complete cyberpunk environment",
        &components,
    );
    try std.testing.expectEqual(@as(u64, 3), composed_id);
    
    // Verify composed price: (1000 + 500) * 1.2 = 1800
    const composed = AssetModule.getAssetById(composed_id).?;
    try std.testing.expectEqual(@as(u64, 1800), composed.price);
    
    // Remove asset
    try AssetModule.removeAsset(asset_id);
    try std.testing.expectEqual(@as(usize, 2), AssetModule.getAssetCount());
    try std.testing.expect(AssetModule.getAssetById(asset_id) == null);
}

test "Asset module validation" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();
    
    try AssetModule.initWithAllocator(allocator);
    defer AssetModule.deinit();
    
    try IdentityModule.registerCreator("did:mv:creator001", "Alice", "0x1234");
    
    // Duplicate asset
    _ = try AssetModule.mintAsset("did:mv:creator001", .model_3d, "A", "B", "dup", 100);
    try std.testing.expectError(error.DuplicateAsset, AssetModule.mintAsset("did:mv:creator001", .model_3d, "C", "D", "dup", 100));
    
    // Invalid creator
    try std.testing.expectError(error.CreatorNotFound, AssetModule.mintAsset("did:mv:none", .model_3d, "A", "B", "hash2", 100));
    
    // Empty hash
    try std.testing.expectError(error.InvalidFileHash, AssetModule.mintAsset("did:mv:creator001", .model_3d, "A", "B", "", 100));
    
    // Component not found
    try std.testing.expectError(error.ComponentNotFound, AssetModule.composeAssets("did:mv:creator001", "X", "Y", &[_]u64{999, 998}));
    
    // Insufficient components
    try std.testing.expectError(error.InsufficientComponents, AssetModule.composeAssets("did:mv:creator001", "X", "Y", &[_]u64{1}));
}

test "Asset module listCreatorAssets" {
    const allocator = std.testing.allocator;
    
    try IdentityModule.initWithAllocator(allocator);
    defer IdentityModule.deinit();
    
    try AssetModule.initWithAllocator(allocator);
    defer AssetModule.deinit();
    
    try IdentityModule.registerCreator("did:mv:alice", "Alice", "0x1234");
    try IdentityModule.registerCreator("did:mv:bob", "Bob", "0x5678");
    
    _ = try AssetModule.mintAsset("did:mv:alice", .model_3d, "A1", "D1", "h1", 100);
    _ = try AssetModule.mintAsset("did:mv:alice", .texture, "A2", "D2", "h2", 100);
    _ = try AssetModule.mintAsset("did:mv:bob", .audio, "B1", "D3", "h3", 100);
    
    var buf: [10]AssetModule.CreativeAsset = undefined;
    const alice_assets = AssetModule.listCreatorAssets("did:mv:alice", &buf);
    try std.testing.expectEqual(@as(usize, 2), alice_assets.len);
}
