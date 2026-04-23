# ZigModu Distributed Example Dockerfile
#
# This Dockerfile creates a minimal image for running the distributed example.
# Due to Zig cross-compilation complexities, the recommended approach is:
#
# OPTION 1: Build locally and copy binary
#   # On macOS/Linux with Zig 0.16.0 installed:
#   cd examples/distributed
#   zig build -Dtarget=x86_64-linux-musl
#   docker build -t zigmodu-distributed .
#   docker run --rm -e NODE_ID=node1 -e PORT=9000 zigmodu-distributed
#
# OPTION 2: Use the pre-built binary on macOS (native)
#   cd examples/distributed
#   zig build
#   ./zig-out/bin/distributed-example
#
# The distributed example demonstrates:
# - DistributedEventBus structure
# - Multi-node cluster configuration
# - Event publishing and subscription
#
# Note: Network functionality is currently disabled due to Zig 0.16.0 stdlib
# API differences. The example demonstrates the architecture and can be
# extended once the network APIs are fixed.

FROM alpine:3.19

# Install ca-certificates for HTTPS
RUN apk add --no-cache ca-certificates

# Copy the pre-built binary
COPY distributed-example /usr/local/bin/

# Set default environment variables
ENV NODE_ID=node1
ENV PORT=9000

# Expose ports for node communication
EXPOSE 9000-9010

# Run the example
ENTRYPOINT ["distributed-example"]