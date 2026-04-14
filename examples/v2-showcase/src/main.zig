const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// ZigModu v0.2.0 Feature Showcase
/// ============================================
/// This example demonstrates all new features introduced in v0.2.0:
/// 1. Simplified API (App, Module, ModuleImpl)
/// 2. Distributed Event Bus
/// 3. Web Monitor
/// 4. Plugin System
/// 5. Hot Reloading
const DemoModule = struct {
    module_name: []const u8,
    initialized: bool = false,
    started: bool = false,
    events_received: usize = 0,

    pub fn name(_: *@This()) []const u8 {
        return "demo-module";
    }

    pub fn init(self: *@This(), _: *anyopaque) !void {
        self.initialized = true;
        std.log.info("[{s}] initialized", .{self.module_name});
    }

    pub fn start(self: *@This()) !void {
        self.started = true;
        std.log.info("[{s}] started", .{self.module_name});
    }

    pub fn stop(self: *@This()) void {
        self.started = false;
        std.log.info("[{s}] stopped", .{self.module_name});
    }

    pub fn onEvent(self: *@This(), event: zigmodu.Event) void {
        self.events_received += 1;
        std.log.info("[{s}] received event: {}", .{ self.module_name, event });
    }
};

const MetricsModule = struct {
    module_name: []const u8,
    dependencies_list: []const []const u8 = &.{"demo-module"},

    pub fn name(_: *@This()) []const u8 {
        return "metrics-module";
    }

    pub fn init(_: *@This(), _: *anyopaque) !void {}
    pub fn start(_: *@This()) !void {}
    pub fn stop(_: *@This()) void {}

    pub fn dependencies(_: *@This()) []const []const u8 {
        return &.{"demo-module"};
    }
};

// Legacy-compatible modules for scanModules/WebMonitor
const LegacyDemoModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "legacy-demo",
        .description = "Legacy demo module for WebMonitor",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("[legacy-demo] initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("[legacy-demo] cleaned up", .{});
    }
};

const LegacyMetricsModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "legacy-metrics",
        .description = "Legacy metrics module",
        .dependencies = &.{"legacy-demo"},
    };

    pub fn init() !void {}
    pub fn deinit() void {}
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("\n╔══════════════════════════════════════════════════════════════╗", .{});
    std.log.info("║     ZigModu v0.2.0 Feature Showcase                           ║", .{});
    std.log.info("║     Testing all new features                                  ║", .{});
    std.log.info("╚══════════════════════════════════════════════════════════════╝\n", .{});

    // ========================================
    // Test 1: Simplified API
    // ========================================
    std.log.info("=== Test 1: Simplified API ===", .{});

    var app = zigmodu.App.init(allocator);
    defer app.deinit();

    var demo = DemoModule{ .module_name = "demo" };
    var metrics = MetricsModule{ .module_name = "metrics" };

    try app.register(zigmodu.ModuleImpl(DemoModule).interface(&demo));
    try app.register(zigmodu.ModuleImpl(MetricsModule).interface(&metrics));

    try std.testing.expectEqual(@as(usize, 2), app.moduleCount());
    try app.start();
    try std.testing.expect(demo.initialized);
    try std.testing.expect(demo.started);

    // Test event publishing via Simplified API
    app.publish(.{ .module_init = .{ .module_name = "demo", .timestamp = std.time.timestamp() } });
    try std.testing.expectEqual(@as(usize, 1), demo.events_received);

    app.stop();
    try std.testing.expect(!demo.started);
    std.log.info("✅ Simplified API test passed\n", .{});

    // ========================================
    // Test 2: Plugin Manager
    // ========================================
    std.log.info("=== Test 2: Plugin Manager ===", .{});

    var plugins = zigmodu.PluginManager.init(allocator, "./plugins");
    defer plugins.deinit();

    // In a real scenario, this would scan .so/.dll/.dylib files
    // For testing, we just verify the API works
    try std.testing.expectEqual(@as(usize, 0), plugins.getPluginCount());
    try std.testing.expect(!plugins.isPluginLoaded("test-plugin"));
    std.log.info("✅ Plugin Manager test passed\n", .{});

    // ========================================
    // Test 3: Hot Reloader
    // ========================================
    std.log.info("=== Test 3: Hot Reloader ===", .{});

    var reloader = zigmodu.HotReloader.init(allocator);
    defer reloader.deinit();

    // Watch the source directory
    try reloader.watchPath("./src");
    try std.testing.expectEqual(@as(usize, 1), reloader.getWatchedFiles().len);

    // Set callback and start watching
    _ = false; // change detection placeholder
    reloader.onChange(struct {
        fn callback(path: []const u8) void {
            std.log.info("[HotReloader] Change detected: {s}", .{path});
        }
    }.callback);

    try reloader.startWatching();
    std.log.info("✅ Hot Reloader test passed\n", .{});
    reloader.stopWatching();

    // ========================================
    // Test 4: Distributed Event Bus
    // ========================================
    std.log.info("=== Test 4: Distributed Event Bus ===", .{});

    var bus = zigmodu.DistributedEventBus.init(allocator);
    defer bus.deinit();

    _ = false; // event placeholder
    try bus.subscribe("test.topic", struct {
        fn callback(event: zigmodu.DistributedEventBus.NetworkEvent) void {
            _ = event;
            std.log.info("[DistributedEventBus] Event received on test.topic", .{});
        }
    }.callback);

    try bus.start(18080);
    try std.testing.expectEqual(@as(usize, 0), bus.getNodeCount());
    std.log.info("✅ Distributed Event Bus test passed\n", .{});
    bus.stop();

    // ========================================
    // Test 5: Web Monitor
    // ========================================
    std.log.info("=== Test 5: Web Monitor ===", .{});

    var monitor = zigmodu.WebMonitor.init(allocator, 13000);
    defer monitor.deinit();

    // WebMonitor requires ApplicationModules from the old API
    var legacy_modules = try zigmodu.scanModules(allocator, .{ LegacyDemoModule, LegacyMetricsModule });
    defer legacy_modules.deinit();

    try monitor.start(&legacy_modules);
    std.log.info("✅ Web Monitor started on http://0.0.0.0:13000", .{});
    std.log.info("   Access /api/modules, /api/health, /api/metrics\n", .{});

    // Give the server a moment, then stop
    std.Thread.sleep(100 * std.time.ns_per_ms);
    monitor.stop();
    std.log.info("✅ Web Monitor test passed\n", .{});

    // ========================================
    // Test 6: YAML/TOML Configuration
    // ========================================
    std.log.info("=== Test 6: YAML/TOML Configuration ===", .{});

    var yaml_parser = zigmodu.YamlParser.init(allocator);
    const yaml =
        \\[server]
        \\host: "0.0.0.0"
        \\port: 3000
    ;
    var yaml_config = try yaml_parser.parse(yaml);
    defer yaml_parser.deinitMap(&yaml_config);
    try std.testing.expectEqualStrings("0.0.0.0", yaml_config.get("server.host").?);

    var toml_parser = zigmodu.TomlParser.init(allocator);
    const toml =
        \\[database]
        \\url = "postgres://localhost"
        \\pool_size = 10
    ;
    var toml_config = try toml_parser.parse(toml);
    defer toml_parser.deinitMap(&toml_config);
    try std.testing.expectEqualStrings("postgres://localhost", toml_config.get("database.url").?);

    std.log.info("✅ YAML/TOML Configuration test passed\n", .{});

    // ========================================
    // Test 7: WebSocket Server
    // ========================================
    std.log.info("=== Test 7: WebSocket Server ===", .{});

    var ws_server = zigmodu.WebSocketServer.init(allocator, 19001);
    defer ws_server.deinit();
    try ws_server.start();
    try std.testing.expectEqual(@as(usize, 0), ws_server.clientCount());
    ws_server.stop();
    std.log.info("✅ WebSocket Server test passed\n", .{});

    // ========================================
    // Test 8: Cluster Membership
    // ========================================
    std.log.info("=== Test 8: Cluster Membership ===", .{});

    var cluster_bus = zigmodu.DistributedEventBus.init(allocator);
    defer cluster_bus.deinit();

    const cluster_addr = try std.net.Address.parseIp4("127.0.0.1", 18081);
    var cluster = try zigmodu.ClusterMembership.init(allocator, "showcase-node", cluster_addr, &cluster_bus);
    defer cluster.deinit();

    try std.testing.expectEqual(@as(usize, 1), cluster.getNodeCount());
    try std.testing.expect(cluster.isLeader());
    std.log.info("✅ Cluster Membership test passed\n", .{});

    // ========================================
    // Test 9: Distributed Transactions (2PC)
    // ========================================
    std.log.info("=== Test 9: Distributed Transactions ===", .{});

    var tpc = zigmodu.TwoPhaseCommit.init(allocator);
    defer tpc.deinit();

    try tpc.createCoordinator("showcase-tx");
    try tpc.addParticipant("showcase-tx", "db-node-1", struct {
        fn prep() bool {
            return true;
        }
    }.prep, struct {
        fn cmt() void {}
    }.cmt, struct {
        fn roll() void {}
    }.roll);

    try tpc.execute("showcase-tx");
    try std.testing.expectEqual(zigmodu.TwoPhaseCommit.TransactionCoordinator.TwoPhaseStatus.COMMITTED, tpc.coordinators.get("showcase-tx").?.status);
    std.log.info("✅ Distributed Transactions test passed\n", .{});

    // ========================================
    // Summary
    // ========================================
    std.log.info("╔══════════════════════════════════════════════════════════════╗", .{});
    std.log.info("║              ALL v0.2.0 FEATURE TESTS PASSED                 ║", .{});
    std.log.info("╠══════════════════════════════════════════════════════════════╣", .{});
    std.log.info("║  ✅ Simplified API (App + Module + VTable)                   ║", .{});
    std.log.info("║  ✅ Plugin Manager                                           ║", .{});
    std.log.info("║  ✅ Hot Reloading                                            ║", .{});
    std.log.info("║  ✅ Distributed Event Bus                                    ║", .{});
    std.log.info("║  ✅ Web Monitor                                              ║", .{});
    std.log.info("║  ✅ YAML/TOML Configuration                                  ║", .{});
    std.log.info("║  ✅ WebSocket Server                                         ║", .{});
    std.log.info("║  ✅ Cluster Membership                                       ║", .{});
    std.log.info("║  ✅ Distributed Transactions                                 ║", .{});
    std.log.info("╚══════════════════════════════════════════════════════════════╝", .{});
}

