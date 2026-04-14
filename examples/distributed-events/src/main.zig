const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Example: Distributed Event Bus
// ============================================
// Demonstrates: Cross-node event communication

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Distributed Event Bus Example ===", .{});
    std.log.info("Demonstrates: Multi-node event communication\n", .{});

    // Create distributed event bus
    var bus = zigmodu.DistributedEventBus.init(allocator);
    defer bus.deinit();

    // Start listening on port 8080
    try bus.start(8080);
    std.log.info("📡 Event bus started on port 8080", .{});

    // Subscribe to events
    try bus.subscribe("order.created", onOrderCreated);
    std.log.info("✅ Subscribed to 'order.created' events", .{});

    // Simulate connecting to another node
    // In real scenario, this would connect to a remote address
    // const remote_addr = try std.net.Address.parseIp4("192.168.1.100", 8080);
    // try bus.connectToNode("node-2", remote_addr);

    std.log.info("\n🚀 Publishing events...", .{});

    // Publish an event (will be distributed to all connected nodes)
    const event_payload = "{\"order_id\": 123, \"total\": 99.99, \"customer\": \"alice\"}";
    try bus.publish("order.created", event_payload);

    std.log.info("📤 Published 'order.created' event", .{});

    // Show cluster info
    std.log.info("\n📊 Cluster Information:", .{});
    std.log.info("  Connected nodes: {d}", .{bus.getNodeCount()});

    std.log.info("\n✅ Distributed Event Bus Example Complete!", .{});
    std.log.info("In production, events would be distributed across the cluster.", .{});
}

fn onOrderCreated(event: zigmodu.DistributedEventBus.NetworkEvent) void {
    std.log.info("📥 Received event on topic '{s}': {s}", .{ event.topic, event.payload });
}
