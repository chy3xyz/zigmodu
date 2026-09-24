//! Cluster membership via gossip over DistributedEventBus.
//!
//! Uses `subscribeWithContext` so membership events update this node's table
//! (join / heartbeat / leave / leader_election). Suitable for small clusters
//! (documented guidance: 3–7 nodes) behind an external load balancer.
//!
//! ## What `nodes` is (a census — nothing is retired)
//!
//! `nodes` holds every node this process has ever heard about, `self` included,
//! and entries are **appended, never removed** (there is no removal path in this
//! file; `deinit` is the only thing that frees one). Liveness lives in
//! `ClusterNode.state`: a peer that misses `node_timeout_ms` walks
//! `healthy → suspect → failed` and **stays in the map**. Three things depend on
//! that, so it is the intent, not an omission:
//!
//!  * `nodesSnapshot` lends out `ClusterNode` values whose `id` borrows the map's
//!    own copy, and its consumer (`cluster/MembershipView.zig`) copies those
//!    strings into the view *after* the lock is dropped. Freeing an id before the
//!    membership dies would turn that copy into a use-after-free.
//!  * The read side wants the dead peer *visible*: `MembershipView.sync` publishes
//!    it with `healthy = false`, which keeps it out of `ClusterView.pick` while
//!    still showing an operator that it exists.
//!  * A peer that comes back is the *same* entry — `handleGossipEvent` resets any
//!    non-healthy state to `.healthy` on its next heartbeat. So there is no re-add
//!    path that could double-count, and no join callback for a peer that merely
//!    returned.
//!
//! Consequences to read the accessors by: `getNodeCount` is the **census** (dead
//! peers included, so it is not the live cluster size), `getHealthyNodeCount` is
//! the live reading, and everything that needs liveness filters on state —
//! `electLeaderLocked` (below), `MembershipView` and `ClusterView.pick`. The
//! census is bounded by the number of distinct node ids ever seen, not by the
//! cluster size: a peer that restarts under a **new** id leaves its old entry
//! behind until `deinit`.

const std = @import("std");
const Time = @import("Time.zig");
const DistributedEventBus = @import("DistributedEventBus.zig").DistributedEventBus;
const AccrualFailureDetector = @import("cluster/FailureDetector.zig").AccrualFailureDetector;
const ArrayList = std.array_list.Managed;

