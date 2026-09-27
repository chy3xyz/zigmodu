//! Consistent Hashing Partitioner
//!
//!
//! ⚠️ Not yet wired into DistributedEventBus: nothing calls this module, so
//! partition routing is not in effect. Its own tests do run (they were
//! previously described as "disabled" — that was stale: see the `test` blocks
//! at the bottom of this file). Wire it in, or delete it; either is better than
//! a routing strategy that silently does nothing.
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
        self.* = undefined;
    }

    /// Add a node to the hash ring
    ///
    /// Adds virtual nodes spread across the ring.
    pub fn addNode(self: *Self, node_id: []const u8) !void {
        // Track physical node (dupe key for ownership). The `catch` frees the
        // dupe only when the map refused it: an `errdefer` would still be live
        // after a *successful* `put` and would then free a key the map owns —
        // `deinit` frees it again. Same rule at both `append`s below, where the
        // copy is an argument inside a multi-line `.{}` and a line-shaped
        // scanner cannot see it.
        const node_key = try self.allocator.dupe(u8, node_id);
        self.nodes.put(node_key, {}) catch |err| {
            self.allocator.free(node_key);
            return err;
        };

        // Add virtual nodes
        var i: usize = 0;
        while (i < self.virtual_node_count) : (i += 1) {
            const virtual_id = try std.fmt.allocPrint(self.allocator, "{s}#{d}", .{ node_id, i });
            // Owned by the ring entry once the append lands; freed in
            // removeNode/deinit — or right here if the append is refused.
            self.ring.append(self.allocator, .{
                .hash = self.hashKey(virtual_id),
                .node_id = virtual_id,
                .is_virtual = true,
            }) catch |err| {
                self.allocator.free(virtual_id);
                return err;
            };
        }

        // Add the physical node itself. The copy is bound to a local first:
        // inside the `append`'s argument list an allocation failure would leave
        // it unfreed and unreachable.
        const hash = self.hashKey(node_id);
        const physical_id = try self.allocator.dupe(u8, node_id);
        self.ring.append(self.allocator, .{
            .hash = hash,
            .node_id = physical_id,
            .is_virtual = false,
        }) catch |err| {
            self.allocator.free(physical_id);
            return err;
        };

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

    /// Alias for `route` — used by DistributedEventBus for event-key partitioning.
    pub fn partition(self: *Self, event_key: []const u8) ?[]const u8 {
        return self.route(event_key);
    }

    /// Route a key with backup nodes
    ///
    /// Returns primary and backup nodes for redundancy. `backup_nodes` is owned
    /// by the caller: free each element and then the slice itself, with the
    /// partitioner's allocator.
    pub fn routeWithBackups(self: *Self, key: []const u8, backup_count: usize) !RouteResult {
        const ring_len = self.ring.items.len;
        if (ring_len == 0) return .{
            .primary_node = &.{},
            .backup_nodes = &.{},
            .hash = 0,
        };

        const primary = self.route(key) orelse return .{
            .primary_node = &.{},
            .backup_nodes = &.{},
            .hash = 0,
        };

        const hash = self.hashKey(key);
        var backups = std.ArrayList([]const u8).empty;
        // Every copy below is in `backups` before the next allocation can fail,
        // so one unwind for the whole list is enough — and it is dead once the
        // list has been handed to the caller.
        errdefer {
            for (backups.items) |b| self.allocator.free(b);
            backups.deinit(self.allocator);
        }

        // Find next N different nodes.
        var found: usize = 0;
        var scanned: usize = 0;
        var idx = self.findEntry(hash);

        // Walk from the key's own position and wrap: stopping at the end of the
        // ring returned fewer backups than were asked for whenever the key
        // landed in the last `backup_count` slots.
        while (found < backup_count and scanned < ring_len) : ({
            scanned += 1;
            idx = (idx + 1) % ring_len;
        }) {
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

            // Bind the copy before the append: as an argument it is unreachable
            // to the clean-up path when the append itself fails.
            const copy = try self.allocator.dupe(u8, node);
            backups.append(self.allocator, copy) catch |err| {
                self.allocator.free(copy);
                return err;
            };
            found += 1;
        }

        return .{
            .primary_node = primary,
            .backup_nodes = try backups.toOwnedSlice(self.allocator),
            .hash = hash,
        };
    }

    /// Get all nodes in the ring
    ///
    /// The slice is owned by the caller (free it with the partitioner's
    /// allocator); the strings in it are borrowed from the partitioner and stay
    /// valid until it is deinited. `catch continue` used to swallow a failed
    /// append here, which reported "all nodes" while quietly dropping one.
    pub fn getNodes(self: *Self) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        errdefer result.deinit(self.allocator);
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            try result.append(self.allocator, entry.key_ptr.*);
        }
        return try result.toOwnedSlice(self.allocator);
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
            var k: u64 = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(key[i .. i + 8].ptr)), .little);
            k *%= c1;
            k = (k << r) | (k >> (64 - r));
            k *%= c2;

            h ^= k;
            h = (h << r) | (h >> (64 - r));
            h = h *% m +| 0xe6546b64;
        }

        // Handle remaining bytes
        if (len > i) {
            var k2: u64 = 0;
            const remaining = len - i;
            const dest: [*]u8 = @ptrCast(&k2);
            @memcpy(dest[0..remaining], key[i..][0..remaining]);
            k2 *%= c1;
            k2 = (k2 << r) | (k2 >> (64 - r));
            k2 *%= c2;
            h ^= k2;
        }

        h ^= @as(u64, @intCast(len));
        h ^= h >> r;
        h *%= m;
        h ^= h >> r;
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
            h ^= self.hashFNV1a(key[i .. i + 32]) *% prime3;
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
            const gop = counts.getOrPut(n) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
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