// ========================================
// Unit Tests
// ========================================

test "Simplified API - module registration and lifecycle" {
    const allocator = std.testing.allocator;

    var app = zigmodu.App.init(allocator);
    defer app.deinit();

    var mod = DemoModule{ .module_name = "test" };
    try app.register(zigmodu.ModuleImpl(DemoModule).interface(&mod));
    try std.testing.expectEqual(@as(usize, 1), app.moduleCount());

    try app.start();
    try std.testing.expect(mod.initialized);
    try std.testing.expect(mod.started);

    app.stop();
    try std.testing.expect(!mod.started);
}

test "Simplified API - event publishing" {
    const allocator = std.testing.allocator;

    var app = zigmodu.App.init(allocator);
    defer app.deinit();

    var mod = DemoModule{ .module_name = "event-test" };
    try app.register(zigmodu.ModuleImpl(DemoModule).interface(&mod));
    try app.start();
    defer app.stop();

    app.publish(.{ .module_init = .{ .module_name = "test", .timestamp = 0 } });
    try std.testing.expectEqual(@as(usize, 1), mod.events_received);
}

test "Simplified API - dependencies" {
    const allocator = std.testing.allocator;

    var app = zigmodu.App.init(allocator);
    defer app.deinit();

    var mod = MetricsModule{ .module_name = "metrics" };
    const interface = zigmodu.ModuleImpl(MetricsModule).interface(&mod);
    const deps = interface.dependencies();
    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("demo-module", deps[0]);
}

