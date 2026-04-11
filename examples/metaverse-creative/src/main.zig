const std = @import("std");
const zigmodu = @import("zigmodu");

// 导入元宇宙创意经济模块
const IdentityModule = @import("../modules/identity.zig").IdentityModule;
const AssetModule = @import("../modules/asset.zig").AssetModule;
const WorldModule = @import("../modules/world.zig").WorldModule;

/// ============================================
/// MetaVerse Creative Economy Demo
/// 元宇宙创意变现平台演示
///
/// 愿景：构建一个开放的创意经济生态系统，让每个创作者都能在元宇宙中
/// 创作、组合、变现自己的数字资产，建立可持续的创作者经济。
///
/// 本演示展示完整的创意变现流程：
/// 1. 创作者入驻与身份建立
/// 2. 创意资产的铸造与组合
/// 3. 虚拟世界的构建与渲染
/// 4. 经济系统的运转与收益分配
/// ============================================
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化日志
    std.log.info("\n╔══════════════════════════════════════════════════════════════╗", .{});
    std.log.info("║     MetaVerse Creative Economy Platform Demo                  ║", .{});
    std.log.info("║     元宇宙创意变现平台演示                                      ║", .{});
    std.log.info("╚══════════════════════════════════════════════════════════════╝\n", .{});

    // ==================== Phase 1: 创作者入驻 ====================
    std.log.info("【Phase 1】创作者入驻与身份建立\n", .{});

    try IdentityModule.init();
    defer IdentityModule.deinit();

    // 注册三位创作者
    try IdentityModule.registerCreator("did:mv:alice", "Alice - 3D Architect", "0xAlice1234567890");
    try IdentityModule.updateReputation("did:mv:alice", 3500); // 给予高声誉
    try IdentityModule.verifyCreator("did:mv:alice");

    try IdentityModule.registerCreator("did:mv:bob", "Bob - Texture Artist", "0xBob0987654321");
    try IdentityModule.updateReputation("did:mv:bob", 1800);

    try IdentityModule.registerCreator("did:mv:carol", "Carol - World Builder", "0xCarol1122334455");
    try IdentityModule.updateReputation("did:mv:carol", 4200);
    try IdentityModule.verifyCreator("did:mv:carol");

    std.log.info("✓ 3 位创作者已入驻平台\n", .{});

    // ==================== Phase 2: 资产铸造 ====================
    std.log.info("【Phase 2】创意资产的铸造与确权\n", .{});

    try AssetModule.init();
    defer AssetModule.deinit();

    // Alice 铸造 3D 建筑资产
    const building_id = try AssetModule.mintAsset("did:mv:alice", .model_3d, "Cyberpunk Skyscraper", "A towering neon-lit skyscraper with holographic billboards", "hash_building_001", 15_000_000 // 15MB
    );
    try AssetModule.setAssetPrice("hash_building_001", 2500);

    const vehicle_id = try AssetModule.mintAsset("did:mv:alice", .model_3d, "Hover Car", "Futuristic flying vehicle with particle trails", "hash_vehicle_001", 5_000_000);
    try AssetModule.setAssetPrice("hash_vehicle_001", 1200);

    // Bob 铸造纹理资产
    const neon_texture = try AssetModule.mintAsset("did:mv:bob", .texture, "Neon Glow Texture", "Pulsing neon light texture for cyberpunk atmosphere", "hash_texture_001", 2_000_000);
    try AssetModule.setAssetPrice("hash_texture_001", 400);

    const metal_texture = try AssetModule.mintAsset("did:mv:bob", .texture, "Scratched Metal", "Industrial metal surface with wear and tear", "hash_texture_002", 1_500_000);
    try AssetModule.setAssetPrice("hash_texture_002", 300);

    std.log.info("✓ 4 个创意资产已铸造完成", .{});
    std.log.info("  - Cyberpunk Skyscraper: 2500 tokens", .{});
    std.log.info("  - Hover Car: 1200 tokens", .{});
    std.log.info("  - Neon Glow Texture: 400 tokens", .{});
    std.log.info("  - Scratched Metal: 300 tokens\n", .{});

    // ==================== Phase 3: 资产组合 ====================
    std.log.info("【Phase 3】资产组合与协作创作\n", .{});

    // Carol 组合多个资产创建复杂场景
    const scene_components = [_]u64{ building_id, vehicle_id, neon_texture };
    const composed_scene = try AssetModule.composeAssets("did:mv:carol", "Night City Street", "Complete cyberpunk street scene with buildings, vehicles and lighting", &scene_components);

    std.log.info("✓ Carol 组合了 3 个资产创建新场景 'Night City Street'", .{});
    std.log.info("  - 组合资产价格: {d} tokens (含 20% 创作溢价)\n", .{2500 + 1200 + 400 + (2500 + 1200 + 400) / 5});

    // ==================== Phase 4: 世界构建 ====================
    std.log.info("【Phase 4】虚拟世界的构建与渲染\n", .{});

    try WorldModule.init();
    defer WorldModule.deinit();

    // Carol 创建虚拟世界
    const world_id = try WorldModule.createWorld("did:mv:carol", "Neo-Tokyo 2077", "NeoTokyo Coin", "NEOTOK");

    // 添加场景到世界
    try WorldModule.addScene(world_id, "Shibuya Crossing", .{ 0.0, 0.0, 0.0 });
    try WorldModule.addScene(world_id, "Skyscraper Rooftop", .{ 100.0, 200.0, 50.0 });
    try WorldModule.addScene(world_id, "Underground Bar", .{ -50.0, -20.0, 30.0 });

    std.log.info("✓ 虚拟世界 'Neo-Tokyo 2077' 已创建", .{});
    std.log.info("  - 包含 3 个精心设计的场景", .{});
    std.log.info("  - 拥有独立的经济系统 (NEOTOK 代币)\n", .{});

    // ==================== Phase 5: 场景渲染 ====================
    std.log.info("【Phase 5】世界场景渲染展示\n", .{});

    var render_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&render_buf);

    try WorldModule.renderScene(world_id, 1, fbs.writer());
    std.log.info("{s}", .{fbs.getWritten()});

    // ==================== Phase 6: 经济流转 ====================
    std.log.info("【Phase 6】经济系统与创作者收益\n", .{});

    // 注册访问者
    try IdentityModule.registerCreator("did:mv:visitor1", "MetaTourist", "0xVisitor1");
    try IdentityModule.updateReputation("did:mv:visitor1", 800); // 普通游客

    try IdentityModule.registerCreator("did:mv:vip1", "MetaVIP", "0xVIP1");
    try IdentityModule.updateReputation("did:mv:vip1", 4500); // VIP 高声誉

    // 设置入场费
    // 注意：在当前版本中，入场费为 0，实际应用中可从 ConfigManager 读取

    // 模拟访问
    const fee1 = try WorldModule.visitWorld(world_id, "did:mv:visitor1");
    const fee2 = try WorldModule.visitWorld(world_id, "did:mv:vip1");
    const fee3 = try WorldModule.visitWorld(world_id, "did:mv:alice");

    std.log.info("✓ 3 位访客访问了世界 'Neo-Tokyo 2077'", .{});
    std.log.info("  - MetaTourist (声誉 800): 支付 {d} tokens", .{fee1});
    std.log.info("  - MetaVIP (声誉 4500): 支付 {d} tokens (高声誉折扣)", .{fee2});
    std.log.info("  - Alice (声誉 3500): 支付 {d} tokens\n", .{fee3});

    // 获取世界统计
    const stats = try WorldModule.getWorldStats(world_id);
    std.log.info("【世界统计】", .{});
    std.log.info("  - 总访客数: {d}", .{stats.visitors});
    std.log.info("  - 总收入: {d} tokens", .{stats.revenue});
    std.log.info("  - 世界总价值: {d} tokens\n", .{stats.value});

    // ==================== Phase 7: 收益分配 ====================
    std.log.info("【Phase 7】创作者收益分配\n", .{});

    std.log.info("创作者收益统计:", .{});

    // Alice 的资产收益
    if (AssetModule.getAsset("hash_building_001")) |asset| {
        const potential_revenue = asset.price * 5; // 假设销售 5 次
        const royalty = potential_revenue * asset.royalty_percent / 100;
        std.log.info("  Alice (3D Architect):", .{});
        std.log.info("    - Skyscraper 销售额: {d} tokens", .{potential_revenue});
        std.log.info("    - 版税收入 (10%): {d} tokens", .{royalty});
        std.log.info("    - 声誉等级: Expert (x2.0 收益 multiplier)\n", .{});
    }

    // Bob 的资产收益
    if (AssetModule.getAsset("hash_texture_001")) |asset| {
        std.log.info("  Bob (Texture Artist):", .{});
        std.log.info("    - Texture 销售额: {d} tokens", .{asset.price * 8});
        std.log.info("    - 声誉等级: Rising (x1.2 收益 multiplier)\n", .{});
    }

    // Carol 的世界收益
    std.log.info("  Carol (World Builder):", .{});
    std.log.info("    - 世界入场费收入: {d} tokens", .{stats.revenue});
    std.log.info("    - 资产组合销售: {d} tokens", .{4900});
    std.log.info("    - 声誉等级: Established (x1.5 收益 multiplier)\n", .{});

    // ==================== 总结 ====================
    std.log.info("╔══════════════════════════════════════════════════════════════╗", .{});
    std.log.info("║                   DEMO COMPLETE 演示完成                      ║", .{});
    std.log.info("╠══════════════════════════════════════════════════════════════╣", .{});
    std.log.info("║  关键成就:                                                    ║", .{});
    std.log.info("║  ✓ 3 位创作者建立了去中心化身份                               ║", .{});
    std.log.info("║  ✓ 4 个独立创意资产被铸造和确权                               ║", .{});
    std.log.info("║  ✓ 1 个复杂场景通过资产组合创建                               ║", .{});
    std.log.info("║  ✓ 1 个虚拟世界被构建并渲染                                   ║", .{});
    std.log.info("║  ✓ 3 位访客体验了虚拟世界                                     ║", .{});
    std.log.info("║  ✓ 创作者通过多种方式获得收益                                 ║", .{});
    std.log.info("╚══════════════════════════════════════════════════════════════╝\n", .{});

    std.log.info("💡 核心创新点:", .{});
    std.log.info("  1. 模块化架构 - 每个功能都是独立的 ZigModu 模块", .{});
    std.log.info("  2. 声誉经济 - 高声誉创作者获得更多收益分成", .{});
    std.log.info("  3. 资产组合 - 低门槛创作通过组合现有资产", .{});
    std.log.info("  4. 跨平台流通 - 标准化资产格式支持多平台", .{});
    std.log.info("  5. 透明经济 - 区块链确权和智能合约自动分账\n", .{});
}