test "ConsistentHashPartitioner routeWithBackups hands back owned, distinct nodes" {
    const allocator = std.testing.allocator;
    var partitioner = ConsistentHashPartitioner.init(allocator, .{ .virtual_nodes_per_node = 10 });
    defer partitioner.deinit();

    try partitioner.addNode("node1");
    try partitioner.addNode("node2");
    try partitioner.addNode("node3");

    const result = try partitioner.routeWithBackups("test-key", 2);
    defer {
        for (result.backup_nodes) |b| allocator.free(b);
        allocator.free(result.backup_nodes);
    }

    // Both backups were found even though the key can land in the last two
    // slots of the ring — the walk wraps.
    try std.testing.expectEqual(@as(usize, 2), result.backup_nodes.len);
    try std.testing.expect(result.primary_node.len > 0);
    try std.testing.expectEqualStrings(partitioner.route("test-key").?, result.primary_node);
    try std.testing.expect(!std.mem.eql(u8, result.backup_nodes[0], result.primary_node));
    try std.testing.expect(!std.mem.eql(u8, result.backup_nodes[1], result.primary_node));
    try std.testing.expect(!std.mem.eql(u8, result.backup_nodes[0], result.backup_nodes[1]));

    // Asking for more backups than there are other nodes stops at the ring
    // rather than looping: two peers is every distinct node there is.
    const all = try partitioner.routeWithBackups("test-key", 8);
    defer {
        for (all.backup_nodes) |b| allocator.free(b);
        allocator.free(all.backup_nodes);
    }
    try std.testing.expectEqual(@as(usize, 2), all.backup_nodes.len);
}

test "ConsistentHashPartitioner routeWithBackups on an empty ring owns nothing" {
    const allocator = std.testing.allocator;
    var partitioner = ConsistentHashPartitioner.init(allocator, .{ .virtual_nodes_per_node = 10 });
    defer partitioner.deinit();

    const result = try partitioner.routeWithBackups("test-key", 3);
    try std.testing.expectEqual(@as(usize, 0), result.primary_node.len);
    try std.testing.expectEqual(@as(usize, 0), result.backup_nodes.len);
    try std.testing.expectEqual(@as(u64, 0), result.hash);
}

test "ConsistentHashPartitioner addNode frees the copy it could not hand over" {
    const base = std.testing.allocator;

    // Every allocation of `addNode` in turn: the ones before it succeeded and
    // the ones after it never ran, so what this exercises is the unwind. `base`
    // is the testing allocator, so a copy the ring or the node map did not take
    // shows up as a leak instead of hiding in a counter. `addNode` failing
    // halfway leaves a partially added node behind, so the partitioner is
    // deinited on both paths — and it has to be able to free that state.
    var failures: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var partitioner = ConsistentHashPartitioner.init(allocator, .{ .virtual_nodes_per_node = 3 });
        partitioner.addNode("node1") catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            partitioner.deinit();
            failures += 1;
            continue;
        };
        try std.testing.expectEqual(@as(usize, 1), partitioner.nodeCount());
        partitioner.deinit();
        break;
    }

    // Both outcomes were reached: at least one allocation was refused, and the
    // loop ran off the end of `addNode`'s allocations.
    try std.testing.expect(failures > 0);
    try std.testing.expect(fail_index < 64);
}

test "ConsistentHashPartitioner getNodes owns its slice, not the node names" {
    const base = std.testing.allocator;

    // The slice is the caller's to free; the names inside it belong to the node
    // map and are freed once, by `deinit` — freeing them here would
    // double-free.
    var partitioner = ConsistentHashPartitioner.init(base, .{ .virtual_nodes_per_node = 2 });
    defer partitioner.deinit();
    try partitioner.addNode("node1");
    try partitioner.addNode("node2");

    const nodes = try partitioner.getNodes();
    defer base.free(nodes);
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    var seen_first = false;
    var seen_second = false;
    for (nodes) |name| {
        if (std.mem.eql(u8, name, "node1")) seen_first = true;
        if (std.mem.eql(u8, name, "node2")) seen_second = true;
    }
    try std.testing.expect(seen_first and seen_second);

    var empty = ConsistentHashPartitioner.init(base, .{});
    defer empty.deinit();
    const none = try empty.getNodes();
    defer base.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // The failure path: with the very next allocation refused, `getNodes`
    // reports it instead of returning a short list, and the node map is left
    // intact for `deinit` to free.
    var failing = std.testing.FailingAllocator.init(base, .{});
    const failing_allocator = failing.allocator();
    var tight = ConsistentHashPartitioner.init(failing_allocator, .{ .virtual_nodes_per_node = 2 });
    defer tight.deinit();
    try tight.addNode("node1");
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, tight.getNodes());
    try std.testing.expectEqual(@as(usize, 1), tight.nodeCount());
}