test "PluginManager - basic operations" {
    const allocator = std.testing.allocator;

    var plugins = zigmodu.PluginManager.init(allocator, "./test_plugins");
    defer plugins.deinit();

    try std.testing.expectEqual(@as(usize, 0), plugins.getPluginCount());
    try std.testing.expect(!plugins.isPluginLoaded("nonexistent"));
}

test "HotReloader - file watching setup" {
    const allocator = std.testing.allocator;

    var reloader = zigmodu.HotReloader.init(allocator);
    defer reloader.deinit();

    try reloader.watchPath("./src");
    try std.testing.expectEqual(@as(usize, 1), reloader.getWatchedFiles().len);
}

test "DistributedEventBus - initialization" {
    const allocator = std.testing.allocator;

    var bus = zigmodu.DistributedEventBus.init(allocator);
    defer bus.deinit();

    try std.testing.expectEqual(@as(usize, 0), bus.getNodeCount());
}

test "WebMonitor - initialization" {
    const allocator = std.testing.allocator;

    var monitor = zigmodu.WebMonitor.init(allocator, 13001);
    defer monitor.deinit();

    var legacy_modules = try zigmodu.scanModules(allocator, .{LegacyDemoModule});
    defer legacy_modules.deinit();

    try monitor.start(&legacy_modules);
    monitor.stop();
}

test "ModuleSnapshot - version tracking" {
    const Snapshot = zigmodu.ModuleSnapshot(u32);
    var snap = Snapshot.init(42);
    try std.testing.expectEqual(@as(u32, 1), snap.version);

    snap.incrementVersion();
    try std.testing.expectEqual(@as(u32, 2), snap.version);
    try std.testing.expectEqual(@as(u32, 42), snap.data);
}

test "ReloadStrategy - enum values" {
    try std.testing.expectEqual(zigmodu.ReloadStrategy.restart, .restart);
    try std.testing.expectEqual(zigmodu.ReloadStrategy.preserve_state, .preserve_state);
    try std.testing.expectEqual(zigmodu.ReloadStrategy.gradual_migration, .gradual_migration);
}

test "YamlParser - basic parsing" {
    const allocator = std.testing.allocator;
    var parser = zigmodu.YamlParser.init(allocator);
    const yaml = "name: zigmodu\nversion: 0.2.0";
    var map = try parser.parse(yaml);
    defer parser.deinitMap(&map);
    try std.testing.expectEqualStrings("zigmodu", map.get("name").?);
}

test "TomlParser - basic parsing" {
    const allocator = std.testing.allocator;
    var parser = zigmodu.TomlParser.init(allocator);
    const toml = "name = \"zigmodu\"\nversion = \"0.2.0\"";
    var map = try parser.parse(toml);
    defer parser.deinitMap(&map);
    try std.testing.expectEqualStrings("zigmodu", map.get("name").?);
}

test "WebSocketServer - initialization" {
    const allocator = std.testing.allocator;
    var server = zigmodu.WebSocketServer.init(allocator, 19002);
    defer server.deinit();
    try std.testing.expectEqual(@as(u16, 19002), server.port);
}

test "ClusterMembership - initialization" {
    const allocator = std.testing.allocator;
    var bus = zigmodu.DistributedEventBus.init(allocator);
    defer bus.deinit();
    const addr = try std.net.Address.parseIp4("127.0.0.1", 18082);
    var cluster = try zigmodu.ClusterMembership.init(allocator, "test-node", addr, &bus);
    defer cluster.deinit();
    try std.testing.expect(cluster.isLeader());
}

test "TwoPhaseCommit - basic commit" {
    const allocator = std.testing.allocator;
    var tpc = zigmodu.TwoPhaseCommit.init(allocator);
    defer tpc.deinit();
    try tpc.createCoordinator("tx-test");
    try tpc.addParticipant("tx-test", "p1", struct {
        fn prep() bool {
            return true;
        }
    }.prep, struct {
        fn cmt() void {}
    }.cmt, struct {
        fn roll() void {}
    }.roll);
    try tpc.execute("tx-test");
    try std.testing.expectEqual(zigmodu.TwoPhaseCommit.TransactionCoordinator.TwoPhaseStatus.COMMITTED, tpc.coordinators.get("tx-test").?.status);
}
