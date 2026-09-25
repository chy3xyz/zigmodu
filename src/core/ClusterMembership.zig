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
//! `healthy → suspect → failed` and **stays in the map**. Four things depend on
//! that, so it is the intent, not an omission:
//!
//!  * `nodesSnapshot` lends out `ClusterNode` values whose `id` borrows the map's
//!    own copy, and its consumer (`cluster/MembershipView.zig`) copies those
//!    strings into the view *after* the lock is dropped. Freeing an id before the
//!    membership dies would turn that copy into a use-after-free.
//!  * The read side wants the dead peer *visible*: `MembershipView.sync` publishes
//!    it with `healthy = false`, which keeps it out of `ClusterView.pick` while
//!    still showing an operator that it exists. A dead peer is only left *out* of
//!    the read side when its buffer cannot hold the whole census, and then it goes
//!    last — the drop order is `nodesSnapshot`'s.
//!  * A peer that comes back is the *same* entry — `handleGossipEvent` resets any
//!    non-healthy state to `.healthy` on its next heartbeat. So there is no re-add
//!    path that could double-count — but the state is not the whole recovery: the
//!    failure sweep `disconnectNode`s a peer as it marks it `.failed` (and the
//!    `.leave` branch disconnects too), so that branch dials the peer again at the
//!    address the census holds. State and connection are flipped together, in the
//!    one place either of them can be.
//!  * A peer that comes back is announced like one that just joined: the node
//!    callbacks are the two halves of one lifecycle, and a return fires the
//!    second half. `on_node_leave_cb` runs for the transitions that take a peer
//!    out of service (`.failed` from the sweep, `.leave` from gossip), and the
//!    next time that peer is a member again `on_node_join_cb` runs for it — with
//!    the address the census holds, exactly like a first join. So `join` means
//!    "this peer is a member you hold state for" (idempotent: a known peer can be
//!    announced again) and `leave` means "tear that state down"; one `join` per
//!    `leave`, in that order. A peer that only went `.suspect` was never announced
//!    as gone and is not announced on recovery either — nothing was taken out of
//!    service — so the pairing holds in both directions. The mirror image is the
//!    stranger that only says goodbye: a `.leave` for an id that is not in the
//!    census is dropped without a trace, because there is no member to retire —
//!    and inventing one would also make that peer's *real* join later look like a
//!    return (state flip, callback, dial).
//!  * Both callbacks are **edge-triggered** — the state transition, not the
//!    state. `leave` is announced once per departure (a second `.leave` from a
//!    peer already `.failed` or `.leaving` says nothing new, and re-announcing it
//!    would break the "one `join` per `leave`" count above), and
//!    `on_leader_change_cb` runs when the leader this process holds actually
//!    changes, not on every `.leader_election` event: a leader re-states itself
//!    on every election round (`checkNodeHealth` and `electLeader` both
//!    broadcast), so a level-triggered callback would have a consumer that counts
//!    leadership changes, or rebuilds per-leader state (a lock, a lease, a
//!    partition map) on each one, re-derive the same fact every round. Both
//!    writers of `current_leader` announce on the edge and on nothing else.
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
                        // Half of one decision, not a teardown on its own: the
                        // peer's next heartbeat dials this connection back up
                        // in `handleGossipEvent`'s recovery branch. Leaving one
                        // half out is how the census came to say `.healthy`
                        // while the bus held no entry for the peer.
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

        // A `.leave` from an id this process has never recorded is **not** a join:
        // the peer is saying it is out. Handling it as one (what this used to do)
        // inserted it as `.healthy` — firing the join callback and
        // `bus.connectToNode` — and only *then* flipped the entry to `.leaving`, so
        // the census kept a peer that only ever said goodbye, an app saw a join it
        // could never match with a membership, and we dialled a node that had
        // already left. Deciding it here, before anything is recorded, is also what
        // keeps that peer's *later*, real join on the join path below: an entry
        // left behind as `.leaving` counts as "known", and that branch flips the
        // state *without* the callback or the dial. "Nothing is retired" (see the
        // top of this file) is about peers observed *as members*; a goodbye from a
        // stranger is not a fact about this cluster. The one side effect an
        // unrecorded id can have is a connection made by an explicit seed
        // (`connectToSeed` deliberately does not touch the census), so the
        // transport is still torn down — `disconnectNode` ignores an id it does not
        // know.
        const seen = self.nodes.getPtr(event.node_id);
        if (seen == null and event.event_type == .leave) {
            std.log.info("[ClusterMembership] Ignoring leave from unknown node {s}", .{event.node_id});
            self.bus.disconnectNode(event.node_id);
            return;
        }

        // Record heartbeat in failure detector if available. A `.leave` is not a
        // liveness sample — it says the opposite — so it is skipped for a known
        // peer too: recording it would both contradict the state this call writes
        // and give the detector an entry for an id whose samples nothing reads
        // (the detector's history map only grows).
        if (self.failure_detector) |fd| {
            if (event.event_type != .leave) {
                fd.heartbeat(event.node_id) catch |err| std.log.warn("[ClusterMembership] failure detector heartbeat failed: {}", .{err});
            }
        }

        if (seen) |node| {
            node.last_seen = now;
            if (event.event_type == .leave) {
                // The announcement belongs to the *transition* into
                // out-of-service, not to the state. `.failed` was already
                // announced — the sweep fires `on_node_leave_cb` and disconnects
                // in the branch that marks it — and `.leaving` was announced by
                // the goodbye that got here first, so a `.leave` from either is
                // the same fact again: the callback pair this file documents is
                // "one `join` per `leave`", and a consumer mirroring its peer set
                // from these callbacks would tear the same peer down twice and
                // count two departures for one peer. `.suspect` was never
                // announced (nothing was taken out of service), so its goodbye is
                // the announcement.
                const was_in_service = node.state == .healthy or node.state == .suspect;
                node.state = .leaving;
                if (was_in_service) {
                    if (self.on_node_leave_cb) |cb| {
                        cb(event.node_id);
                    }
                }
                // Unconditional: the transport half of the departure is
                // idempotent (`disconnectNode` ignores an id it does not hold),
                // and a peer that said goodbye twice is no less gone.
                self.bus.disconnectNode(event.node_id);
            } else if (node.state == .suspect or node.state == .failed or node.state == .leaving) {
                // What this recovery has to do about callbacks depends on what
                // was announced when the peer stopped being a member: `failed`
                // and `leaving` are announced through `on_node_leave_cb`, so
                // their return has to be announced through the other half of the
                // pair. `.suspect` announces nothing (nothing is taken out of
                // service), so its recovery announces nothing either — a `join`
                // for a peer the app was never told had gone is a callback with
                // no state to build back.
                const was_announced_absent = node.state != .suspect;
                node.state = .healthy;
                std.log.info("[ClusterMembership] Node {s} is back healthy", .{event.node_id});
                // The callback half of that flip, and the mirror of the two
                // `on_node_leave_cb` calls that wrote the peer off: an app that
                // keeps per-peer state — a connection pool, a shard map, a
                // metrics label — tore it down on `leave`, and without this it
                // would never rebuild it while the census (and the read side fed
                // from it) said the peer was a healthy member. `join` therefore
                // means "this peer is a member you hold state for", not "first
                // time seen": it is announced once per `leave`, for a peer that
                // came back exactly as it is for a peer that just appeared, and a
                // consumer has to treat it as upsert/idempotent (the second half
                // of the pair for the same peer, not a second peer).
                if (was_announced_absent) {
                    if (self.on_node_join_cb) |cb| {
                        cb(event.node_id, node.address);
                    }
                }
                // The connection half of the same flip, and the mirror of the two
                // teardowns that wrote the peer off: `checkNodeHealth` calls
                // `bus.disconnectNode` on the failed transition and the `.leave`
                // branch above does the same. Without a dial here the census —
                // and the read side fed from it (`MembershipView`,
                // `ClusterView.pick`) — said healthy and routed to a peer the
                // bus held no entry for. Idempotent for `.suspect`, which was
                // never disconnected: `connectToNode` returns without a second
                // dial when the id is already tracked.
                //
                // Dialled at `node.address`, the address this membership
                // already holds and publishes for the peer (installed by the
                // join path, handed to the app and the read side with it) — and
                // the address the join callback above carries, so the two agree.
                // The payload-derived `addr` above is loopback + the advertised
                // port, so using it here would throw away a real seed address; a
                // peer that restarted on a new port is dialled at the address we
                // have and stays "tracked for routing, not reachable" until it
                // rejoins under a new id — nothing in this file resolves a
                // gossiped host, so a moved peer was already this unreachable.
                self.bus.connectToNode(event.node_id, node.address) catch |err| {
                    std.log.err("[ClusterMembership] Failed to reconnect event bus to recovered node {s}: {}", .{ event.node_id, err });
                };
            }
        } else {
            self.trackNewNodeLocked(event.node_id, addr, now) catch |err| {
                // Reported, never swallowed — and now one report for *both*
                // allocations on this path (the id copy and the table insert),
                // where the insert used to return in silence. The node stays
                // untracked (its next heartbeat walks this path again, so this is
                // recoverable), and the caller here is the event bus —
                // `onBusEvent` is `void`, so a log is the only channel there is.
                //
                // Named for what it is, because the two things an operator could
                // attribute this drop to are not the same defect: this one is
                // local memory pressure, while a payload that cannot be parsed is
                // rejected earlier, in `onBusEvent`, under the "malformed gossip
                // payload" message. Reading the absence of that message as "the
                // peer sent nonsense" would send whoever is on call after the
                // wrong node.
                std.log.warn("[ClusterMembership] cannot track joining node {s}: local allocation failed ({}), not a malformed event — its next heartbeat retries", .{ event.node_id, err });
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

        if (event.event_type == .leader_election) {
            // The edge, not the level. Every node re-announces the leader it holds
            // on every election round (`checkNodeHealth` and `electLeader` both
            // broadcast), so an event naming the leader this process already
            // recorded is a heartbeat about a fact that has not moved — and a
            // callback fired on it tells a consumer that counts leadership
            // changes, or rebuilds per-leader state (a lock, a lease, a partition
            // map) on each one, something untrue. `onLeaderChange` is named for
            // the edge, and the election branch below
            // (`electLeaderLocked`) already announces on nothing but a change;
            // this makes the two writers of `current_leader` agree.
            //
            // Skipping the copy too, not just the callback: the id the census
            // already holds is the same string, so replacing it would free and
            // re-allocate the owned copy on every round to end up with what we
            // had (`getLeader`'s pointer is stable across a heartbeat).
            const unchanged = self.current_leader != null and
                std.mem.eql(u8, self.current_leader.?, event.node_id);
            if (!unchanged) {
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
    }

    /// Record a node this process has not seen before: the id copy the census
    /// owns plus the insert that takes it, as one fallible step. Called with the
    /// mutex held (`handleGossipEvent`), like `electLeaderLocked`.
    ///
    /// The helper exists so the insert's allocation failure has somewhere to go
    /// at all: `put` only allocates when the table is full, and the branch used
    /// to answer that with a silent return, so the peer was dropped with nothing
    /// on the record. Both allocations mean the same thing to the caller — the
    /// peer stays untracked and its next heartbeat retries — and the one report
    /// for either lives in `handleGossipEvent` (the only caller whose caller,
    /// `onBusEvent`, is `void` and can only log).
    ///
    /// All-or-nothing: a failed insert frees the copy, so the census is exactly
    /// as it was and nothing leaks.
    fn trackNewNodeLocked(self: *Self, node_id: []const u8, addr: std.Io.net.IpAddress, now: i64) std.mem.Allocator.Error!void {
        const id_copy = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(id_copy);

        try self.nodes.put(id_copy, .{
            .id = id_copy,
            .address = addr,
            .state = .healthy,
            .last_seen = now,
            .joined_at = now,
        });
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
    /// that drops an entry.
    ///
    /// When the census is larger than `out`, *which* entries a bounded copy keeps
    /// has to be a choice, and it is made here rather than by hash order: liveness
    /// first — `healthy`, then `suspect`, then `failed`/`leaving` — and ascending
    /// `id` inside each class (`snapshotPrecedes`). The order `out` comes back in
    /// **is** that selection, and three properties follow from it: the same census
    /// always yields the same subset (a bounded view does not flutter as unrelated
    /// peers are discovered), a peer that is down can never displace one that is up
    /// (an arbitrary subset could hand a routing view nothing but dead members),
    /// and one growth step can only evict the highest `id` of a class. Note that
    /// `written == out.len` does not by itself say whether anything was left out —
    /// compare against `getNodeCount()` when that matters (the census only grows,
    /// so the comparison is conservative).
    pub fn nodesSnapshot(self: *Self, out: []ClusterNode) usize {
        // Uncancelable: `0` is a published reading, not a placeholder — this is
        // the snapshot the read side is fed from (`cluster/MembershipView.zig`),
        // so "zero nodes" claims the cluster is empty while it is not, and the
        // publish path that consumes it replaces the whole view. The critical
        // section is a bounded copy.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Bounded insertion sort: `out[0..written]` stays in selection order, so an
        // entry that makes the cut costs at most `out.len` moves and the walk is
        // O(census × out.len) with no allocation.
        var written: usize = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr.*;
            var pos: usize = written;
            while (pos > 0 and snapshotPrecedes(node, out[pos - 1])) : (pos -= 1) {}
            if (pos >= out.len) continue; // weaker than everything already kept
            if (written < out.len) written += 1;
            var j: usize = written - 1;
            while (j > pos) : (j -= 1) {
                out[j] = out[j - 1];
            }
            out[pos] = node;
        }
        return written;
    }

    /// What a bounded `nodesSnapshot` keeps first, and in what order: routing
    /// candidates, then the peer that might come back, then the ones kept only so
    /// an operator can see them. Ascending `id` decides inside a class, so the
    /// selection is a function of the census alone (not of hash order, insertion
    /// history or the map's table size).
    fn snapshotPrecedes(a: ClusterNode, b: ClusterNode) bool {
        const rank_a = snapshotRank(a.state);
        const rank_b = snapshotRank(b.state);
        if (rank_a != rank_b) return rank_a < rank_b;
        return std.mem.lessThan(u8, a.id, b.id);
    }

    fn snapshotRank(state: NodeState) u8 {
        return switch (state) {
            .healthy => 0,
            .suspect => 1,
            .failed, .leaving => 2,
        };
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

    /// Called when a peer becomes a member this process should hold per-peer
    /// state for: a node that just joined, **and** a known node that came back
    /// after being written off (`failed` by the health sweep, or `.leaving` by
    /// its own `.leave`) — see "What `nodes` is" at the top of this file. It is
    /// the other half of `onNodeLeave` and fires exactly once per `leave`, in
    /// that order, with the address this membership holds for the peer; a peer
    /// that only went `.suspect` was never announced as gone, so its recovery
    /// does not fire this either. Treat it as an upsert: the peer may already be
    /// in whatever you keep.
    pub fn onNodeJoin(self: *Self, callback: *const fn ([]const u8, std.Io.net.IpAddress) void) void {
        self.on_node_join_cb = callback;
    }

    /// Called when a peer leaves the set this process should hold state for —
    /// written off by the health sweep, or gone by its own `.leave` (the
    /// `disconnectNode` that comes with both is this file's, not the callback's
    /// job). Announced once per departure, on the transition out of service: a
    /// second `.leave` from a peer that is already `.failed` or `.leaving`
    /// restates a fact the app has acted on and is not announced again, so the
    /// "one `join` per `leave`" pairing holds for a consumer that counts. The
    /// peer's return fires `onNodeJoin` again; the census entry itself is never
    /// removed.
    pub fn onNodeLeave(self: *Self, callback: *const fn ([]const u8) void) void {
        self.on_node_leave_cb = callback;
    }

    /// Called when the leader this process holds **changes** — the edge, not the
    /// level. A `.leader_election` event is also how a leader re-states itself on
    /// every election round, so an event naming the id already recorded (or an
    /// election that re-derives the same winner) is a heartbeat, not a change, and
    /// does not fire this. The argument is this membership's own copy of the
    /// leader id, valid while it holds that leader (it is freed when a different
    /// leader replaces it, or at `deinit`) — and it is optional because the field
    /// is: both call sites in this file pass the copy they just made, right after
    /// installing it, so a callback delivered by this version never sees `null`.
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

// A `.leave` for a node this process has never recorded used to be handled as a
// join first: the unknown-node branch inserted the peer as `.healthy` (join
// callback + `bus.connectToNode`) and only then did the leave branch flip it to
// `.leaving`. Three consequences, all pinned here: the census kept a peer that
// only ever said goodbye (published to the read side as a member), an app got a
// join callback for a node it never had, and we dialled a node that had already
// left. "Nothing is retired" (see "What `nodes` is" at the top) is about peers
// observed *as members* — a goodbye from a stranger is not a membership fact, so
// the census stays as it is. That is also what keeps the peer's *later*, real
// join on the full join path: an entry left behind as `.leaving` would send it
// down the "known node" branch, a state flip with no join callback and no dial.
test "ClusterMembership a leave from an unknown node is not a join" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "leave-stranger");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18230);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-m", addr, &bus);
    defer cluster.deinit();

    const Counters = struct {
        var joins: usize = 0;
        var leaves: usize = 0;

        fn onJoin(_: []const u8, _: std.Io.net.IpAddress) void {
            joins += 1;
        }

        fn onLeave(_: []const u8) void {
            leaves += 1;
        }
    };
    Counters.joins = 0;
    Counters.leaves = 0;
    cluster.onNodeJoin(Counters.onJoin);
    cluster.onNodeLeave(Counters.onLeave);

    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "ghost",
        .host = "127.0.0.1",
        .port = 18231,
        .timestamp = 0,
    });

    // The census is still just this node — nothing to publish that "only ever
    // said goodbye" — and neither callback fired: there was no join to announce
    // and no member to retire.
    try std.testing.expectEqual(@as(usize, 1), cluster.getNodeCount());
    try std.testing.expectEqual(@as(usize, 1), cluster.getHealthyNodeCount());
    try std.testing.expectEqual(@as(usize, 0), Counters.joins);
    try std.testing.expectEqual(@as(usize, 0), Counters.leaves);

    // The peer's real join afterwards takes the join path, callback and bus dial
    // included — the entry the old code left behind would have swallowed both.
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "ghost",
        .host = "127.0.0.1",
        .port = 18231,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), Counters.joins);
    try std.testing.expectEqual(@as(usize, 0), Counters.leaves);
    try std.testing.expectEqual(@as(usize, 2), cluster.getNodeCount());
    try std.testing.expectEqual(ClusterMembership.NodeState.healthy, cluster.nodes.get("ghost").?.state);
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

