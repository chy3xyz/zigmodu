#!/bin/bash
# ZigModu Distributed Example - Test Script
# Tests the distributed event bus with Docker containers

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== ZigModu Distributed Example Test ==="
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed"
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! command -v docker compose &> /dev/null; then
    echo "ERROR: Docker Compose is not installed"
    exit 1
fi

COMPOSE_CMD="docker compose"
if ! command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
fi

cd "$SCRIPT_DIR"

# Build the Docker images
echo "[1/4] Building Docker images..."
$COMPOSE_CMD build

# Start the cluster
echo "[2/4] Starting 3-node cluster..."
$COMPOSE_CMD up -d

# Wait for all nodes to be healthy
echo "[3/4] Waiting for nodes to be healthy..."
sleep 5

# Check node status
echo ""
echo "=== Cluster Status ==="
$COMPOSE_CMD ps

# Wait for cluster to stabilize
echo ""
echo "[4/4] Waiting for cluster to stabilize..."
sleep 10

# Show logs
echo ""
echo "=== Node Logs ==="
echo "--- Node 1 ---"
$COMPOSE_CMD logs node1 | tail -20
echo ""
echo "--- Node 2 ---"
$COMPOSE_CMD logs node2 | tail -20
echo ""
echo "--- Node 3 ---"
$COMPOSE_CMD logs node3 | tail -20

# Cleanup
echo ""
echo "=== Cleaning up ==="
$COMPOSE_CMD down

echo ""
echo "✅ Distributed test complete!"