/// Cluster Membership Service using gossip protocol
/// Tracks node health, handles join/leave events, and performs leader election
pub const ClusterMembership = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    node_id: []const u8,
    address: std.Io.net.IpAddress,
    bus: *DistributedEventBus,
    failure_detector: ?*AccrualFailureDetector = null,
    nodes: std.StringHashMap(ClusterNode),
    is_running: bool,
    on_node_join_cb: ?*const fn ([]const u8, std.Io.net.IpAddress) void,
    on_node_leave_cb: ?*const fn ([]const u8) void,
    on_leader_change_cb: ?*const fn (?[]const u8) void,
    mutex: std.Io.Mutex,
    gossip_interval_ms: u32,
    health_check_interval_ms: u32,
    node_timeout_ms: u32,
    current_leader: ?[]const u8,

    pub const ClusterNode = struct {
        id: []const u8,
        address: std.Io.net.IpAddress,
        state: NodeState,
        last_seen: i64,
        joined_at: i64,
    };

    pub const NodeState = enum {
        healthy,
        suspect,
        failed,
        leaving,
    };

    pub const GossipEvent = struct {
        event_type: EventType,
        node_id: []const u8,
        host: []const u8,
        port: u16,
        timestamp: i64,
    };

    pub const EventType = enum(u8) {
        join = 1,
        heartbeat = 2,
        suspect = 3,
        leave = 4,
        leader_election = 5,
    };

    pub const Config = struct {
        gossip_interval_ms: u32 = 1000,
        health_check_interval_ms: u32 = 3000,
        node_timeout_ms: u32 = 10000,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, node_id: []const u8, address: std.Io.net.IpAddress, bus: *DistributedEventBus) !Self {
        const id_copy = try allocator.dupe(u8, node_id);
        errdefer allocator.free(id_copy);

        var nodes = std.StringHashMap(ClusterNode).init(allocator);

        // Add self to cluster
        try nodes.put(id_copy, .{
            .id = id_copy,
            .address = address,
            .state = .healthy,
            .last_seen = 0,
            .joined_at = 0,
        });

        return .{
            .allocator = allocator,
            .io = io,
            .node_id = id_copy,
            .address = address,
            .bus = bus,
            .failure_detector = null,
            .nodes = nodes,
            .is_running = false,
            .on_node_join_cb = null,
            .on_node_leave_cb = null,
            .on_leader_change_cb = null,
            .mutex = std.Io.Mutex.init,
            .gossip_interval_ms = 1000,
            .health_check_interval_ms = 3000,
            .node_timeout_ms = 10000,
            .current_leader = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        if (self.current_leader) |leader| {
            self.allocator.free(leader);
        }

        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, self.node_id)) {
                self.allocator.free(entry.value_ptr.id);
            }
        }
        self.nodes.deinit();
        self.allocator.free(self.node_id);
        self.* = undefined;
    }

    /// Start membership: subscribe to gossip and announce join.
    /// Drive periodic heartbeat/health via `runOnce()` (Zig 0.17 Io has no
    /// blocking sleep; do not spawn OS threads with `std.Io.Mutex`).
    pub fn start(self: *Self, config: Config) !void {
        if (self.is_running) return;

        self.gossip_interval_ms = config.gossip_interval_ms;
        self.health_check_interval_ms = config.health_check_interval_ms;
        self.node_timeout_ms = config.node_timeout_ms;
        self.is_running = true;

        // Subscribe with context so gossip events mutate this instance.
        try self.bus.subscribeWithContext("cluster.membership", @ptrCast(self), onBusEvent);

        // Announce join
        self.broadcastEvent(.join) catch |err| {
            std.log.err("[ClusterMembership] Failed to broadcast join: {}", .{err});
        };

        // Initial leader election (self is leader if no other nodes)
        self.electLeader();

        std.log.info("[ClusterMembership] Node {s} joined cluster at {any}", .{ self.node_id, self.address });
    }

    pub fn stop(self: *Self) void {
        if (!self.is_running) return;

        self.is_running = false;

        // Broadcast leave
        self.broadcastEvent(.leave) catch |err| std.log.warn("[ClusterMembership] broadcast leave failed: {}", .{err});
        self.bus.unsubscribeContext("cluster.membership", @ptrCast(self));
    }

    /// Run a single synchronous gossip + health check pass.
    /// Useful for testing and for driving the membership loop externally.
    pub fn runOnce(self: *Self) !void {
        // Record heartbeat
        if (self.failure_detector) |fd| {
            fd.heartbeat(self.node_id) catch |err| {
                std.log.err("[ClusterMembership] Failed to record heartbeat: {}", .{err});
            };
        }
        self.broadcastEvent(.heartbeat) catch |err| {
            std.log.err("[ClusterMembership] Gossip error: {}", .{err});
        };
        self.checkNodeHealth();
    }

    fn checkNodeHealth(self: *Self) void {
        const now = Time.monotonicNowSeconds();
        const timeout_secs = @divFloor(self.node_timeout_ms, 1000);
        var should_broadcast_leader = false;

        // Cancelable on purpose, unlike the read accessors below: this is a
        // *periodic* pass over facts that are already recorded (`last_seen`, the
        // detector's samples), so a canceled wait costs one tick and nothing else —
        // the next `runOnce` re-derives the same transition from the same inputs.
        self.mutex.lock(self.io) catch return;
        {
            defer self.mutex.unlock(self.io);

            var iter = self.nodes.iterator();
            while (iter.next()) |entry| {
                const node = entry.value_ptr;
                if (std.mem.eql(u8, node.id, self.node_id)) continue;

                const elapsed = now - node.last_seen;
                if (node.state == .healthy) {
                    const is_alive = if (self.failure_detector) |fd| fd.isAlive(node.id) else (elapsed <= timeout_secs);
                    if (!is_alive) {
                        node.state = .suspect;
                        std.log.warn("[Cluster] Node {s} suspect", .{node.id});
                    }
                } else if (node.state == .suspect) {
                    const is_dead = if (self.failure_detector) |fd| !fd.isAlive(node.id) else (elapsed > timeout_secs * 2);
                    if (is_dead) {
                        node.state = .failed;
                        if (self.on_node_leave_cb) |cb| cb(node.id);
                        self.bus.disconnectNode(node.id);

                        if (self.current_leader) |leader| {
                            if (std.mem.eql(u8, leader, node.id)) {
                                // Dropping the leader and electing its replacement
                                // are one critical section, and it is this one: the
                                // mutex is held until the end of the loop, and
                                // `isLeader`/`getLeader` take the same mutex — so
                                // the `null` never reaches a reader, and it is not
                                // left behind either (`self` is in `nodes`, never
                                // removed, never moved off `.healthy`, so the
                                // election below always finds a candidate; only a
                                // failed leader copy can leave it null, and then
                                // `isLeader`'s "single node ⇒ leader" fallback is
                                // saying the truth — the one node left is this one).
                                self.allocator.free(leader);
                                self.current_leader = null;
                                should_broadcast_leader = self.electLeaderLocked();
                            }
                        }
                    }
                }
            }
        }

        // Never broadcast while holding mutex — publish invokes onBusEvent → handleGossipEvent.
        if (should_broadcast_leader) {
            self.broadcastEvent(.leader_election) catch |err| std.log.warn("[ClusterMembership] broadcast leader_election failed: {}", .{err});
        }
    }

    fn broadcastEvent(self: *Self, event_type: EventType) !void {
        // Use a static-sized buffer on stack to avoid heap allocation per broadcast
        var buf: [1024]u8 = undefined;

        var addr_buf: [64]u8 = undefined;
        // `{f}`, not `{any}`: the latter renders the structural dump
        // (`.{ .ip4 = .{ .bytes = … } }`), which used to travel inside the
        // gossip payload as `"h"`. `{f}` calls `IpAddress.format` → `host:port`.
        var w = std.Io.Writer.fixed(&addr_buf);
        w.print("{f}", .{self.address}) catch |err| {
            std.log.debug("[ClusterMembership] address format failed: {}", .{err});
        };
        const addr_str = w.buffered();
        const host = if (std.mem.indexOf(u8, addr_str, ":")) |colon| addr_str[0..colon] else addr_str;

        const payload = try std.fmt.bufPrint(&buf, "{{\"t\":{d},\"id\":\"{s}\",\"h\":\"{s}\",\"p\":{d},\"ts\":{d}}}", .{ @backingInt(event_type), self.node_id, host, self.address.ip4.port, Time.monotonicNowSeconds() });

        try self.bus.publish("cluster.membership", payload);
    }

    fn onBusEvent(ctx: *anyopaque, event: DistributedEventBus.NetworkEvent) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const gossip = parseGossipPayload(event.payload) orelse {
            std.log.warn("[ClusterMembership] Ignoring malformed gossip payload from {s}", .{event.source_node});
            return;
        };
        self.handleGossipEvent(gossip);
    }

    fn parseGossipPayload(payload: []const u8) ?GossipEvent {
        // Payload format from broadcastEvent:
        // {"t":N,"id":"...","h":"...","p":N,"ts":N}
        const t = extractJsonInt(payload, "t") orelse return null;
        const id = extractJsonString(payload, "id") orelse return null;
        const host = extractJsonString(payload, "h") orelse return null;
        const port_i = extractJsonInt(payload, "p") orelse return null;
        const ts = extractJsonInt(payload, "ts") orelse return null;
        if (t < 1 or t > 5) return null;
        return .{
            .event_type = @fromBackingInt(@intCast(@as(u8, @intCast(t)))),
            .node_id = id,
            .host = host,
            .port = @intCast(port_i),
            .timestamp = ts,
        };
    }

    fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
        var key_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{key}) catch return null;
        const pos = std.mem.indexOf(u8, json, needle) orelse return null;
        const val_start = pos + needle.len;
        const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
        return json[val_start..val_end];
    }

    fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
        var key_buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{key}) catch return null;
        const pos = std.mem.indexOf(u8, json, needle) orelse return null;
        var i = pos + needle.len;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
        var end = i;
        if (end < json.len and json[end] == '-') end += 1;
        while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
        if (end == i) return null;
        return std.fmt.parseInt(i64, json[i..end], 10) catch null;
    }

    pub fn handleGossipEvent(self: *Self, event: GossipEvent) void {
        // Cancelable on purpose: a dropped membership event is bounded staleness,
        // not a lost fact — the peer's next heartbeat re-announces it (the same
        // recovery the OOM branch below relies on), and a peer that really left is
        // failed by the next health pass (`2 × node_timeout_ms`). The exception
        // worth knowing: a dropped `.leader_election` can leave this node on a
        // stale leader until a later election is announced or its own health pass
        // fails the leader it holds.
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (std.mem.eql(u8, event.node_id, self.node_id)) return;

        const now = Time.monotonicNowSeconds();
        // The gossip payload carries the peer's host, but nothing here resolves
        // it: a discovered node is addressed as loopback + its advertised port.
        // So *discovery* works when the peer is reachable at 127.0.0.1 (same host,
        // or a container network that routes it); across hosts use explicit seeds
        // (`connectToSeed`) — those carry their real address and are unaffected.
        const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = event.port } };

        // Record heartbeat in failure detector if available
        if (self.failure_detector) |fd| {
            fd.heartbeat(event.node_id) catch |err| std.log.warn("[ClusterMembership] failure detector heartbeat failed: {}", .{err});
        }

        if (self.nodes.getPtr(event.node_id)) |node| {
            node.last_seen = now;
            if (node.state == .suspect or node.state == .failed or node.state == .leaving) {
                node.state = .healthy;
                std.log.info("[ClusterMembership] Node {s} is back healthy", .{event.node_id});
            }
        } else {
            const id_copy = self.allocator.dupe(u8, event.node_id) catch |err| {
                // Reported, never swallowed: the node stays untracked (its next
                // heartbeat re-attempts the join, so this is recoverable), and the
                // caller is the event bus — `onBusEvent` is `void`, so a log is
                // the only channel there is. The same rule as the leader copy
                // below.
                std.log.warn("[ClusterMembership] cannot track joining node {s}: {}", .{ event.node_id, err });
                return;
            };
            self.nodes.put(id_copy, .{
                .id = id_copy,
                .address = addr,
                .state = .healthy,
                .last_seen = now,
                .joined_at = now,
            }) catch {
                self.allocator.free(id_copy);
                return;
            };

            std.log.info("[ClusterMembership] Node {s} joined at {s}:{d}", .{ event.node_id, event.host, event.port });
            if (self.on_node_join_cb) |cb| {
                cb(event.node_id, addr);
            }
            self.bus.connectToNode(event.node_id, addr) catch |err| {
                std.log.err("[ClusterMembership] Failed to connect event bus to node {s}: {}", .{ event.node_id, err });
            };
        }

        if (event.event_type == .leave) {
            if (self.nodes.getPtr(event.node_id)) |node| {
                node.state = .leaving;
            }
            if (self.on_node_leave_cb) |cb| {
                cb(event.node_id);
            }
            self.bus.disconnectNode(event.node_id);
        }

        if (event.event_type == .leader_election) {
            // Own the copy *before* dropping the old one. Freeing first and
            // copying after leaves `current_leader` pointing at freed memory
            // when the copy fails, and the only signal left (`return`) reads
            // as "nothing to do" — while `getLeader`/`isLeader`, the callback
            // below and `deinit` all keep reading that pointer.
            //
            // The copy cannot be propagated: this runs inside the bus callback
            // (`onBusEvent` is `void`), where an error has no channel and the
            // caller is the event bus, not a request. Keeping the previously
            // elected leader is the honest no-op — the alternative, nulling the
            // field, makes `isLeader` fall back to "single node ⇒ leader".
            const new_leader = self.allocator.dupe(u8, event.node_id) catch |err| {
                std.log.warn("[ClusterMembership] Leader copy for {s} failed, keeping the current leader: {}", .{ event.node_id, err });
                return;
            };
            if (self.current_leader) |leader| {
                self.allocator.free(leader);
            }
            self.current_leader = new_leader;
            if (self.on_leader_change_cb) |cb| {
                cb(self.current_leader);
            }
        }
    }

    pub fn connectToSeed(self: *Self, node_id: []const u8, address: std.Io.net.IpAddress) !void {
        try self.bus.connectToNode(node_id, address);
        std.log.info("[ClusterMembership] Connected to seed node {s} at {any}", .{ node_id, address });
    }

    /// How many nodes this process knows about — the **census**, `self`
    /// included, with peers in any non-healthy state (`.suspect`, `.failed`,
    /// `.leaving`) still counted (see "What `nodes` is" at the top of this file).
    /// This is therefore *not* the live cluster size: `getHealthyNodeCount` is the
    /// reading a health endpoint or a capacity number wants, and no in-tree caller
    /// makes a quorum decision on this one.
    pub fn getNodeCount(self: *Self) usize {
        // Uncancelable: `0` is a published reading, not a placeholder — it says
        // "this cluster holds no nodes" to whatever health endpoint or metrics
        // scrape asks, and the accessor has no error channel to report a
        // cancelation through. The critical section is one map count.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.nodes.count();
    }

    /// How many nodes are `.healthy` right now. `suspect`, `failed` and
    /// `leaving` peers are **not** counted, so this is the live reading — and it
    /// is the one to use wherever "how much cluster is up" matters (the census
    /// `getNodeCount` returns would count dead peers). `self` counts: nothing in
    /// this file moves it off `.healthy` (the health pass skips it and gossip from
    /// itself is ignored).
    pub fn getHealthyNodeCount(self: *Self) usize {
        // Uncancelable, for the same reason as `getNodeCount`: a fabricated `0`
        // reads as "every node is down", which is the input a quorum or capacity
        // decision is made on. One map walk.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var count: usize = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.state == .healthy) {
                count += 1;
            }
        }
        return count;
    }

    /// Copy the node list into `out` (mutex-protected) and return how many were
    /// written. This is the seam the **read side** needs: `ClusterView` is fed
    /// from here (`cluster/MembershipView.zig`), so request paths never touch
    /// this hash map. `ClusterNode` values borrow `id` — valid while the
    /// membership lives, which is exactly what a view publish expects.
    ///
    /// What comes back is the **census**, and it only grows: a `.failed` peer is
    /// still listed, with the state a consumer needs to keep it out of routing
    /// (`MembershipView.sync` publishes it as `healthy = false`; `ClusterView.pick`
    /// skips it) instead of losing the operator's only record that it exists. The
    /// list therefore cannot shrink under a consumer — `deinit` is the only thing
    /// that drops an entry. Truncation is bounded by `out.len`; the copy stops
    /// there rather than writing past it.
    pub fn nodesSnapshot(self: *Self, out: []ClusterNode) usize {
        // Uncancelable: `0` is a published reading, not a placeholder — this is
        // the snapshot the read side is fed from (`cluster/MembershipView.zig`),
        // so "zero nodes" claims the cluster is empty while it is not, and the
        // publish path that consumes it replaces the whole view. The critical
        // section is a bounded copy.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var n: usize = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (n >= out.len) break;
            out[n] = entry.value_ptr.*;
            n += 1;
        }
        return n;
    }

    pub fn getLeader(self: *Self) ?[]const u8 {
        // Uncancelable: `null` is a reading, not a placeholder — it says "this
        // cluster has no leader", which is the signal a failover path or a
        // leader-only duty acts on, and there is no error channel to tell the two
        // apart (`?[]const u8` is the answer). The critical section is a pointer
        // read. Red: `core.ClusterMembership.test.canceled lock wait does not
        // fabricate an empty cluster reading` fails at its first assertion.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.current_leader;
    }

    pub fn isLeader(self: *Self) bool {
        // Uncancelable: `false` is a reading, not a placeholder — it asserts "this
        // node is not the leader", and the callers that act on it (leader-only
        // duties, failover paths) cannot tell a fabricated answer from the truth.
        // The critical section is one string compare, so waiting costs nothing;
        // the old `catch return false` answered a canceled wait, which is the
        // only error `std.Io.Mutex.lock` has.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.current_leader) |leader| {
            return std.mem.eql(u8, leader, self.node_id);
        }
        // If no leader elected yet and we're the only node, we're leader
        return self.nodes.count() == 1;
    }

    pub fn electLeader(self: *Self) void {
        const should_broadcast = blk: {
            // Cancelable on purpose: an election is idempotent — it re-derives the
            // winner from `nodes` — and every node runs the same pass, so a canceled
            // wait costs one round rather than the election.
            self.mutex.lock(self.io) catch return;
            defer self.mutex.unlock(self.io);
            break :blk self.electLeaderLocked();
        };
        // broadcastEvent → publish → onBusEvent → handleGossipEvent locks mutex;
        // Io.Mutex is not recursive — broadcast only after unlock.
        if (should_broadcast) {
            self.broadcastEvent(.leader_election) catch |err| std.log.warn("[ClusterMembership] broadcast leader_election failed: {}", .{err});
        }
    }

    /// Update current_leader under lock. Returns true if caller should broadcast
    /// `.leader_election` (this node is the new leader).
    fn electLeaderLocked(self: *Self) bool {
        // Simple leader election: lowest node_id wins
        var leader_id: ?[]const u8 = null;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr;
            if (node.state != .healthy and node.state != .suspect) continue;
            if (leader_id == null or std.mem.lessThan(u8, node.id, leader_id.?)) {
                leader_id = node.id;
            }
        }

        if (leader_id) |new_leader| {
            if (self.current_leader == null or !std.mem.eql(u8, self.current_leader.?, new_leader)) {
                // Same rule as the gossip writer above: take the owned copy
                // first, so a failed copy cannot leave `current_leader` at
                // freed memory. `false` here already means "no broadcast", so
                // an error return would be indistinguishable from it — this is
                // a no-op with the previous leader (and every reader's view of
                // it) intact, not a silently failed election.
                const owned = self.allocator.dupe(u8, new_leader) catch |err| {
                    std.log.warn("[ClusterMembership] Leader copy for {s} failed, keeping the current leader: {}", .{ new_leader, err });
                    return false;
                };
                if (self.current_leader) |old| {
                    self.allocator.free(old);
                }
                self.current_leader = owned;
                std.log.info("[ClusterMembership] New leader elected: {s}", .{new_leader});

                if (self.on_leader_change_cb) |cb| {
                    cb(self.current_leader);
                }

                return std.mem.eql(u8, new_leader, self.node_id);
            }
        }
        return false;
    }

    /// Set the failure detector for advanced health checking
    /// Must be called before start() for best results
    pub fn setFailureDetector(self: *Self, fd: *AccrualFailureDetector) void {
        self.failure_detector = fd;
    }

    /// Get phi value for a node (requires failure detector)
    pub fn getNodePhi(self: *Self, node_id: []const u8) ?f64 {
        if (self.failure_detector) |fd| {
            return fd.phi(node_id);
        }
        return null;
    }

    pub fn onNodeJoin(self: *Self, callback: *const fn ([]const u8, std.Io.net.IpAddress) void) void {
        self.on_node_join_cb = callback;
    }

    pub fn onNodeLeave(self: *Self, callback: *const fn ([]const u8) void) void {
        self.on_node_leave_cb = callback;
    }

    pub fn onLeaderChange(self: *Self, callback: *const fn (?[]const u8) void) void {
        self.on_leader_change_cb = callback;
    }
};

