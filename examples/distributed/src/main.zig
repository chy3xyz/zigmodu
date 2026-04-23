const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Distributed Example - Multi-Node Demo
// ============================================
// Demonstrates:
// - DistributedEventBus for cross-node communication
// - Docker multi-container deployment
// - Cluster configuration via environment variables
//
// This demo shows the structure of a distributed ZigModu application.
// Due to Zig 0.16.0 API differences, the full DistributedEventBus
// network code may require adjustments for your Zig version.
//
// Docker Compose runs 3 containers, each running this example.
// See docker-compose.yml for the configuration.
//

/// Shared order event for demonstrating distributed pub/sub
pub const OrderEvent = struct {
    order_id: u64,
    event_type: []const u8,
    amount: f64,
    timestamp: i64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("=== ZigModu Distributed Example ===", .{});
    std.log.info("This demonstrates a distributed node configuration", .{});

    // Configuration would come from environment variables in production
    const node_id = "node1";
    const port: u16 = 9000;

    std.log.info("Node configuration:", .{});
    std.log.info("  Node ID: {s}", .{node_id});
    std.log.info("  Port: {d}", .{port});

    // Initialize DistributedEventBus
    std.log.info("Initializing DistributedEventBus...", .{});
    var event_bus = try zigmodu.DistributedEventBus.init(allocator, io, node_id);
    defer event_bus.deinit();

    // Subscribe to order events
    {
        const Handler = struct {
            const Self = @This();
            var node_id_ptr: []const u8 = undefined;

            pub fn handler(event: zigmodu.DistributedEventBus.NetworkEvent) void {
                std.log.info("[{s}] Received event on topic '{s}': {s}", .{
                    Self.node_id_ptr, event.topic, event.payload,
                });
            }
        };
        Handler.node_id_ptr = node_id;
        try event_bus.subscribe("order", Handler.handler);
    }

    // Start the event bus listener
    std.log.info("Starting event bus listener on port {d}...", .{port});
    try event_bus.start(port);
    std.log.info("[{s}] Event bus listening on port {d}", .{ node_id, port });

    std.log.info("[{s}] Node startup complete", .{node_id});

    // Create a test event
    const test_event = OrderEvent{
        .order_id = 12345,
        .event_type = "created",
        .amount = 99.99,
        .timestamp = zigmodu.time.monotonicNowSeconds(),
    };

    std.log.info("Created test event:", .{});
    std.log.info("  order_id: {}", .{test_event.order_id});
    std.log.info("  event_type: {s}", .{test_event.event_type});
    std.log.info("  amount: {d}", .{test_event.amount});
    std.log.info("  timestamp: {}", .{test_event.timestamp});

    // Demonstrate that the event bus API is working
    std.log.info("Event bus state:", .{});
    std.log.info("  Subscribed topics: order", .{});
    std.log.info("  Connected nodes: {d}", .{event_bus.getNodeCount()});

    std.log.info("[{s}] Demo complete - event bus initialized and listening", .{node_id});
    std.log.info("To test distributed communication, run multiple nodes with docker-compose", .{});
}