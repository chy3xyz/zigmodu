# Distributed Systems

This page covers how zmodu's cluster modules behave, what they guarantee and where the boundaries are. Single-process concurrency is covered in [MODULITH.md](../guide/MODULITH.md); a runnable first node is in [CLUSTER-QUICKSTART.md](../guide/CLUSTER-QUICKSTART.md).

## 1. Module status

All modules are ready for single-node development and tests. Multi-node production carries the caveats in §8.

| Module | Tests | Notes |
|--------|:-----:|-------|
| `FailureDetector` | 7 | Phi-accrual detector, adaptive threshold. |
| `KafkaConnector` | 12+ | Kafka TCP produce/fetch + `RecordBatch` parse. Live gate: `ROBUSTMQ_URL` / `KAFKA_BOOTSTRAP`. |
| `GrpcTransport` | 10+ | Unary framing + registry; unary, server, client and bidi streaming; HTTP/1.1 and HTTP/2 packaging. |
| `SagaOrchestrator` | 9 | Auto-compensation with reverse-order rollback. |
| `RaftElection` | 11 | Leader election and vote counting, including split votes. |
| `DistributedTransaction` | 10 | 2PC commit/abort plus a durable coordinator journal (`TransactionJournal.recover`). Participants have no journal (§10). |
| `ClusterMembership` | 4 | Gossip over the bus via `subscribeWithContext`; join/leave/heartbeat converge. |
| `DistributedEventBus` | 22 | Cross-node pub/sub, soft backpressure, authenticated frames (§2). |
| `ClusterView` | 6 | Reference-counted read-side snapshot + rendezvous pick. |
| WAL (eventbus) | 2 | Write-ahead log. |
| DLQ (eventbus) | 3 | Dead-letter queue; expiry and requeue with cooldown. |
| `Partitioner` | 3 | Consistent hash ring. |

Counts are `grep -c '^test '` per file and drift with the code; the code is authoritative. `src/core/cluster/` exports its building blocks flat from `root.zig`: `RaftElection`, `RaftTransport`, `PeerDiscovery`, `LoadBalancer`, `AccrualFailureDetector`. The facade is `ClusterBootstrap`. It assembles those parts and exposes the request-path entry points `pick(key)`, `getView()`, `healthJson(alloc)` and `tick()`; do not assemble a second set.

`ClusterHealth` is a module, not a type: `cluster_health` plus `clusterHealthJson(alloc, cluster)` and `clusterHealthHandler(cluster)`; mounting routes is the application's job. `ClusterSnapshot` (= `ClusterView.Snapshot`) and `ClusterNodeView` (= `MembershipView.Node`) are application-facing aliases; framework code uses the underlying names.

## 2. Bus inbound: frames, identity and replay

The `DistributedEventBus` listener is the cluster-internal face. With any credential configured (`cluster_secret`, `setOwnKey`, `setPeerKey`) every frame is authenticated.

```text
[4-byte BE len][mac: 32][json]
inbound  mac = HMAC(peer_keys[bound_id], json)
outbound mac = HMAC(own_key, json)
```

Identity is pinned by a handshake, not claimed by frames. Every connection runs this before any event frame:

```text
1 receiver -> dialer   [len][rc: 16]                     fresh per connection (randomSecure)
2 dialer   -> receiver [len][dc: 16][claim_id][mac: 32]  mac  = HMAC(own_key, claim_id ++ rc ++ dc)
3 receiver -> dialer   [len][receiver_id][mac2: 32]      mac2 = HMAC(own_key, receiver_id ++ dc)
```

1. The receiver challenges first, so a captured response never replays. Step 3 is mutual proof. MACs are compared in constant time (`ClusterAuth.timingSafeEql`); sign with your own key, verify with the sender's key. In `setPeerKey(id, key)`, `key` is that node's own key.
2. After binding, a frame whose `source` differs from `bound_id` closes the connection. `source_node` becomes a verified fact instead of a claim, so a node holding its own key cannot appear as another node.
3. `"seq"` is mandatory and strictly increasing per bound id; the high-water mark survives reconnects, so captured frames cannot be replayed. Residual: frames never accepted before (sent after a disconnect) replay once. A host reboot rolls the sender's sequence back, and the peer rejects it until `forgetPeerSeq(id)` or a peer restart. Resets are never accepted automatically.
4. Inbound reads have a 30 s idle bound (`inbound_idle_timeout_ms`, 6 × heartbeat interval), applied to freshly dialed sockets too. A silent peer cannot hold a connection or block `stop()`, and a healthy peer is quiet between heartbeats.

Fail-closed covers the whole path, with no downgrade:

- Credentials configured but the peer has no `peer_key` → `error.PeerKeyMissing`, raised before dialing.
- Unknown claim, wrong MAC or replay → close the connection.
- A bare frame on an authenticated port → close. It is a malformed handshake response, not a frame without a MAC.
- With no credentials at all the bus uses the bare-frame path (single node, development; `start()` logs a warning).

