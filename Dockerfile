# Multi-stage build for leanpoint (linux/amd64, linux/arm64)

# Stage 1: Build stage
FROM alpine:latest AS builder

# TARGETARCH is set by docker buildx (amd64 or arm64)
ARG TARGETARCH
ARG ZIG_VERSION=0.14.1

# Install build dependencies
RUN apk add --no-cache \
    curl \
    xz \
    bash \
    nodejs \
    npm

# Install Zig 0.14.1 for the target architecture
RUN case "$TARGETARCH" in \
    amd64) ZIG_ARCH=x86_64 ;; \
    arm64) ZIG_ARCH=aarch64 ;; \
    *) echo "Unsupported TARGETARCH: $TARGETARCH"; exit 1 ;; \
    esac && \
    curl -L -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" && \
    tar -xJf /tmp/zig.tar.xz -C /usr/local && \
    ln -s "/usr/local/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

# Set working directory
WORKDIR /build

# Copy source files
COPY build.zig build.zig.zon ./
COPY src/ ./src/

# Build the backend
RUN zig build -Doptimize=ReleaseSafe

# Copy and build frontend
COPY web/ ./web/
COPY Makefile ./
RUN cd web && npm ci && npm run build

# Stage 2: Runtime stage
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    libgcc \
    libstdc++

# Create non-root user
RUN addgroup -g 1000 leanpoint && \
    adduser -D -u 1000 -G leanpoint leanpoint

# Create directories
RUN mkdir -p /etc/leanpoint /var/lib/leanpoint /usr/share/leanpoint/web && \
    chown -R leanpoint:leanpoint /etc/leanpoint /var/lib/leanpoint /usr/share/leanpoint

# Copy binary from builder
COPY --from=builder /build/zig-out/bin/leanpoint /usr/local/bin/leanpoint

# Copy web UI from builder
COPY --from=builder /build/web-dist/ /usr/share/leanpoint/web/

# Copy example config
COPY upstreams.example.json /etc/leanpoint/upstreams.example.json

# Switch to non-root user
USER leanpoint

# Expose port
EXPOSE 5555

# Set working directory
WORKDIR /var/lib/leanpoint

# Default command - serve with web UI
CMD ["leanpoint", "--upstreams-config", "/etc/leanpoint/upstreams.json", "--static-dir", "/usr/share/leanpoint/web"]