// `on_leader_change_cb` fired on *every* `.leader_election` gossip event: that
// branch replaced `current_leader` unconditionally and announced the result,
// while the election branch next door (`electLeaderLocked`) announces only when
// the winner differs. Every node re-announces the leader it holds on every
// election round, so a node in a steady cluster heard one "leadership change"
// per round with nothing changing — a consumer that counts leadership changes,
// or rebuilds per-leader state on each one (a lock, a lease, a partition map),
// was being lied to. The callback is named for the edge, so this pins the edge:
// the same id again is a heartbeat.
//
// Red on the old shape: the second event below fired the callback a second
// time, `expected 1, found 2`.
const LeaderLog = struct {
    var calls: usize = 0;
    var last: ?[]const u8 = null;

    fn onLeaderChange(leader: ?[]const u8) void {
        calls += 1;
        last = leader;
    }
};

test "ClusterMembership announces the leader on the edge, not on every election event" {
    const allocator = std.testing.allocator;

    LeaderLog.calls = 0;
    LeaderLog.last = null;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "leader-edge-bus");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18250);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-z", addr, &bus);
    defer cluster.deinit();
    cluster.onLeaderChange(LeaderLog.onLeaderChange);

    // Peers written straight into the table: a gossiped id this process does not
    // hold takes the join path, which dials a socket — not what this test is
    // about.
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

    // The first announcement of a leader this process did not have.
    cluster.handleGossipEvent(.{
        .event_type = .leader_election,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18251,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), LeaderLog.calls);
    try std.testing.expectEqualStrings("node-a", LeaderLog.last.?);
    try std.testing.expectEqualStrings("node-a", cluster.getLeader().?);

    // The same leader again: a heartbeat about a fact that has not moved, and a
    // notification for it is the lie this pins. The reading is unchanged, and the
    // owned copy is not churned either (same pointer, nothing freed and
    // re-copied) — the id the census already holds *is* the string.
    const held = cluster.getLeader().?;
    cluster.handleGossipEvent(.{
        .event_type = .leader_election,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18252,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), LeaderLog.calls);
    try std.testing.expectEqualStrings("node-a", cluster.getLeader().?);
    try std.testing.expectEqual(held.ptr, cluster.getLeader().?.ptr);

    // A different id is an edge, and it is announced.
    cluster.handleGossipEvent(.{
        .event_type = .leader_election,
        .node_id = "node-m",
        .host = "127.0.0.1",
        .port = 18253,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 2), LeaderLog.calls);
    try std.testing.expectEqualStrings("node-m", LeaderLog.last.?);
    try std.testing.expectEqualStrings("node-m", cluster.getLeader().?);
}