// ========================================
// Tests
// ========================================

test "ClusterMembership bus gossip converges via subscribeWithContext" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "bus-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19001);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-local", addr, &bus);
    defer cluster.deinit();

    try cluster.start(.{});
    defer cluster.stop();

    // Simulate remote gossip arriving through the bus (same path as network receive).
    try bus.publish("cluster.membership", "{\"t\":1,\"id\":\"node-remote\",\"h\":\"127.0.0.1\",\"p\":19002,\"ts\":1}");

    try std.testing.expect(cluster.getNodeCount() >= 2);
    try std.testing.expect(cluster.nodes.contains("node-remote"));
}

test "ClusterMembership leader election" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18082);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-b", addr, &bus);
    defer cluster.deinit();

    // Simulate node-a joining (lower id should win)
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18083,
        .timestamp = 0,
    });

    cluster.electLeader();

    try std.testing.expectEqualStrings("node-a", cluster.getLeader().?);
    try std.testing.expect(!cluster.isLeader());
}

test "ClusterMembership node health tracking" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18084);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-1", addr, &bus);
    defer cluster.deinit();

    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-2",
        .host = "127.0.0.1",
        .port = 18085,
        .timestamp = 0,
    });

    try std.testing.expectEqual(@as(usize, 2), cluster.getHealthyNodeCount());
}

