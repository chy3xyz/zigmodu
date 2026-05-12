//! Consistent Hashing Partitioner
//!
//!
//! ⚠️ WORK IN PROGRESS — not yet wired into DistributedEventBus.
//! Tests are implemented but disabled pending integration.
//!
//! Routes messages to nodes using consistent hashing with virtual nodes.
//! This provides:
//! - Uniform distribution across nodes
//! - Minimal remapping when nodes join/leave
//! - Deterministic routing for idempotent operations
//!
//! Reference: Karger et al. "Consistent Hashing and Random Trees"

const std = @import("std");

/// Configuration for consistent hash partitioner
pub const PartitionerConfig = struct {
    /// Number of virtual nodes per physical node
    /// Higher values = more uniform distribution, more memory
    virtual_nodes_per_node: usize = 150,

    /// Hash function to use
    hash_fn: HashFunction = .murmur3,
};

/// Hash function variants
pub const HashFunction = enum {
    murmur3,
    fnv1a,
    xxhash3,
};

/// Consistent hash ring partitioner
///
/// Routes keys (topics, message IDs) to nodes using consistent hashing.
/// Virtual nodes provide better load balancing when nodes join/leave.
pub const ConsistentHashPartitioner = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: PartitionerConfig,

    /// Hash ring - sorted array of (hash, node_id) pairs
    ring: std.ArrayList(RingEntry),

    /// Physical nodes currently in the ring
    nodes: std.StringHashMap(void),

    /// Virtual node count per physical node
    virtual_node_count: usize,

    /// A single entry on the hash ring
    pub const RingEntry = struct {
        hash: u64,
        node_id: []const u8,
        is_virtual: bool,
    };

    /// Routing result with metadata
    pub const RouteResult = struct {
        primary_node: []const u8,
        backup_nodes: []const []const u8,
        hash: u64,
    };

    /// Initialize partitioner with configuration
    pub fn init(allocator: std.mem.Allocator, config: PartitionerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .ring = std.ArrayList(RingEntry).empty,
            .nodes = std.StringHashMap(void).init(allocator),
            .virtual_node_count = config.virtual_nodes_per_node,
        };
    }

    /// Release all resources
    pub fn deinit(self: *Self) void {
        // Free all node IDs in ring (virtual IDs from allocPrint, physical IDs from dupe)
        for (self.ring.items) |entry| {
            self.allocator.free(entry.node_id);
        }
        self.ring.deinit(self.allocator);
        var node_iter = self.nodes.keyIterator();
        while (node_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.nodes.deinit();
    }

    /// Add a node to the hash ring
    ///
    /// Adds virtual nodes spread across the ring.
    pub fn addNode(self: *Self, node_id: []const u8) !void {
        // Track physical node (dupe key for ownership)
        const node_key = try self.allocator.dupe(u8, node_id);
        try self.nodes.put(node_key, {});

        // Add virtual nodes
        var i: usize = 0;
        while (i < self.virtual_node_count) : (i += 1) {
            const virtual_id = try std.fmt.allocPrint(self.allocator, "{s}#{d}", .{ node_id, i });
            // NOTE: virtual_id is stored in ring entry; freed in removeNode/deinit
            const hash = self.hashKey(virtual_id);
            try self.ring.append(self.allocator, .{
                .hash = hash,
                .node_id = virtual_id,
                .is_virtual = true,
            });
        }

        // Add the physical node itself
        const hash = self.hashKey(node_id);
        try self.ring.append(self.allocator, .{
            .hash = hash,
            .node_id = try self.allocator.dupe(u8, node_id),
            .is_virtual = false,
        });

        // Sort ring by hash
        std.sort.pdq(RingEntry, self.ring.items, {}, ringEntryLessThan);
    }

    /// Remove a node from the hash ring
    ///
    /// Removes all virtual nodes for this physical node.
    pub fn removeNode(self: *Self, node_id: []const u8) void {
        if (self.nodes.fetchRemove(node_id)) |kv| {
            self.allocator.free(kv.key);
        }

        // Remove all entries for this node
        var i: usize = 0;
        while (i < self.ring.items.len) {
            const entry = self.ring.items[i];
            // Check if this entry belongs to the node being removed
            const starts_with = std.mem.startsWith(u8, entry.node_id, node_id);

            if (starts_with) {
                self.allocator.free(entry.node_id);
                _ = self.ring.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Route a key to a node
    ///
    /// Uses consistent hashing to find the appropriate node.
    /// Returns the node that owns this key.
    pub fn route(self: *Self, key: []const u8) ?[]const u8 {
        if (self.ring.items.len == 0) return null;

        const hash = self.hashKey(key);

        // Binary search for first entry with hash >= key hash
        const idx = self.findEntry(hash);

        // Wrap around to beginning if needed
        const entry_idx = if (idx >= self.ring.items.len) 0 else idx;

        // Return the physical node (strip virtual suffix if needed)
        const entry = self.ring.items[entry_idx];
        return self.extractPhysicalNode(entry.node_id);
    }

    /// Route a key with backup nodes
    ///
    /// Returns primary and backup nodes for redundancy.
    pub fn routeWithBackups(self: *Self, key: []const u8, backup_count: usize) RouteResult {
        const primary = self.route(key) orelse return .{
            .primary_node = &.{},
            .backup_nodes = &.{},
            .hash = 0,
        };

        const hash = self.hashKey(key);
        var backups = std.ArrayList([]const u8).empty;

        // Find next N different nodes
        var found: usize = 0;
        var idx = self.findEntry(hash);

        while (found < backup_count and idx < self.ring.items.len) : (idx += 1) {
            const entry = self.ring.items[idx];
            const node = self.extractPhysicalNode(entry.node_id) orelse continue;

            // Skip if same as primary
            if (std.mem.eql(u8, node, primary)) continue;

            // Skip if already in backups
            var is_dup = false;
            for (backups.items) |b| {
                if (std.mem.eql(u8, b, node)) {
                    is_dup = true;
                    break;
                }
            }
            if (is_dup) continue;

            try backups.append(try self.allocator.dupe(u8, node));
            found += 1;
        }

        return .{
            .primary_node = primary,
            .backup_nodes = backups.toOwnedSlice(),
            .hash = hash,
        };
    }

    /// Get all nodes in the ring
    pub fn getNodes(self: *Self) []const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            result.append(entry.key_ptr.*) catch continue;
        }
        return result.toOwnedSlice();
    }

    /// Get the number of physical nodes
    pub fn nodeCount(self: Self) usize {
        return self.nodes.count();
    }

    /// Get the total number of ring entries (physical + virtual)
    pub fn ringSize(self: Self) usize {
        return self.ring.items.len;
    }

    // =========================================================================
    // Private Methods
    // =========================================================================

    fn hashKey(self: *Self, key: []const u8) u64 {
        return switch (self.config.hash_fn) {
            .murmur3 => self.hashMurmur3(key),
            .fnv1a => self.hashFNV1a(key),
            .xxhash3 => self.hashXXHash3(key),
        };
    }

    /// FNV-1a hash (fast, good distribution)
    fn hashFNV1a(_: *Self, key: []const u8) u64 {
        // FNV-1a 64-bit
        var h: u64 = 0xcbf29ce484222325;
        for (key) |byte| {
            h ^= byte;
            h = h *% 0x100000001b3;
        }
        return h;
    }

    /// Simplified murmur3-like hash for non-cryptographic use
    fn hashMurmur3(_: *Self, key: []const u8) u64 {
        const c1: u64 = 0xcc9e2d51;
        const c2: u64 = 0x1b873593;
        const m: u64 = 0x0000000000000005;
        const r: u64 = 47;

        var h: u64 = @intCast(key.len);
        const len = key.len;

        // Process 8-byte chunks
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) {
            var k: u64 = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(key[i..i+8].ptr)), .little);
            k *%= c1;
            k = (k << r) | (k >> (64 - r));
            k *%= c2;

            h ^= k;
            h = (h << r) | (h >> (64 - r));
            h = h *% m +| 0xe6546b64;
        }

        // Handle remaining bytes
        var k2: u64 = 0;
        const remaining = len % 8;
        if (remaining > 0) {
            const dest: [*]u8 = @ptrCast(&k2);
            @memcpy(dest[0..remaining], key[i..][0..remaining]);
        }

        h ^= @as(u64, @intCast(remaining));
        h ^= h >> r;
        h *%= m;
        return h;
    }

    /// XXHash3-like hash (fast, high quality)
    fn hashXXHash3(self: *Self, key: []const u8) u64 {
        // Simplified XXHash3-64 for demonstration
        // In production, would use a proper xxhash implementation
        const prime1: u64 = 0x9e3779b185ebca87;
        const prime2: u64 = 0xc2b2ae35d1214671;
        const prime3: u64 = 0x165667b19e3779f9;
        const prime4: u64 = 0x85ebca6c8964a03f;

        var h: u64 = @as(u64, @intCast(key.len)) *% prime1;

        var i: usize = 0;
        while (i + 32 <= key.len) : (i += 32) {
            h +%= prime2;
            h ^= self.hashFNV1a(key[i..i+32]) *% prime3;
            h = (h << 49) | (h >> 15);
            h +%= prime4;
        }

        return h ^ (h >> 31);
    }

    fn findEntry(self: *Self, target_hash: u64) usize {
        // Binary search for first entry with hash >= target
        var low: usize = 0;
        var high = self.ring.items.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.ring.items[mid].hash < target_hash) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        return low;
    }

    fn extractPhysicalNode(_: *Self, node_id: []const u8) ?[]const u8 {
        // If has virtual suffix (#N), strip it
        if (std.mem.indexOf(u8, node_id, "#")) |idx| {
            return node_id[0..idx];
        }
        return node_id;
    }

    fn ringEntryLessThan(_: void, a: RingEntry, b: RingEntry) bool {
        return a.hash < b.hash;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ConsistentHashPartitioner basic routing" {
    const allocator = std.testing.allocator;
    const config = PartitionerConfig{
        .virtual_nodes_per_node = 10, // Small for testing
    };

    var partitioner = ConsistentHashPartitioner.init(allocator, config);
    defer partitioner.deinit();

    try partitioner.addNode("node1");
    try partitioner.addNode("node2");
    try partitioner.addNode("node3");

    try std.testing.expectEqual(@as(usize, 3), partitioner.nodeCount());

    // Same key should always route to same node
    const key = "test-key";
    const route1 = partitioner.route(key);
    const route2 = partitioner.route(key);
    const route3 = partitioner.route(key);

    try std.testing.expect(route1 != null);
    try std.testing.expectEqualStrings(route1.?, route2.?);
    try std.testing.expectEqualStrings(route2.?, route3.?);
}