// Drive `nodes` to the state where the next `put` has to grow the table.
// `available` is the map's own count of inserts left before a grow, so zero is
// exactly the condition `put` allocates on — and the state an insert's
// allocation is reachable from at all: a table with a free slot answers `put`
// without touching the allocator, which is why the two-entry cluster the first
// report used could not reach that branch. The filler keys come from the
// cluster's allocator, the same one the census frees them with. Returns the next
// unused filler index so a second call after a growth keeps the ids distinct.
fn fillCensusToCapacity(cluster: *ClusterMembership, first_index: usize) !usize {
    var i = first_index;
    while (cluster.nodes.unmanaged.available != 0) : (i += 1) {
        if (i - first_index > 4096) return error.TestUnexpectedResult; // the rule moved
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "filler-{d}", .{i});
        const key = try cluster.allocator.dupe(u8, name);
        try cluster.nodes.put(key, .{
            .id = key,
            .address = cluster.address,
            .state = .healthy,
            .last_seen = 0,
            .joined_at = 0,
        });
    }
    return i;
}

// The join path makes two allocations — the id copy the census will own, then
// the table insert — and only the first one was reported: the `dupe` logged a
// `warn`, the `put` above it returned in silence (`catch { free; return; }`), so
// a node this process could not record was dropped with nothing on the record
// that the cause was *local* (the same event dropped for an unparseable payload
// is rejected earlier, in `onBusEvent`, under its own "malformed gossip payload"
// message — an operator reading only the absence of that message would look at
// the wrong node). `put` only allocates when the table is full, so this drives
// the census there first and then denies exactly the allocation that follows the
// id copy: the growth.
//
// The failure is induced through an allocator the cluster is *built* from, not
// by swapping `cluster.allocator` the way the leader-copy tests next door do:
// `StringHashMap.init` captures the allocator it is handed and the table grows
// through that one, so the map's allocator is a second field
// (`nodes.allocator`) and swapping the first never reaches this branch — which
// is the other half of why the insert's failure looked unreachable.
//
// Two phases, because "which allocation failed" is the whole question: with the
// failure disarmed the same call on the same full table costs exactly two
// allocations (copy, growth), which is the measurement the armed run reads.
// What must hold either way: nothing half-recorded, nothing leaked, and the
// failure arriving at the caller as `error.OutOfMemory` instead of as silence.
test "ClusterMembership reports a join it cannot record instead of dropping it" {
    const allocator = std.testing.allocator;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "track-fail-bus");
    defer bus.deinit();

    var failing = std.testing.FailingAllocator.init(allocator, .{});

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18290);
    var cluster = try ClusterMembership.init(failing.allocator(), std.testing.io, "node-t", addr, &bus);
    defer cluster.deinit();

    var next_filler = try fillCensusToCapacity(&cluster, 0);
    try std.testing.expectEqual(@as(usize, 0), cluster.nodes.unmanaged.available);

    // Phase 1 — the measurement. On a full table the insert is the id copy plus
    // exactly one more allocation, the table growth.
    const census_before = cluster.getNodeCount();
    const allocs_before = failing.alloc_index;
    try cluster.trackNewNodeLocked("node-added", addr, 0);
    try std.testing.expectEqual(allocs_before + 2, failing.alloc_index);
    try std.testing.expectEqual(census_before + 1, cluster.getNodeCount());

    // Fill the grown table up again, then deny the allocation right after the id
    // copy.
    next_filler = try fillCensusToCapacity(&cluster, next_filler);
    try std.testing.expectEqual(@as(usize, 0), cluster.nodes.unmanaged.available);

    const allocs_armed = failing.alloc_index;
    const freed_armed = failing.freed_bytes;
    const census_armed = cluster.getNodeCount();
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, cluster.trackNewNodeLocked("node-rejected", addr, 0));

    // The failure is the growth, not the copy: one allocation succeeded (the
    // copy — `alloc_index` does not advance on the denied one), the denied one
    // was the next, and the copy came back (`freed_bytes` is where a free shows
    // up in this allocator; `allocated_bytes` only ever grows). Nothing
    // half-recorded either: the census is exactly as it was — the second fill
    // above added its own fillers, so the reading to compare against is the one
    // taken just before the armed call — and the id is not in it.
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(allocs_armed + 1, failing.alloc_index);
    try std.testing.expectEqual(freed_armed + "node-rejected".len, failing.freed_bytes);
    try std.testing.expectEqual(census_armed, cluster.getNodeCount());
    try std.testing.expect(!cluster.nodes.contains("node-rejected"));
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
    // rejoin path (the callback pair is what a consumer keeps in step here; it is
    // pinned by "a peer that comes back through the join callback" below).
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

