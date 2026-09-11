# Build a ZigModu app into a small runtime image.
#
# The example apps depend on zigmodu via `.path = "../.."`, so the build
# CONTEXT must be the repository root and this Dockerfile is referenced
# explicitly:
#
#   docker build -f examples/production-deploy/Dockerfile \
#                --build-arg APP=examples/basic -t zigmodu-api .
#
# Pinned to the same Zig the framework CI locks (see .github/workflows/ci.yml).

FROM debian:bookworm-slim AS build

ARG ZIG_VERSION=0.17.0-dev.1970+67f39b551
ARG APP=examples/basic

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) zarch=x86_64 ;; \
      arm64) zarch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/builds/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /src
COPY . .

# Driver selection lives in each app's build.zig (`.db = "sqlite"` for the
# bundled examples — see docs/SQLX_DRIVERS.md); do not pass -Ddb here unless the
# app declares that option.
RUN cd "${APP}" && zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim AS runtime

ARG APP=examples/basic
RUN apt-get update && apt-get install -y --no-install-recommends \
      libsqlite3-0 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home zigmodu

WORKDIR /app
COPY --from=build /src/${APP}/zig-out/bin/ /app/bin/

USER zigmodu
EXPOSE 8080

# Wired by the orchestrator:
#   HTTP_MAX_CONNECTIONS / HTTP_HEADER_TIMEOUT_MS / WS_WRITE_TIMEOUT_MS / JWT_SECRET
ENV HTTP_PORT=8080 \
    HTTP_MAX_CONNECTIONS=4096 \
    HTTP_HEADER_TIMEOUT_MS=10000 \
    WS_WRITE_TIMEOUT_MS=10000

HEALTHCHECK --interval=10s --timeout=2s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${HTTP_PORT}/health/live" || exit 1

ENTRYPOINT ["/app/bin/basic-example"]
