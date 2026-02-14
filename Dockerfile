# Build stage
FROM swift:6.0-noble AS builder

WORKDIR /build

COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY Benchmarks ./Benchmarks

RUN swift build -c release --static-swift-stdlib --product cok-server
RUN swift build -c release --static-swift-stdlib --product cok

# Server runtime
FROM ubuntu:24.04 AS server

RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/.build/release/cok-server /app/cok-server

ENV COK_HTTP_PORT=8080
ENV COK_WS_PORT=8081
ENV COK_DOMAIN=localhost
ENV COK_MAX_TUNNELS=1000
ENV COK_API_KEY_SECRET=change-me-in-production

EXPOSE 8080 8081

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/cok-server"]

# Client runtime
FROM ubuntu:24.04 AS client

RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/.build/release/cok /app/cok

ENV COK_SERVER_URL=ws://localhost:8081
ENV COK_LOCAL_PORT=3000

ENTRYPOINT ["/app/cok"]