// The connection half of a state flip. `checkNodeHealth` calls
// `bus.disconnectNode` the moment it marks a peer `.failed`, and the `.leave`
// branch disconnects too — but the recovery branch only flipped the state back
// to `.healthy`. The census then said "healthy, route to it" (that is what
// `MembershipView` publishes and `ClusterView.pick` routes on) while the bus
// held no entry for that peer at all: two answers to one question, and the read
// side acts on the census one. This pins the two halves together — fail ⇒
// disconnected, come back ⇒ connected again — and the `.leave` → heartbeat case
// with it.
//
// Red on the old shape: the first bus count after recovery reads
// `expected 1, found 0`.
test "ClusterMembership reconnects a peer that recovers from failed" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "recovery-bus");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18240);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-m", addr, &bus);
    defer cluster.deinit();

    // The peer joins through gossip, which is also what puts it in the bus
    // registry (the dial to the closed port below leaves the entry with
    // `socket == null`, "tracked for routing, not reachable") — so every count
    // from here on is about *that* entry, not about a socket being open.
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18241,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), bus.getNodeCount());

    // Backdated well past `node_timeout_ms` (10s default, doubled for the
    // suspect → failed step), so each health pass advances one state.
    cluster.nodes.getPtr("node-a").?.last_seen = Time.monotonicNowSeconds() - 100;

    cluster.checkNodeHealth();
    try std.testing.expectEqual(ClusterMembership.NodeState.suspect, cluster.nodes.get("node-a").?.state);
    // A suspect peer is not disconnected — the sweep tears the connection down
    // only on the failed transition, so there is nothing to reconnect yet.
    try std.testing.expectEqual(@as(usize, 1), bus.getNodeCount());

    cluster.checkNodeHealth();
    try std.testing.expectEqual(ClusterMembership.NodeState.failed, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 0), bus.getNodeCount());

    // The peer heartbeats again. The state flip and the dial are one decision:
    // a `.healthy` peer the bus holds no entry for is traffic routed at a peer
    // we cannot reach.
    cluster.handleGossipEvent(.{
        .event_type = .heartbeat,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18241,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.healthy, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 1), bus.getNodeCount());

    // Same asymmetry on the `.leave` path: a known peer's goodbye disconnects
    // it and its next heartbeat is the return trip.
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18241,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.leaving, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 0), bus.getNodeCount());

    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18241,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.healthy, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 1), bus.getNodeCount());
}