Each node pays one extra RTT per connection setup. Connections are one per peer and long-lived (`self.nodes` holds one socket per id; `connectToNode` returns early for registered ids), so the cost lands on join and reconnect only. Each node also has one write lock, so `publish` and `heartbeatLoop` cannot interleave frames on the same socket.

## 3. Raft port: per-node identity

The bus pins identity with a challenge-response handshake. The Raft port is short-lived request/response, where the same shape would add an RTT to every RPC. Instead identity is pinned per frame: request and response frames already carry a self-declared id (`candidate_id`, `leader_id`, `responder_id`) inside the MAC coverage, so verification uses `peer_keys[declared id]` and a forged id fails the MAC. The wire format is unchanged: `[len][tag][payload][mac]`.

```zig
var cluster = try ClusterBootstrap.init(allocator, io, .{
    .node_id = "n1",
    .port = 9000,
    .peers = &.{ "n2@10.0.0.2:9001", "n3@10.0.0.3:9002" },
    .transport = my_transport,
    // Symmetric pre-shared keys: n1's own_key is the key in the peers' peer_keys["n1"].
    .own_key = key_n1,
    .peer_keys = &.{ .{ .id = "n2", .key = key_n2 }, .{ .id = "n3", .key = key_n3 } },
});
```

- Mode selection (`RaftTransport.zig`, file header §A-1): configuring `own_key` or `peer_keys` selects per-node mode and takes precedence over `cluster_secret`; when both are set the shared key is ignored, because falling back would reopen "any key holder impersonates any node". Only `cluster_secret` keeps the existing shared path byte-for-byte: it authenticates frames without binding identity. Neither means bare frames (development; a multi-node start is still refused).
- Sign with your own key, verify with the sender's key. Inbound looks up `peer_keys` by the declared id and rejects missing keys before the L2 membership check; relay responses check the candidate's key too. Synchronous RPC responses carry no id and are verified with the dial target's key.
- Fail-closed without a downgrade: in per-node mode a node without `own_key` rejects inbound connections and drops outbound messages (never bare frames). A peer without a key is dropped before dialing (`TransportImpl.outboundKeys`); Raft retries as a lost message.
- Replay: Raft does not need the bus's `seq`. Monotonic term/index plus idempotent AppendEntries and InstallSnapshot already reject stale traffic. The bus needs `seq` because it has no equivalent of term.
- Scope: these keys govern the Raft port. The bus is a separate listener with its own handshake. Without `cluster_secret`, `ClusterBootstrap` forwards `own_key`/`peer_keys` to the bus as well, so a per-node-key application never ends up with an authenticated Raft port and a bare-frame event port. With `cluster_secret` the bus keeps using it; override afterwards with `getEventBus().?.setOwnKey` / `setPeerKey`.

## 4. Key rotation and revocation

`SecretsManager` remains the source of truth; the framework does not read keys for you. The calls below apply a key change to a running cluster. The wire format stays `[len][tag][payload][mac]`, there is no kid, and a rotation window only changes which keys verify.

The bus (`DistributedEventBus`) and the Raft port (`RaftElection`) expose the same names; `ClusterBootstrap` forwards to both and skips a missing side.

| Operation | Bus | Raft | Bootstrap |
|-----------|-----|------|-----------|
| Replace own signing key | `rotateOwnKey(new)` | same | same (both sides) |
| Rotate a peer key (open a window) | `rotatePeerKey(id, new)` | same | same (both sides) |
| Overwrite and close the window | `setPeerKey(id, key)` | same | same (both sides) |
| Close the window explicitly | `dropPreviousPeerKey(id) bool` | same | same (`true` if either side has it) |
| Revoke | `removePeerKey(id) bool` (also disconnects that id) | `revokePeerKey(id) !bool` (frames/RPC fail closed) | `revokePeerKey(id) !bool` (either side) |

A rotation window accepts two keys: verification tries `current` and then `previous`; signing always uses `current`. That is at most two HMACs per frame inside the window. `rotatePeerKey(id, new)` sets current←new and previous←old current; `setPeerKey` overwrites and clears previous; `dropPreviousPeerKey` closes the window without touching current.

Rotate a peer key (K1→K2) without a partition in three phases:

1. On every other node, `rotatePeerKey("B", K2)`. Old K1 signatures still verify via previous; new K2 signatures are already current.
2. On B, `rotateOwnKey(K2)`. B signs with K2; peers accept K2 as current and in-flight K1 frames via previous.
3. After convergence, call `setPeerKey("B", K2)` or `dropPreviousPeerKey("B")` on each node to stop accepting K1.

Revocation:

