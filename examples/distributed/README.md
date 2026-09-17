# Distributed Example

This example demonstrates **one** distributed building block: `DistributedEventBus`,
the cross-node pub/sub transport.

## Scope

| Item | Status in this example |
|------|------------------------|
| `DistributedEventBus` | Used: `init` → `subscribe("order", …)` → `start(port)` → `getNodeCount()` |
| Node id / port | Hard-coded (`node1`, `9000`) — the demo does **not** read `NODE_ID` / `PORT` |
| Cluster membership | Not used — no discovery, no heartbeats, no gossip in `src/main.zig` |
| Leader election | Not used — `RaftElection` is a framework module, not wired here |
| Read side (`ClusterView`) | Not used |

The cluster stack (membership, election, `ClusterView` read path, deployment
checklist) lives in the framework and is documented in
[`docs/DISTRIBUTED.md`](../../docs/DISTRIBUTED.md). This example is the
smallest thing that exercises the bus, not a cluster you can run.

## Multi-node topology — and why it does not start

The compose-only demo that used to sit next to this one advertised a 3-node
cluster while its containers built the repo-root `Dockerfile` — i.e. they ran
`examples/basic`, with no cluster binary and no `/cluster/health` route to curl.
That directory is gone; this section keeps the only part of it worth keeping,
the topology:

```
  node1:9001 ──gossip── node2:9002
       │                    │
       └────gossip── node3:9003

  Each node runs: ClusterBootstrap (DistributedEventBus + Membership + Raft + Metrics)
```

**Start with more than one node is fail-closed.** `ClusterBootstrap`'s built-in
Raft transport is a stub (`sendVoteRequest` is an empty function,
`sendAppendEntries` always returns `false`), so `raft_cluster_size > 1` makes
`start()` return `error.RaftTransportUnavailable` instead of electing a leader
nobody voted for (`docs/DISTRIBUTED.md`, section on the fail-closed multi-node
start — the English summary of the same rule is under *Multi-node* in its
production checklist). Two supported ways out:

1. supply a real `.transport` (`RaftElection.ElectionTransport`; v0.23.0 ships
   `src/core/cluster/RaftTransport.zig` with `TransportImpl(N)`), or
2. `.allow_stub_raft_transport = true` — explicitly run membership + the read
   side only (single node uses `raft_cluster_size = 1`).

So leader election across nodes is **not available today**; what is real is
membership plus the read path (`MembershipView` / `ClusterView` with
`acquire` / `release` / `pick`), which the framework documents and exercises in
its own tests. Nothing in `examples/` mounts a cluster HTTP API, so there is no
`/cluster/health` endpoint to curl from a demo.

For a running Docker topology (gateway + TLS sidecar + backed-up backend
replicas, probes, k8s/systemd units), see
[`examples/production-deploy/`](../production-deploy/) — that is the deploy
reference this directory's compose files were meant to grow into.

## Prerequisites

- Zig 0.17

## Quick Start

```bash
cd examples/distributed
zig build run     # or: zig build && ./zig-out/bin/distributed-example
```

Expected output:

```
info: === ZigModu Distributed Example ===
info: Node configuration:
info:   Node ID: node1
info:   Port: 9000
info: Initializing DistributedEventBus...
info: Starting event bus listener on port 9000...
info: [DistributedEventBus] Node 'node1' listening on port 9000
info: [node1] Node startup complete
info: Created test event:            # order_id 12345, amount 99.99, ...
info: Event bus state:
info:   Subscribed topics: order
info:   Connected nodes: 0
info: [node1] Demo complete - event bus initialized and listening
```

The process prints the state and exits. `Connected nodes: 0` is expected — a
second process would have to connect to the port to make it non-zero.

## What the code does

1. `DistributedEventBus.init(allocator, io, "node1")`;
2. `subscribe("order", handler)` — a topic subscription, invoked for events that
   arrive over the network;
3. `start(9000)` — binds the TCP listener;
4. prints `getNodeCount()` and exits.

Publishing is not part of the demo because there is no peer to receive it; the
bus API (`publish`, quarantine on send failure, WAL/DLQ) is covered by the
framework's own tests.

## Docker files

`Dockerfile`, `docker-compose.yml`, and `test_distributed.sh` are kept as a
deployment scaffold. They start three containers of **this same demo**, so all
three print `node1` / port `9000` — the compose `environment:` entries
(`NODE_ID`, `PORT`) are not read by the code. Treat them as a starting point for
your own multi-node wiring, not as a working cluster.

## Files

```
distributed/
├── build.zig              # Build configuration
├── build.zig.zon          # Package manifest
├── Dockerfile             # Docker image definition (scaffold)
├── docker-compose.yml     # 3-container definition (scaffold)
├── test_distributed.sh    # Docker smoke script (scaffold)
├── README.md              # This file
└── src/
    └── main.zig           # DistributedEventBus demo
```