// The two node callbacks are halves of one lifecycle, and this file fired only
// one of them: the failure sweep and the `.leave` branch announce a peer through
// `on_node_leave_cb` (and disconnect it), while the recovery branch flipped the
// state back and announced nothing. An application that mirrors its peer set
// from these callbacks — a connection pool, a shard map, a metrics label —
// therefore tore the peer down for good while this file's census (and the bus,
// since the recovery branch dials) kept it: the same census/consumer divergence
// the `connectToNode` in that branch fixed one layer down.
//
// The contract pinned here: `leave` is announced exactly for the transitions
// that take a peer out of service, and the next time that peer is a member again
// it is announced through `join` — one `join` per `leave`, in that order, with
// the address this membership holds (the one it dials), not the loopback+port a
// gossip payload carried. A peer that only went `.suspect` was never announced as
// gone, so its recovery is not announced either: an unpaired `join` would have a
// consumer build back state nothing ever tore down.
//
// Red on the old shape: the recovery branch fired no callback, so the sequence
// stopped at `join, leave` — `expected 3, found 2` on the count after the
// heartbeat that brought the peer back.
const NodeCallbackLog = struct {
    const Kind = enum { join, leave };
    const Entry = struct { kind: Kind, id: []const u8, address: std.Io.net.IpAddress };

    var entries: [8]Entry = undefined;
    var len: usize = 0;

    fn reset() void {
        len = 0;
    }

    fn onJoin(id: []const u8, address: std.Io.net.IpAddress) void {
        if (len < entries.len) {
            entries[len] = .{ .kind = .join, .id = id, .address = address };
            len += 1;
        }
    }

    fn onLeave(id: []const u8) void {
        if (len < entries.len) {
            entries[len] = .{ .kind = .leave, .id = id, .address = undefined };
            len += 1;
        }
    }
};