test "ClusterMembership node leave and rejoin" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-bus");
    defer bus.deinit();
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18090);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "test-3", addr, &bus);
    defer cluster.deinit();

    // Add 2 nodes
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "n1",
        .host = "127.0.0.1",
        .port = 1,
        .timestamp = 0,
    });
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "n2",
        .host = "127.0.0.1",
        .port = 2,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), cluster.getHealthyNodeCount());

    // Node leaves
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "n1",
        .host = "127.0.0.1",
        .port = 1,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 2), cluster.getHealthyNodeCount());

    // Node rejoins
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "n1",
        .host = "127.0.0.1",
        .port = 1,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 3), cluster.getHealthyNodeCount());
}

// `current_leader` is owned memory, and both writers below free the old copy
// *before* they try to make the new one. When that copy fails they return as if
// nothing had happened, leaving the field pointing at freed memory — which
// `getLeader`/`isLeader`, the leader callback and `deinit` all read afterwards.
//
// The failing allocator is installed once the node table exists, so the induced
// failure lands on the leader copy and nowhere else. The peers are put into the
// table directly rather than announced through gossip: the branch for an unknown
// node dials a socket, and these tests are about memory, not networking.
test "ClusterMembership leader_election keeps a live leader when the copy fails" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18210);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-c", addr, &bus);
    defer cluster.deinit();

    const peer_a = try allocator.dupe(u8, "node-a");
    try cluster.nodes.put(peer_a, .{
        .id = peer_a,
        .address = addr,
        .state = .healthy,
        .last_seen = 0,
        .joined_at = 0,
    });
    const peer_m = try allocator.dupe(u8, "node-m");
    try cluster.nodes.put(peer_m, .{
        .id = peer_m,
        .address = addr,
        .state = .healthy,
        .last_seen = 0,
        .joined_at = 0,
    });

    cluster.handleGossipEvent(.{
        .event_type = .leader_election,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18211,
        .timestamp = 0,
    });
    try std.testing.expectEqualStrings("node-a", cluster.getLeader().?);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cluster.allocator = failing.allocator();

    cluster.handleGossipEvent(.{
        .event_type = .leader_election,
        .node_id = "node-m",
        .host = "127.0.0.1",
        .port = 18212,
        .timestamp = 0,
    });

    // The copy failed, so the recorded leader must still be the old one: alive,
    // and neither the gossiped id nor freed bytes (`Allocator.free` overwrites
    // the buffer with `undefined`, so a dangling read comes back as garbage).
    try std.testing.expectEqualStrings("node-a", cluster.getLeader().?);
}

