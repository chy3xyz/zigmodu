# ─────────────────────────────────────────────────
# ZigModu Production Docker Image
# Multi-stage build: compile in builder, minimal runtime
# ─────────────────────────────────────────────────

# ziglang/zig docker images only ship *releases*; this project pins a dev
# toolchain (same ZIG_VERSION as .github/workflows/ci.yml). Download the
# official arch-first tarball from ziglang.org instead.
FROM alpine:3.21 AS builder
ARG ZIG_VERSION=0.17.0-dev.1970+67f39b551
ARG TARGETARCH

RUN apk add --no-cache curl xz postgresql-dev mariadb-connector-c-dev sqlite-dev

RUN case "$TARGETARCH" in \
      amd64) ART="zig-x86_64-linux" ;; \
      arm64) ART="zig-aarch64-linux" ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH"; exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/builds/$ART-$ZIG_VERSION.tar.xz" -o /tmp/zig.tar.xz && \
    mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig && \
    ln -s "/opt/zig/$ART-$ZIG_VERSION/zig" /usr/local/bin/zig

WORKDIR /zigmodu

# build.zig references these paths directly (module roots + shared db_link).
COPY build.zig build.zig.zon ./
COPY src/ ./src/
COPY tools/ ./tools/
COPY scripts/gen-jwt-token.zig ./scripts/gen-jwt-token.zig
COPY examples/_shared/ ./examples/_shared/
COPY examples/basic/ ./examples/basic/

# Build release (default -Ddb=all: alpine's postgresql-dev /
# mariadb-connector-c-dev / sqlite-dev provide libpq / libmysqlclient /
# libsqlite3 respectively)
RUN zig build -Doptimize=ReleaseSafe

# ─────────────────────────────────────────────────
# Runtime stage — distroless-style minimal image
# ─────────────────────────────────────────────────
FROM alpine:3.21

# Runtime shared libs for the SQL drivers (libpq / libmariadb / libsqlite3).
RUN apk add --no-cache ca-certificates tzdata libpq mariadb-connector-c sqlite-libs && \
    addgroup -S zigmodu && adduser -S zigmodu -G zigmodu

# `zig build` only installs bin/ (no lib/ directory is produced).
COPY --from=builder /zigmodu/zig-out/bin/ /opt/zigmodu/bin/

# Default config directory
RUN mkdir -p /etc/zigmodu /var/log/zigmodu && \
    chown -R zigmodu:zigmodu /etc/zigmodu /var/log/zigmodu

USER zigmodu

EXPOSE 8080
EXPOSE 9091

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/health/live || exit 1

ENTRYPOINT ["/opt/zigmodu/bin/zigmodu-example"]