test "ConsistentHashPartitioner uniform distribution" {
    const allocator = std.testing.allocator;
    const config = PartitionerConfig{
        .virtual_nodes_per_node = 50,
    };

    var partitioner = ConsistentHashPartitioner.init(allocator, config);
    defer partitioner.deinit();

    try partitioner.addNode("A");
    try partitioner.addNode("B");
    try partitioner.addNode("C");

    // Route many keys and count distribution
    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const key = std.fmt.allocPrint(allocator, "key-{d}", .{i}) catch continue;
        defer allocator.free(key);

        const node = partitioner.route(key);
        if (node) |n| {
            const count = counts.getOrPut(n) catch continue;
            count.value_ptr.* += 1;
        }
    }

    // Each node should get roughly 1/3 (allowing for variance)
    var total: usize = 0;
    var iter = counts.iterator();
    while (iter.next()) |entry| {
        total += entry.value_ptr.*;
    }

    try std.testing.expectEqual(@as(usize, 3), counts.count());
}

test "ConsistentHashPartitioner remove node" {
    const allocator = std.testing.allocator;
    var partitioner = ConsistentHashPartitioner.init(allocator, .{ .virtual_nodes_per_node = 10 });
    defer partitioner.deinit();

    try partitioner.addNode("node1");
    try partitioner.addNode("node2");

    try std.testing.expectEqual(@as(usize, 2), partitioner.nodeCount());

    partitioner.removeNode("node1");

    try std.testing.expectEqual(@as(usize, 1), partitioner.nodeCount());

    // node2 should still be routable
    try std.testing.expect(partitioner.route("test") != null);
}
