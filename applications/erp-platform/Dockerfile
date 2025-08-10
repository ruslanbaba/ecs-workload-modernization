# Multi-stage Dockerfile for ERP Platform (.NET Framework)
# Enterprise-grade containerization with security hardening

# Build stage
FROM mcr.microsoft.com/dotnet/sdk:6.0-alpine AS builder

# Set working directory
WORKDIR /app

# Install security updates
RUN apk update && apk upgrade && \
    apk add --no-cache git

# Copy project files
COPY *.csproj ./
COPY *.sln ./

# Restore dependencies
RUN dotnet restore --no-cache

# Copy source code
COPY . ./

# Build application
RUN dotnet publish -c Release -o out --no-restore

# Production stage
FROM mcr.microsoft.com/dotnet/aspnet:6.0-alpine AS production

# Create non-root user
RUN addgroup -g 1001 dotnetuser && \
    adduser -D -s /bin/sh -u 1001 -G dotnetuser dotnetuser

# Install security updates and monitoring tools
RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
    ca-certificates \
    curl \
    icu-libs \
    tzdata && \
    rm -rf /var/cache/apk/*

# Set timezone and locale
ENV TZ=UTC \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8

# Create application directory
WORKDIR /app

# Copy application files
COPY --from=builder --chown=dotnetuser:dotnetuser /app/out .

# Set ASP.NET Core environment variables
ENV ASPNETCORE_ENVIRONMENT=Production \
    ASPNETCORE_URLS=http://+:8081 \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_ENABLE_DUMPS=1 \
    DOTNET_DUMP_PATH=/tmp

# Configure logging
ENV Logging__LogLevel__Default=Information \
    Logging__LogLevel__Microsoft=Warning \
    Logging__LogLevel__System=Warning

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8081/api/health || exit 1

# Switch to non-root user
USER dotnetuser

# Expose application port
EXPOSE 8081

# Application startup
ENTRYPOINT ["dotnet", "ERPPlatform.dll"]

# Enterprise metadata
LABEL maintainer="platform-engineering@company.com" \
      version="3.2.1" \
      description="ERP Platform - Legacy System Modernization" \
      application="erp-platform" \
      environment="production" \
      framework=".NET 6.0" \
      compliance.sox="compliant"