- Bus: `removePeerKey` removes the table entry under `peer_keys_lock`, then `disconnectNode(id)` closes registered connections (an in-progress dial is closed by `settleConnect`). Inbound long-lived connections outside the registry are caught by the per-frame lookup: the next frame finds no key and disconnects, and the re-handshake is rejected in `bindInbound`.
- Raft: no long-lived connections to close. RPCs use one short connection each, so inbound frames for that id fail key lookup and outbound RPCs are dropped before dialing.

Fail-closed still holds: a peer without a key is dropped before dialing (`error.PeerKeyMissing`), a node without `own_key` refuses to send or answer, and deleting the last peer key does not downgrade the port to bare frames (`credentials_configured` is sticky).

Runbook:

- Rotate B's key (K1→K2, no partition): fetch K2 from `SecretsManager`; on every other node `bootstrap.rotatePeerKey("B", K2)`; on B `bootstrap.rotateOwnKey(K2)`; after convergence, each node `dropPreviousPeerKey("B")` or `setPeerKey("B", K2)`. Verify that no new verification failures appear per phase. Rollback: `rotateOwnKey(K1)` on B, then `rotatePeerKey("B", K1)` and close the window on the others.
- Key leak: on the remaining nodes `bootstrap.revokePeerKey("B")`, then remove B from `peers` and restart. Do not only edit configuration: the running key table follows runtime calls.
- Process restart: the key table is not persisted. A restart falls back to the configured keys, so close windows only after every node has converged.

Synchronization: Raft inbound (`RaftTransport.handleConnection`, accept thread) verifies before dispatch and deliberately does not hold `RaftLock`; outbound `tick()` looks up keys under `RaftLock`. Rotation therefore uses a dedicated leaf lock, `RaftElection.key_lock`: the read side copies the key by value (`[32]u8`) under the lock, and mutations rebuild the entry under the lock (allocate, swap, free the old slice). Readers never hold a slice pointer, so there is no UAF and no RCU. Lock order is `RaftLock` → `key_lock`; `key_lock` takes no other lock, allocates nothing on the hot path and performs no IO. The bus reuses `peer_keys_lock`, which now also guards `own_key`; a per-frame lookup costs one hash lookup plus a 32–64 byte copy under the lock.

Out of scope: in-frame kid negotiation, control-plane key distribution, and persistence of rotation state.

## 5. Transport encryption boundary

Both cluster faces (Raft port, distributed event bus) are plaintext TCP with per-frame HMAC-SHA256. HMAC gives authentication and integrity, not confidentiality. The authentication helpers live in `core/cluster/ClusterAuth.zig`; there is no TLS transport in the framework.

| Stopped | Mechanism |
|---------|-----------|
| Injected or forged frames | Per-frame HMAC-SHA256; a signer without a key fails. |
| Node impersonation | Bus: challenge-response binds identity. Raft: identity is the per-frame declared id inside MAC coverage. |
| Replay | Bus: `seq` window. Raft: monotonic term/index plus idempotent rejection of stale entries. |
| Key leak response | Runtime rotation (two-key window) or revocation. |

Not stopped: anyone who can read traffic. A passive sniffer sees Raft log entries and event payloads in clear text. That is the design, not an omission.

Why not embed TLS: encryption uses `std.crypto` only, and pulling in a TLS library breaks the zero-dependency rule. Zig's std has no server-side TLS (`std.crypto.tls` is client-only), and writing a TLS stack is out of bounds. If std gains server-side TLS, this decision can be revisited, still using std only.

Production topology: cluster ports belong on a trusted Layer 2 (VPC, private line, localhost). Cross-domain, cross-cloud or public traffic must terminate mTLS in a sidecar or service mesh.

```text
[Same VPC / private line / same host] - direct is allowed
  node A -------- plaintext+HMAC -------- node B

[Cross-domain / public] - sidecar or mesh required
  node A --localhost-- sidecar A === mTLS === sidecar B --localhost-- node B
        +- plaintext+HMAC exists only between a node and its local sidecar -+
```

The last hop (sidecar → node) is still plaintext+HMAC, so the sidecar must share the host or Pod with the node. The same rule applies to the HTTP entry face; see `examples/production-deploy/` for TLS termination in a sidecar with a plaintext backend.

A runnable cluster-face reference lives in `examples/production-deploy/cluster-sidecar/`: a 3-node cluster plus an nginx stream sidecar with mutual mTLS and an iptables plaintext block. `./run.sh` starts everything and asserts that plaintext bypass is refused, a certificate-less peer is refused, and election plus mesh work.

`ClusterBootstrap.start()`'s `ClusterAuthRequired` gate guarantees authentication, not confidentiality. `.allow_unauthenticated_cluster = true` explicitly accepts a bare cluster for development. Monitoring, audit and compliance must not read "cluster auth enabled" as "cluster traffic encrypted".

## 6. Concurrency budget exhaustion (A-8)

`std.Io.ConcurrentError` is `error{ConcurrencyUnavailable}`. The framework handles it in seven places with two shapes.