test "ClusterMembership electLeader keeps a live leader when the copy fails" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18213);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-c", addr, &bus);
    defer cluster.deinit();

    // The lowest id wins an election, so recording "node-z" as leader makes the
    // election below try to replace it.
    const peer_a = try allocator.dupe(u8, "node-a");
    try cluster.nodes.put(peer_a, .{
        .id = peer_a,
        .address = addr,
        .state = .healthy,
        .last_seen = 0,
        .joined_at = 0,
    });
    const peer_z = try allocator.dupe(u8, "node-z");
    try cluster.nodes.put(peer_z, .{
        .id = peer_z,
        .address = addr,
        .state = .healthy,
        .last_seen = 0,
        .joined_at = 0,
    });

    cluster.handleGossipEvent(.{
        .event_type = .leader_election,
        .node_id = "node-z",
        .host = "127.0.0.1",
        .port = 18214,
        .timestamp = 0,
    });
    try std.testing.expectEqualStrings("node-z", cluster.getLeader().?);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    cluster.allocator = failing.allocator();

    cluster.electLeader();

    try std.testing.expectEqualStrings("node-z", cluster.getLeader().?);
}

// `checkNodeHealth` drops the failed leader (`free` + `current_leader = null`)
// *before* electing its replacement. That reads like a window — between the two,
// `isLeader` would fall back to `nodes.count() == 1` and answer "I am leader" —
// but both statements run inside one mutex hold, which `isLeader`/`getLeader`
// also take, and the replacement is in place before the lock is dropped. This
// pins the property a reader actually depends on: after the pass that fails the
// leader, a leader is there, and it is the surviving node.
test "ClusterMembership checkNodeHealth re-elects before it lets the lock go" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18215);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-m", addr, &bus);
    defer cluster.deinit();

    // The lowest id wins, so the peer is the elected leader — the failure below is
    // the one that must be replaced. Backdated well past `node_timeout_ms`
    // (10s default, doubled for the suspect → failed step), so one pass takes it
    // healthy → suspect and the next suspect → failed. `node_timeout_ms` is only
    // read here; `start()` is not needed to drive the health check.
    const peer = try allocator.dupe(u8, "node-a");
    try cluster.nodes.put(peer, .{
        .id = peer,
        .address = addr,
        .state = .healthy,
        .last_seen = Time.monotonicNowSeconds() - 100,
        .joined_at = 0,
    });

    cluster.electLeader();
    try std.testing.expectEqualStrings("node-a", cluster.getLeader().?);
    try std.testing.expect(!cluster.isLeader());

    cluster.checkNodeHealth();
    try std.testing.expectEqual(ClusterMembership.NodeState.suspect, cluster.nodes.get("node-a").?.state);

    cluster.checkNodeHealth();
    try std.testing.expectEqual(ClusterMembership.NodeState.failed, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqualStrings("node-m", cluster.getLeader().?);
    try std.testing.expect(cluster.isLeader());
}