test "ClusterMembership announces a peer that comes back through the join callback" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    NodeCallbackLog.reset();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "pair-bus");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18260);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-p", addr, &bus);
    defer cluster.deinit();
    cluster.onNodeJoin(NodeCallbackLog.onJoin);
    cluster.onNodeLeave(NodeCallbackLog.onLeave);

    // A peer this process has never recorded joins: the first `join`.
    cluster.handleGossipEvent(.{
        .event_type = .join,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18261,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 1), NodeCallbackLog.len);
    try std.testing.expectEqual(NodeCallbackLog.Kind.join, NodeCallbackLog.entries[0].kind);
    const peer_addr = cluster.nodes.get("node-a").?.address;
    try std.testing.expectEqual(peer_addr.ip4.port, NodeCallbackLog.entries[0].address.ip4.port);

    // The health sweep writes it off (two passes: `.healthy` → `.suspect` →
    // `.failed`, the second being where `leave` is announced).
    cluster.nodes.getPtr("node-a").?.last_seen = Time.monotonicNowSeconds() - 100;
    cluster.checkNodeHealth();
    cluster.checkNodeHealth();
    try std.testing.expectEqual(ClusterMembership.NodeState.failed, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 2), NodeCallbackLog.len);
    try std.testing.expectEqual(NodeCallbackLog.Kind.leave, NodeCallbackLog.entries[1].kind);

    // Its own heartbeat is the way back, and the way back is announced: the
    // application that tore the peer down on `leave` has to hear the other half.
    cluster.handleGossipEvent(.{
        .event_type = .heartbeat,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18261,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.healthy, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 3), NodeCallbackLog.len);
    try std.testing.expectEqual(NodeCallbackLog.Kind.join, NodeCallbackLog.entries[2].kind);
    try std.testing.expectEqual(peer_addr.ip4.port, NodeCallbackLog.entries[2].address.ip4.port);

    // A peer that only went `.suspect` was never announced as gone, so its
    // recovery is not announced as a return either.
    cluster.nodes.getPtr("node-a").?.last_seen = Time.monotonicNowSeconds() - 100;
    cluster.checkNodeHealth();
    try std.testing.expectEqual(ClusterMembership.NodeState.suspect, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 3), NodeCallbackLog.len);
    cluster.handleGossipEvent(.{
        .event_type = .heartbeat,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18261,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.healthy, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 3), NodeCallbackLog.len);

    // A known peer saying goodbye is the other way out, and its next heartbeat
    // the other way back: `leave` then `join`, once more.
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18261,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.leaving, cluster.nodes.get("node-a").?.state);
    try std.testing.expectEqual(@as(usize, 4), NodeCallbackLog.len);
    try std.testing.expectEqual(NodeCallbackLog.Kind.leave, NodeCallbackLog.entries[3].kind);

    cluster.handleGossipEvent(.{
        .event_type = .heartbeat,
        .node_id = "node-a",
        .host = "127.0.0.1",
        .port = 18261,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 5), NodeCallbackLog.len);
    try std.testing.expectEqual(NodeCallbackLog.Kind.join, NodeCallbackLog.entries[4].kind);

    // The whole sequence, and every entry is about the one peer.
    const expected = [_]NodeCallbackLog.Kind{ .join, .leave, .join, .leave, .join };
    try std.testing.expectEqual(expected.len, NodeCallbackLog.len);
    for (expected, NodeCallbackLog.entries[0..NodeCallbackLog.len]) |want, got| {
        try std.testing.expectEqual(want, got.kind);
        try std.testing.expectEqualStrings("node-a", got.id);
    }
}