`Io.Threaded` returns `error.ConcurrencyUnavailable` when `busy_count >= concurrent_limit`, and maps OOM to it too. `concurrent_limit` defaults to `.unlimited`. The loops use `Group.concurrent`, not `Group.async`, and that is load-bearing: `async` falls back eagerly on reaching the limit and runs the task body on the caller thread, while `busy_count` only drops when the body returns. A loop that never returns would pin `start()` or the accept thread forever. `concurrent` has no eager path and reports the limit instead.

| Shape | Locations | Semantics |
|-------|-----------|-----------|
| Startup: dispatch failure = `start()` failure | `core/DistributedEventBus.zig` (accept/heartbeat/dlq), `extensions/WebSocket.zig` (`acceptLoop`, `WebSocketMonitor.updateLoop`) | `abortStart` rolls back (reset flags, close listeners, drain the group, warn) and the error propagates to the caller of `start()`. |
| Connection: dispatch failure = reject this connection | `api/Server.zig`, `core/DistributedEventBus.zig`, `extensions/WebSocket.zig`, `core/cluster/NetworkTransport.zig` | Warn, close the connection, `continue`; the accept loop survives. |

Test boundary:

- `std.testing.io` is a default `Io.Threaded`: the repo runner and the std simple runner only set `argv0`/`environ`, so `concurrent_limit` stays `.unlimited`. Tests on `testing.io` can never reach this branch; that is the fixed shape of the test io, not a coverage gap.
- The three startup sites have dedicated tests using a bounded `Io.Threaded` (`.concurrent_limit = .nothing` / `.limited(1)`), asserting `error.ConcurrencyUnavailable`, a clean rollback and an immediately rebindable port.
- The WebSocket connection site is executed incidentally by the monitor test but not asserted. The `Server`, event-bus and `NetworkTransport` connection sites have no tests; they are writable with bounded io and a real client. Transient exhaustion under production io (`.unlimited` or a large limit) is not covered: tests pin the budget at 0 or 1.

Both shapes log a warning. Startup failures surface at deploy time; a rejected connection kills one connection while the loop keeps serving. `Io.Threaded` defaults to `.unlimited`, so hitting this in production means host thread resources are already exhausted; failing loudly is the right end state.

This conclusion changes if `testing.io` or the repo runner sets a non-default `concurrent_limit`, if the three connection sites gain tests, or if std changes `ConcurrentError` semantics.

## 7. ClusterBootstrap: read side and Raft transport

`ClusterView` is the read side: reference-counted snapshots plus rendezvous selection. The request path reads the view, never the membership hash map. `src/cluster/MembershipView.zig` is the publisher:

```text
gossip / health (ClusterMembership, write side) -> sync() -> ClusterView.publish() -> request path
        mutex-protected hash map                  snapshot+format     ref-counted slots   acquire / pick
```

### 7.1 Bootstrapping and the request path

```zig
// ClusterBootstrap is the facade. It owns the view, membership, raft and metrics.
// A single node must set raft_cluster_size = 1: Config defaults to 3 and the
// built-in Raft transport is a stub, so start() would refuse (see §8).
// For multi-node, each `.peers` entry is "<id>@<host>:<port>", e.g.
// "n2@10.0.0.2:9001". The `@<id>` is the node's own node_id and is mandatory:
// without it `id` falls back to the host and start() returns
// error.PeerIdRequired (that cluster can never elect a leader).
var cluster = try ClusterBootstrap.init(allocator, io, .{
    .node_id = "n1",
    .port = 9000,
    .peers = &.{},
    .raft_cluster_size = 1,
});
defer cluster.deinit();
try cluster.start();

// Both loops are externally driven. tick() does all three steps:
try cluster.tick();                       // gossip/health + refresh read side + raft.tick()

// Request path one: rendezvous pick (one call, no acquire/release)
const node = cluster.pick(order_id) orelse return error.NoHealthyNode;

// Request path two: the whole snapshot (member listing, custom failover)
const view = cluster.getView();
const snap = view.acquire();
defer view.release(snap);
const backup = view.pickRanked(order_id, 1);

// Operations: health report (facade over ClusterHealth.healthJson; caller frees)
const json = try cluster.healthJson(allocator);
defer allocator.free(json);               // mount at /cluster/health or a scrape hook
```

- `error.ReadersBusy` from `tick()` is not a failure: a request is reading, the view keeps the previous generation and the next tick publishes again.
- To drive `tick()` from a runtime timer: `_ = try worker.after(1000, .tick);`.
- Nodes in `suspect` state are excluded from `pick` but stay in the snapshot for operators.
- Do not route request traffic through `LoadBalancer`. Its source is `PeerDiscovery`'s service-name → peers mapping (with canary and least-connections state), which is a different fact from member id → address + health. Mirroring the view into discovery every tick adds state and allocation and loses the zero-allocation steady state of `sync()`. Use `PeerDiscovery` + `LoadBalancer` for service-name outbound balancing and `ClusterBootstrap` for membership and the read side.