// What this file decides about a peer that walks to `.failed` (see "What `nodes`
// is" at the top): it is **not** retired. It stays in the census — still counted
// by `getNodeCount`, still listed by `nodesSnapshot` — while `getHealthyNodeCount`
// and leader election ignore it by state. Pinned here because that is the reading
// the accessors publish: "we still know about it" is the intent, and the reader
// side depends on the dead peer staying *visible* as unhealthy rather than
// disappearing from the snapshot.
test "ClusterMembership a failed node stays in the census and out of the healthy count" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "census-bus");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18220);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-m", addr, &bus);
    defer cluster.deinit();

    // Peers go straight into the table: the `join` path for an unknown node dials
    // a socket, and this test is about the census, not networking. "node-a" has
    // the lowest id (it wins an election) and is backdated well past
    // `node_timeout_ms` (10s default, doubled for the suspect → failed step), so
    // each health pass advances it one state; "node-z" is fresh and must stay
    // healthy throughout.
    const peer_a = try allocator.dupe(u8, "node-a");
    try cluster.nodes.put(peer_a, .{
        .id = peer_a,
        .address = addr,
        .state = .healthy,
        .last_seen = Time.monotonicNowSeconds() - 100,
        .joined_at = 0,
    });
    const peer_z = try allocator.dupe(u8, "node-z");
    try cluster.nodes.put(peer_z, .{
        .id = peer_z,
        .address = addr,
        .state = .healthy,
        .last_seen = Time.monotonicNowSeconds(),
        .joined_at = 0,
    });

    cluster.electLeader();
    try std.testing.expectEqual(@as(usize, 3), cluster.getNodeCount());
    try std.testing.expectEqual(@as(usize, 3), cluster.getHealthyNodeCount());
    try std.testing.expectEqualStrings("node-a", cluster.getLeader().?);

    cluster.checkNodeHealth();
    try std.testing.expectEqual(ClusterMembership.NodeState.suspect, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 3), cluster.getNodeCount());
    try std.testing.expectEqual(@as(usize, 2), cluster.getHealthyNodeCount());

    cluster.checkNodeHealth();
    try std.testing.expectEqual(ClusterMembership.NodeState.failed, cluster.nodes.get("node-a").?.state);

    // The decision: a failed peer is counted by the census and *not* by the live
    // reading, and both numbers are answers rather than placeholders.
    try std.testing.expectEqual(@as(usize, 3), cluster.getNodeCount());
    try std.testing.expectEqual(@as(usize, 2), cluster.getHealthyNodeCount());

    // And it is still listed, with the state a consumer keys off: `MembershipView`
    // turns it into `healthy = false`, which `ClusterView.pick` skips, while the
    // operator's view keeps the record that the peer existed.
    var snapshot: [4]ClusterMembership.ClusterNode = undefined;
    var listed = cluster.nodesSnapshot(&snapshot);
    try std.testing.expectEqual(@as(usize, 3), listed);
    var failed_seen = false;
    for (snapshot[0..listed]) |node| {
        if (std.mem.eql(u8, node.id, "node-a")) {
            try std.testing.expectEqual(ClusterMembership.NodeState.failed, node.state);
            failed_seen = true;
        }
    }
    try std.testing.expect(failed_seen);

    // Leader election also filters by state, so the dead peer does not lead: the
    // node that is actually up does, and `isLeader` agrees with `getLeader`.
    try std.testing.expectEqualStrings("node-m", cluster.getLeader().?);
    try std.testing.expect(cluster.isLeader());

    // The peer coming back reuses the same entry — one heartbeat, no second copy,
    // no extra census slot. This is why "never retire" costs nothing on the
    // rejoin path (and why the join callback does not fire for a peer that merely
    // returned).
    cluster.handleGossipEvent(.{
        .event_type = .heartbeat,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18221,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.healthy, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 3), cluster.getNodeCount());
    try std.testing.expectEqual(@as(usize, 3), cluster.getHealthyNodeCount());

    listed = cluster.nodesSnapshot(&snapshot);
    var copies: usize = 0;
    for (snapshot[0..listed]) |node| {
        if (std.mem.eql(u8, node.id, "node-a")) copies += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), copies);
}