// The departure callback is one half of the pair ("one `join` per `leave`, see
// "What `nodes` is" at the top), and the `.leave` branch fired it on the *state*
// rather than on the transition into it: a peer the health sweep had already
// written off (announced through `leave` there, and disconnected there) that
// then sent its own goodbye was announced a second time, and so was a peer
// whose goodbye had already been handled, on a retransmission. The consumer this
// callback exists for — one that mirrors its peer set from it (a connection
// pool, a shard map, a metrics label) — was told to tear the same peer down
// twice, and the pairing only holds if the second goodbye says nothing new.
//
// Red on the old shape: the first assertion after the failed peer's goodbye read
// `expected 0, found 1`.
test "ClusterMembership announces a departure once, not on every goodbye" {
    const allocator = std.testing.allocator;

    NodeCallbackLog.reset();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "leave-once-bus");
    defer bus.deinit();

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 18270);
    var cluster = try ClusterMembership.init(allocator, std.testing.io, "node-l", addr, &bus);
    defer cluster.deinit();
    cluster.onNodeLeave(NodeCallbackLog.onLeave);

    // Peers written straight into the table in the two states that were *already*
    // announced: `.failed` is what the health sweep leaves behind (it fires
    // `leave` and disconnects in the same branch), `.leaving` is what an earlier
    // goodbye left. Neither is a transition into out-of-service, so neither
    // goodbye is an announcement.
    const written_off = try allocator.dupe(u8, "node-f");
    try cluster.nodes.put(written_off, .{
        .id = written_off,
        .address = addr,
        .state = .failed,
        .last_seen = 0,
        .joined_at = 0,
    });
    const gone = try allocator.dupe(u8, "node-g");
    try cluster.nodes.put(gone, .{
        .id = gone,
        .address = addr,
        .state = .leaving,
        .last_seen = 0,
        .joined_at = 0,
    });

    // A late goodbye from the peer the sweep already wrote off.
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "node-f",
        .host = "127.0.0.1",
        .port = 18271,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.leaving, cluster.nodes.get("node-f").?.state);
    try std.testing.expectEqual(@as(usize, 0), NodeCallbackLog.len);

    // A retransmitted goodbye, and then a third: the first one was the
    // announcement, and the state was already `.leaving` before the pair.
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "node-g",
        .host = "127.0.0.1",
        .port = 18272,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 0), NodeCallbackLog.len);
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "node-g",
        .host = "127.0.0.1",
        .port = 18272,
        .timestamp = 0,
    });
    try std.testing.expectEqual(@as(usize, 0), NodeCallbackLog.len);

    // A peer still in service: its goodbye *is* the transition, so it is
    // announced — once. The suppressed pairs above are the ones with no state
    // left to tear down.
    const up = try allocator.dupe(u8, "node-u");
    try cluster.nodes.put(up, .{
        .id = up,
        .address = addr,
        .state = .healthy,
        .last_seen = 0,
        .joined_at = 0,
    });
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "node-u",
        .host = "127.0.0.1",
        .port = 18273,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.leaving, cluster.nodes.get("node-u").?.state);
    try std.testing.expectEqual(@as(usize, 1), NodeCallbackLog.len);
    try std.testing.expectEqual(NodeCallbackLog.Kind.leave, NodeCallbackLog.entries[0].kind);
    try std.testing.expectEqualStrings("node-u", NodeCallbackLog.entries[0].id);

    // And `.suspect` counts as in service on purpose: the sweep announces the
    // peer only on the `.failed` step, so nothing was torn down for a suspected
    // peer and its goodbye is the announcement, not a repeat of one.
    const shaky = try allocator.dupe(u8, "node-s");
    try cluster.nodes.put(shaky, .{
        .id = shaky,
        .address = addr,
        .state = .suspect,
        .last_seen = 0,
        .joined_at = 0,
    });
    cluster.handleGossipEvent(.{
        .event_type = .leave,
        .node_id = "node-s",
        .host = "127.0.0.1",
        .port = 18274,
        .timestamp = 0,
    });
    try std.testing.expectEqual(ClusterMembership.NodeState.leaving, cluster.nodes.get("node-s").?.state);
    try std.testing.expectEqual(@as(usize, 2), NodeCallbackLog.len);
    try std.testing.expectEqualStrings("node-s", NodeCallbackLog.entries[1].id);
}