Known limit (cross-host discovery): gossip carries peer hosts but the receiver has no resolver, so discovered nodes are recorded as `127.0.0.1` plus their advertised port (`ClusterMembership.handleGossipEvent`). Discovery works on the same host or a shared container network; cross-host requires an explicit seed (`connectToSeed` with a real address).

### 7.2 Transport contract

`src/core/cluster/RaftTransport.zig` supplies the wiring (`TransportImpl(N)` for outbound sync/async, `handleConnection` + `InboundServer` for inbound dispatch and same-connection replies, `AddressBook`). Vote responses travel back through inbound. The table below is both what `RaftTransport` does for you and what a custom transport must implement.

| Direction | Building block | Requirement |
|-----------|----------------|-------------|
| Outbound vote | `NetworkTransport.connect(host, port)` → `ClusterConnection.send(payload)` | `sendVoteRequest` returns `void` (fire-and-forget): encode `VoteRequest` and send to each peer; responses arrive inbound. |
| Outbound replication | same | `sendAppendEntries` is synchronous: send, then read `AppendEntriesResponse` on the same connection. `sendInstallSnapshot` follows the same model. |
| Inbound dispatch | `ClusterBootstrap.start()` wires this when `.transport` is set; otherwise use `ClusterServer.start(handler, context)` or `RaftTransport.InboundServer` | Decode, call `RaftElection.handleVoteRequest` / `handleAppendEntries` / `handleVoteResponse` / `handleInstallSnapshot`, encode the result and reply on the same connection. The `append_entries_response` and `install_snapshot_response` tags are not consumed inbound; the sender already read the response synchronously. |
| Address book | `ClusterBootstrap` builds it from `config.peers` (`RaftTransport.AddressBook`, key = the id before `@`, matching `raft.addPeer(p.id)`) | Map peer id → `host:port`. `BootstrapConfig.peers` is the only source today. |
| Failure semantics | yours | Raft tolerates loss and retries: `AppendEntriesResponse{ .success = false }` is a normal response, and a failed connection is a lost message. Do not declare the node dead; that is `AccrualFailureDetector`'s job. |

Inbound runs one fiber per connection: `ClusterServer` hands each accepted connection to a `std.Io.Group` task, and the handler gets its owner from `start(handler, context)`. `rpc_timeout_ms` bounds how long one peer can occupy its handler, not whether later peers must wait. `stop()` joins these fibers; they hold the raft state and address book.

`max_append_entries` is read in both directions. Outbound batches by it; inbound clamps to the first N entries rather than rejecting (rejecting requires matching config on both sides and would strand a follower; clamping costs one extra round and self-heals). The reply's `match_index` is what was actually applied, so the leader advances `next_index` from it. The decoder has a hard cap, `RaftTransport.MAX_ENTRIES_PER_FRAME` (4096): frames declaring more are dropped before allocation, so keep `max_append_entries` below it.

Facade guarantees:

- `RaftElection.tick()` always gets called: `ClusterBootstrap.tick()` runs `runOnce()` → `view.sync()` → `raft.tick()`.
- Inbound is wired: with `.transport`, `start()` listens on `port`, dispatches votes and replication through `RaftTransport.handleConnection`, replies on the same connection and closes it in `stop()`. A failed bind returns `error.RaftInboundListenFailed`; without `.transport`, multi-node startup fails closed.
- Peer id and address are separate facts. `start()` calls `raft.addPeer(p.id)` and puts `host:port` in the address book; vote response push-back looks up the address by `candidate_id`, so both sides agree. A missing `@id` falls back to the host, and `start()` rejects multi-node clusters with `error.PeerIdRequired`: Raft counts votes only for `raft.peers[].id`, while nodes announce `node_id`, so votes could never reach a quorum.
- One `RaftElection` is serialized by `RaftElection.RaftLock`, a three-tier lock (`cmpxchgWeak` fast path, bounded spin, then `poll` sleep), because `tick()` and inbound dispatch on the accept thread both mutate `voted_for`, `log`, `next_index` and `match_index`. Every public entry that touches shared state takes it (`tick`, `handleVoteRequest`, `handleAppendEntries`, `handleVoteResponse`, `handleInstallSnapshot`, `handleInstallSnapshotResponse`, `appendEntry`, `addPeer`, `compactLog`, state accessors). Private step functions assume the lock; `deliverStagedRound` assumes it is not held. The facade holds no lock. The lock window covers decode → dispatch → encode's `handle*`; socket reads, replies and push-back happen outside it. Nodes without `.transport` have no accept thread, so the lock costs one predictable branch.
- `getRaft()` returns a raw pointer and carries a contract instead of a lock: one driver thread per `RaftElection`. `tick()` and `handle*` take the lock individually, but a caller driving it from another thread must synchronize itself (same thread, or wrap the whole atomic sequence in `raft.lock`). Accessors are single reads, not transactions; `getLogEntry().command` and `getLeader()` return borrowed slices valid only until the next call. `stop()` destroys the object; `deinit()` does not synchronize.

