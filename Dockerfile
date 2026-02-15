# Build stage
FROM swift:6.0-noble AS builder

WORKDIR /build

COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY Benchmarks ./Benchmarks

RUN swift build -c release --static-swift-stdlib --product cok-server
RUN swift build -c release --static-swift-stdlib --product cok

# Server runtime - Ubuntu 24.04 Slim (matches build environment glibc)
FROM ubuntu:24.04 AS server

# Install minimal dependencies and clean up thoroughly  
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean \
    && rm -rf /tmp/* /var/tmp/*

WORKDIR /app

COPY --from=builder /build/.build/release/cok-server /app/cok-server

ENV HTTP_PORT=8080
ENV WS_PORT=8081
ENV BASE_DOMAIN=localhost
ENV MAX_TUNNELS=1000
ENV API_KEY_SECRET=change-me-in-production

EXPOSE 8080 8081

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/cok-server"]

# Client runtime - Ubuntu 24.04 Slim
FROM ubuntu:24.04 AS client

# Install minimal dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

WORKDIR /app

COPY --from=builder /build/.build/release/cok /app/cok

ENV COK_SERVER_URL=ws://localhost:8081
ENV COK_SUBDOMAIN=
ENV COK_API_KEY=
ENV COK_LOCAL_PORT=3000

ENTRYPOINT ["/app/cok"]