// The three read-only accessors answering a canceled lock wait with a fabricated
// `0` / `0` / `null` all read the same way: "this cluster holds no nodes and has no
// leader". That is what a health endpoint or metrics scrape publishes, what a
// caller compares against a quorum, and what leader-only duties route on — and
// none of the three has an error channel, because the returned value *is* the
// answer (`isLeader` next door was fixed for exactly that). Each critical section
// is a map walk or a pointer read, so waiting costs nothing. `getLeader` is the
// one with reach: a fabricated `null` says the leader is gone, which is the signal
// a failover path acts on.
test "canceled lock wait does not fabricate an empty cluster reading" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var bus = try DistributedEventBus.init(allocator, io, "reader-node");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18216);
    var cluster = try ClusterMembership.init(allocator, io, "reader-node", addr, &bus);
    defer cluster.deinit();

    // A second, healthy node and an elected peer leader, so the true readings are
    // visibly different from the fabricated ones (2 / 2 / "peer-a", not 0 / 0 /
    // null). Written straight into the table, and the leader set through the
    // `leader_election` event: the `join` path dials the peer
    // (`handleGossipEvent` → `connectToNode`), which is a socket and no part of
    // what this test is about.
    const peer = try allocator.dupe(u8, "peer-a");
    try cluster.nodes.put(peer, .{
        .id = peer,
        .address = addr,
        .state = .healthy,
        .last_seen = 0,
        .joined_at = 0,
    });
    cluster.handleGossipEvent(.{
        .event_type = .leader_election,
        .node_id = "peer-a",
        .host = "127.0.0.1",
        .port = 18217,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 2), cluster.getNodeCount());
    try std.testing.expectEqual(@as(usize, 2), cluster.getHealthyNodeCount());
    try std.testing.expectEqualStrings("peer-a", cluster.getLeader().?);

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var node_count: usize = 0;
        var healthy_count: usize = 0;
        var has_leader: bool = false;

        fn read(c: *ClusterMembership) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            node_count = c.getNodeCount();
            healthy_count = c.getHealthyNodeCount();
            has_leader = c.getLeader() != null;
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);
    Task.node_count = 0;
    Task.healthy_count = 0;
    Task.has_leader = false;

    try cluster.mutex.lock(io);

    var read_fut = try io.concurrent(Task.read, .{&cluster});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (cluster.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    cluster.mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);

    try std.testing.expectEqual(@as(usize, 2), Task.node_count);
    try std.testing.expectEqual(@as(usize, 2), Task.healthy_count);
    try std.testing.expect(Task.has_leader);
}