Two startup gates besides the transport gate: multi-node with a real transport but no credentials (`cluster_secret`, `own_key`/`peer_keys` all empty) → `error.ClusterAuthRequired`, unless `.allow_unauthenticated_cluster = true`; a `peers` entry without `@id` → `error.PeerIdRequired`.

### 7.3 Outbound IO and the lock

`tick()` is one `flushOutgoing()`: take lock → stage → release → deliver → take lock → apply. An atomic `flush_active` gate keeps it single-flight; a concurrent call (tick thread and post-election resend from `handleVoteResponse`) returns, and `heartbeat_owed` records the skipped heartbeat for the next round.

```text
stage  (locked, stageLeaderRoundLocked): decide the round and build self-contained requests
       (buffers are cleared first, so a round that stages nothing sends nothing)
deliver (unlocked, deliverStagedRound): perform IO, fill response slots in the staged items
apply  (locked, applyStagedRoundLocked): apply responses with validation
```

Three obligations, each with a concrete landing point:

1. Staged requests must be self-contained. `AppendEntriesRequest.entries` borrows `self.log`, and `LogEntry.command` is heap memory freed by `truncateLog`. Once the lock is released, inbound `handleAppendEntries` can truncate the log and hand those bytes back, so the transport would read freed memory. The stage step copies each `entry.command` with `arena.dupe` into `outbound_arena` (`reset(.retain_capacity)`, zero allocation in steady state); snapshot bytes are copied once per round and shared across peers. Heartbeat rounds have no entries and copy nothing.
2. The apply step must verify the response belongs to this round. Between stages another thread can raise `current_term`, demote us to follower or re-elect us. The stage step records `round_term`; apply requires `state == .leader and current_term == round_term` per item, otherwise the whole batch is dropped. A higher-term response is the exception: the term half always applies (demote immediately, drop the rest), because that is Raft's step-down rule.
3. `next_index` and `match_index` are read and written only under the lock and never carried across stages. All production writes happen in `becomeLeader`, `stageLeaderRoundLocked`, `applyStagedRoundLocked` and `processInstallSnapshotResponse` (called from apply or from the locked `handleInstallSnapshotResponse`). The deliver step neither reads nor writes them.

Related changes: `becomeLeader` only sets `heartbeat_owed = true` instead of sending heartbeats; `startElection` stages `staged_vote` + `staged_peers` instead of calling `sendVoteRequest`; `flushOutgoing()` is the single path, invoked by `tick()` and after `handleVoteResponse` releases the lock (a failure there logs `std.log.err` and the next tick covers it). Inbound dispatch is unchanged.

Guards: `a round in flight reads staged bytes while the log is truncated under it` (blocks `sendAppendEntries` while another thread truncates, asserts the request still reads valid bytes; removing the deep copy fails it) and `a reply that lands after the term moved is dropped, not applied` (removing the term/state guard advances `next_index` from a stale reply).

`rpc_timeout_ms` (default 100 ms) bounds a reply wait via `sockread.setRecvTimeout`, covering peers that accept and never answer. Outbound dials use `RaftTransport.connectTimeout(io, addr, timeout_ms)` (raw socket, `O_NONBLOCK`, `poll(POLLOUT)`, monotonic deadline, `getsockopt(SO_ERROR)`), returning `error.ConnectTimeout`; `timeout_ms = 0` means unbounded. The bound is POSIX-only; Windows falls back to unbounded. The `IpAddress.ConnectOptions.timeout` field is a trap: `std.Io.Threaded.netConnectIpPosix` panics on non-`.none` values in the pinned toolchain.

### 7.4 Log compaction (Raft §7, InstallSnapshot)

`log` holds only live entries after the snapshot boundary. Absolute index `i` lives at `log.items[i - last_included_index - 1]`, and `log.items.len` is a count, not the last index. Conversions are centralized in `lastLogIndex` / `lastLogTerm` / `termAt`; append, prev checks, conflict truncation, commit advance, vote completeness and batch construction all work in absolute coordinates.

Follower prev checks have three branches: prev on the boundary compares `last_included_term` and rejects without truncation (the snapshot is committed history); prev inside the boundary is an implicit match, guaranteed by leader completeness, and snapshot-covered entries are skipped; prev outside the boundary compares live entries and truncates on conflict, never into the snapshot.

Compaction entry points:

- Manual: `raft.compactLog(up_to_index, snapshot_bytes)`. The boundary must be committed: `up_to_index > commit_index` returns `error.NotCommitted`, because folding uncommitted entries into a snapshot would make a minority's uncommitted state survivable. `up_to_index <= last_included_index` is a no-op.
- Automatic: `ElectionConfig.snapshot_threshold_entries` (default `0` = off). Each `tick()` checks `log.items.len > threshold` and compacts to `commit_index` (`maybeCompactLog`); hook and OOM errors only log and never break the election loop. It runs in every role, so follower logs no longer grow without bound; follower `commit_index` is advanced by `leader_commit`, so the boundary never crosses it. `BootstrapConfig` forwards `snapshot_threshold_entries`, `snapshotter`, `snapshotter_ctx` and `snapshot_chunk_bytes`.
- Snapshot bytes: `ElectionConfig.snapshotter`, `*const fn (ctx: ?*anyopaque, up_to_index: u64, allocator) anyerror![]u8`, called under the lock, so keep it cheap; the returned slice is freed by raft. Without a hook the framework stores a placeholder digest (`zigmodu-raft-snapshot:v1:last_included_index=…:last_included_term=…:compacted_entries=…`) that cannot restore application state. Real snapshots need a hook plus a follower-side consumer of `snapshot_data`.
- Leader → lagging follower: when `next_index[peer] <= last_included_index` the round sends InstallSnapshot, chunked by `snapshot_chunk_bytes` (default 16 KiB, clamped to 65535 for the u16 wire prefix). The response is consumed synchronously; on success `match_index[peer] = last_included_index` and `next_index[peer] = last_included_index + 1`, returning to AppendEntries next round. A higher term demotes immediately. Asynchronous transports call `handleInstallSnapshotResponse(resp, from_peer, last_included_index)`; a mismatched boundary is stale, so only the term half applies.
- Follower assembly: chunks are keyed by `(last_included_index, last_included_term)`, and `offset` must equal the assembled length, otherwise the chunk is dropped and the leader retransmits (idempotent). Only the `done` frame applies. Applying keeps the log suffix that continues the snapshot (boundary entry present with the same term → drop only the covered prefix, otherwise clear) and advances `commit_index` / `last_applied` with `@max`.
- Snapshot sending uses the same three-stage split: bytes are copied into `outbound_arena` during the stage step and chunks are sent unlocked. `snapshot_chunk_bytes` is a wire/format knob, not a lock-hold trade-off. Intermediate chunk responses only record the term; `match_index` advances on the `done` frame. Proactive follower-side compaction is not implemented.

## 8. Production deployment checklist

Single node: all modules are ready.

Multi-node (3–7 nodes):

1. `ClusterMembership` — gossip converges via `DistributedEventBus.subscribeWithContext`.
2. `DistributedEventBus` — cross-node pub/sub with soft backpressure.
3. `RaftElection` + `RaftTransport` + `ClusterBootstrap` — votes count per peer to quorum; outbound is `RaftTransport.TransportImpl(N)`; `ClusterBootstrap` wires the inbound listener and `raft.tick()`. `raft_cluster_size > 1` refuses to start without a real `.transport` (`error.RaftTransportUnavailable`) unless `.allow_stub_raft_transport = true`.
4. `SagaOrchestrator` — compensation workflows.
5. `DistributedTransaction` — 2PC with a durable coordinator journal; participants hold no journal (§10).
6. `KafkaConnector` — Kafka wire client for RobustMQ (`initWithIo`, default `127.0.0.1:9092`).
7. WAL/DLQ — durability layer for the event bus.

Rolling upgrades are a hard cut with no negotiation. Nodes from v0.32.x or earlier send bare frames, which authenticated nodes reject by design: during a mixed run the old nodes cannot win an election or join membership. Evidence and harness: `src/cluster_node.zig` + `scripts/ci-mixed-version.sh` (three-node election/replication at one version, plus v0.32.0 ↔ master interop).

Platform boundary: the cluster transport (`src/core/sockread.zig`, `RaftTransport` frame writes) is POSIX-only (raw `posix.read`, `send(MSG_NOSIGNAL)`, `sendmsg`). Linux and macOS work; the cluster face does not compile on Windows, so the windows-cross CI gate skips `cluster-node`. Windows portability is a separate work item.

## 9. RobustMQ producer

```zig
var producer = zmodu.KafkaProducer.initWithIo(allocator, io, .{
    .bootstrap_servers = "127.0.0.1:9092", // RobustMQ Kafka listener
    .client_id = "my-app",
});
defer producer.deinit();
try producer.send(.{
    .topic = "orders",
    .key = null,
    .value = payload,
    .headers = &.{},
    .timestamp = zmodu.time.monotonicNowSeconds(),
});
```

Live smoke test: `ROBUSTMQ_URL=127.0.0.1:9092 zig build test`

## 10. 2PC durable coordinator journal

The coordinator is the only role that knows the outcome. After voting YES and before receiving commit/abort, participants are in doubt. With in-memory coordinator state only, a crash erases that knowledge and participants wait forever. `TransactionJournal` is the append-only coordinator log: decisions are persisted before they are executed.

