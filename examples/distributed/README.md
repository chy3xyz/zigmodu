# Distributed Example

This example demonstrates ZigModu's distributed capabilities with multi-node cluster support.

## Features Demonstrated

- **DistributedEventBus** - Cross-node event communication via TCP
- **ClusterMembership** - Node discovery, health tracking, and leader election
- **Event Subscription** - Topic-based pub/sub pattern
- **Cluster Configuration** - Multi-node setup via environment variables
- **Heartbeat** - Periodic health checks between nodes
- **Connection Handling** - Accepting and managing incoming connections

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Node 1    │────▶│   Node 2    │────▶│   Node 3    │
│  Port 9000  │◀────│  Port 9001 │◀────│  Port 9002  │
└─────────────┘     └─────────────┘     └─────────────┘
```

## Prerequisites

- Zig 0.16.0
- Docker (for containerized deployment)

## Quick Start

### Local Development

```bash
# Build the example
cd examples/distributed
zig build

# Run the example
./zig-out/bin/distributed-example
```

The example will start a single node (node1) listening on port 9000.

### Docker Deployment

Due to Zig cross-compilation complexity, the recommended approach is:

```bash
# Build locally for Linux first
cd examples/distributed
zig build -Dtarget=x86_64-linux-musl

# Then build Docker image
docker build -t zigmodu-distributed .

# Run with Docker
docker run --rm -e NODE_ID=node1 -p 9000:9000 zigmodu-distributed
```

### Multi-Node Docker Cluster

To test with multiple nodes using Docker Compose:

```bash
cd examples/distributed

# Build images
docker compose build

# Start cluster
docker compose up -d

# View logs
docker compose logs -f

# Stop
docker compose down
```

## How It Works

### Node Startup

1. Each node initializes a `DistributedEventBus` with a unique node ID
2. Nodes subscribe to topics (e.g., "order")
3. Nodes listen on their assigned ports for incoming connections
4. Nodes connect to seed nodes to join the cluster

### Event Publishing

When an event is published:
1. The event is serialized with a timestamp
2. It's broadcast to all connected peers
3. Peers forward to their peers (gossip protocol)
4. All connected nodes receive the event on subscribed topics

### Heartbeat

Each node periodically sends heartbeats to connected peers to indicate liveness. If a peer fails to respond, it's marked as suspect and eventually removed from the cluster.

### Demo Output

```
info: === ZigModu Distributed Example ===
info: This demonstrates a distributed node configuration
info: Node configuration:
info:   Node ID: node1
info:   Port: 9000
info: Initializing DistributedEventBus...
info: Starting event bus listener on port 9000...
info: [DistributedEventBus] Node 'node1' listening on port 9000
info: [node1] Event bus listening on port 9000
info: [node1] Node startup complete
info: Event bus state:
info:   Subscribed topics: order
info:   Connected nodes: 0
info: [node1] Demo complete - event bus initialized and listening
info: To test distributed communication, run multiple nodes with docker-compose
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE_ID` | node1 | Unique identifier for this node |
| `PORT` | 9000 | Port for incoming connections |

## Files

```
distributed/
├── build.zig              # Build configuration
├── build.zig.zon         # Package manifest
├── Dockerfile             # Docker image definition
├── docker-compose.yml     # 3-node cluster definition
├── test_distributed.sh    # Automated test script
├── README.md              # This file
└── src/
    └── main.zig           # Distributed example application
```

## Already Implemented Features

ZigModu includes these resilience and observability features:

| Feature | File | Tests |
|---------|------|-------|
| ClusterMembership | `src/core/ClusterMembership.zig` | 9 passing |
| DistributedTracer | `src/tracing/DistributedTracer.zig` | 4 passing |
| CircuitBreaker | `src/resilience/CircuitBreaker.zig` | 2 passing |

## Completed TODO Items

- [x] Fix network I/O APIs for Zig 0.16.0 compatibility ✅
- [x] Enable TCP listener and connection handling ✅
- [x] Implement heartbeat between nodes ✅
- [x] Add cluster membership discovery ✅
- [x] Implement leader election ✅
- [x] Add distributed tracing with OpenTelemetry ✅
- [x] Configure circuit breakers for resilient communication ✅