# Multi-stage Dockerfile for Financial Trading System (C++ with Python Analytics)
# High-performance containerization for latency-critical trading applications

# Build stage for C++ components
FROM gcc:11-bullseye AS cpp-builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    cmake \
    make \
    libboost-all-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libpq-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy C++ source code
COPY src/cpp/ ./cpp/
COPY CMakeLists.txt ./

# Build C++ trading engine
RUN mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc) && \
    make install

# Python analytics build stage
FROM python:3.11-slim-bullseye AS python-builder

# Install Python build dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy Python requirements
COPY requirements.txt ./
COPY src/python/ ./python/

# Install Python dependencies with optimizations
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    python -m compileall python/

# Production stage
FROM python:3.11-slim-bullseye AS production

# Create non-root user
RUN groupadd -r trader && useradd -r -g trader trader

# Install runtime dependencies and security updates
RUN apt-get update && apt-get install -y \
    libssl1.1 \
    libcurl4 \
    libpq5 \
    curl \
    ca-certificates \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# Create application directory
WORKDIR /app

# Copy C++ binaries
COPY --from=cpp-builder --chown=trader:trader /usr/local/bin/trading-engine ./bin/
COPY --from=cpp-builder --chown=trader:trader /usr/local/lib/libtrading* ./lib/

# Copy Python analytics
COPY --from=python-builder --chown=trader:trader /app/python ./python/
COPY --from=python-builder --chown=trader:trader /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages

# Copy configuration and scripts
COPY --chown=trader:trader config/ ./config/
COPY --chown=trader:trader scripts/ ./scripts/

# Set library path for C++ components
ENV LD_LIBRARY_PATH=/app/lib:$LD_LIBRARY_PATH

# Trading system environment variables
ENV TRADING_ENV=production \
    TRADING_PORT=8082 \
    MARKET_DATA_THREADS=4 \
    ORDER_PROCESSING_THREADS=8 \
    RISK_CHECK_ENABLED=true \
    LATENCY_MONITORING=true

# Performance optimizations
ENV PYTHONOPTIMIZE=2 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Security hardening
RUN chmod -R 750 /app && \
    chmod +x /app/scripts/start.sh

# Health check for trading system
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
    CMD curl -f http://localhost:8082/status || exit 1

# Switch to non-root user
USER trader

# Expose trading system port
EXPOSE 8082

# Start trading system with monitoring
ENTRYPOINT ["/app/scripts/start.sh"]

# Critical system metadata
LABEL maintainer="trading-team@company.com" \
      version="4.5.2" \
      description="Financial Trading System - Ultra Low Latency" \
      application="trading-system" \
      environment="production" \
      criticality="high" \
      compliance.mifid="compliant" \
      latency.requirement="sub-millisecond"