```zig
var journal = zmodu.TransactionJournal.initWithBackend(allocator, backend); // data.SqlxBackend
defer journal.deinit();
try journal.migrate();                        // CREATE TABLE IF NOT EXISTS zigmodu_tx_journal

var tpc = zmodu.TwoPhaseCommit.init(allocator);
defer tpc.deinit();
tpc.setJournal(&journal);                     // unset = in-memory coordinator (old behavior)

try tpc.createCoordinator("tx-1");
try tpc.addParticipant("tx-1", "orders", prepareOrder, commitOrder, rollbackOrder);
if (try tpc.preparePhase("tx-1")) {           // all YES: prepared is persisted first
    // Crash window: disk says prepared, no terminal state; recover() reports it.
    try tpc.commitPhase("tx-1");
} else {
    try tpc.abortPhase("tx-1");               // aborted is persisted before rollback
}

// New process after a crash: report only, no decisions
const in_doubt = try tpc.recover(allocator);
defer zmodu.TransactionJournal.freeInDoubt(allocator, in_doubt);
for (in_doubt) |tx| { /* tx.tx_id / tx.participants / tx.updated_at */ }
```

`execute()` still runs both phases in one call. Callers that need the crash window use the three-step form.

Table: `zigmodu_tx_journal(tx_id VARCHAR(191), state VARCHAR(16), participants TEXT, updated_at BIGINT)`. One row per transition (`begun`, `prepared`, `committed`, `aborted`), INSERT only, never UPDATE, so a crash loses at most the last record. DDL is dialect-neutral (no `AUTOINCREMENT`, no indexes) and writes go through the `data` seam (`data.SqlxBackend`); core does not import drivers.

Write points: `createCoordinator` / `addParticipant` write `begun` with the full participant list; all YES writes `prepared` before any participant is told to commit; all acks writes `committed`. A NO or `abortPhase` writes `aborted` before rolling back. With a journal configured, decisions are fail-closed: if a decision cannot be persisted, the coordinator does not proceed.

`recover` reports, it does not decide. It returns transactions that are `prepared` without `committed`/`aborted` (`tx_id`, participant ids, `updated_at`). It does not retry, roll back, time out or ask participants what they did. Policy belongs to the caller: re-register callbacks by id and call `commitPhase`, or roll back per business rules. Callbacks are not persisted.

Boundaries:

- No participant-side journal. `recover` tells you who is in doubt; it cannot make your commit retries idempotent. Participant prepare and commit must stay replayable.
- A crash during rollback after `aborted` is written leaves the decision on disk but no per-participant rollback record; replaying rollback is not implemented.
- The table is append-only and has no GC; retention and cleanup are yours.
- `updated_at` uses `core/Time` monotonic seconds (comparable across processes on one host, not across restarts), not wall clock.

## 11. ClusterView read side

The write side (`ClusterMembership`, `FailureDetector`, `PeerDiscovery`) is the maintenance loop's state: gossip arrival, heartbeat loss, state flips. Request handlers must not read it. It is a mutable hash map owned by that loop, and locking it is the wrong trade: data changes every few seconds, requests arrive in microseconds.

```zig
var view = zmodu.ClusterView(64, 4).init(allocator);
defer view.deinit();

// Maintenance loop (single writer): publish the whole snapshot.
// Readers see either the old or the new set, never half of one.
try view.publish(&.{ .{ .id = "node-a", .address = "10.0.0.1:8080" }, ... });

// Request path: ref-counted snapshot, lock-free
const snap = view.acquire();
defer view.release(snap);
const owner = view.pick(key) orelse return error.NoHealthyNode;   // rendezvous hash
const backup = view.pickRanked(key, 1);                           // failover
```

Reclamation uses reference counting, not a generational ring alone: a slow reader can still hit a slot the writer has wrapped around to. `acquire()` returns a counted snapshot, `release()` returns it, and the writer waits for that slot's readers to reach zero before reusing it. If they do not drain, `publish` returns `error.ReadersBusy` instead of overwriting live data. Publishing is a seconds-scale maintenance activity; reading is microsecond-scale. Waiting is the cheap direction.

`pick` uses rendezvous hashing (`hash(key ‖ id)`, maximum wins), not the consistent hash ring in `core/eventbus/Partitioner.zig`. The ring needs rebuilding on every membership change and locking to read; rendezvous is stateless and lock-free, and still migrates only the keys owned by a changed member. The ring remains for batch writes on the event bus.

Deliberately out of scope:

- No new protocol: membership propagation and heartbeats use the existing `NetworkTransport` and gossip message format.
- No cross-node consistency: strong-consistency orchestration still belongs in PostgreSQL.
- `RaftElection` remains experimental (not wired into service discovery). Coordinator decisions are durable (§10), but `recover` only reports and participants have no journal. Snapshot `weight` is present but unused by `pick`, reserved to avoid a format change later.
