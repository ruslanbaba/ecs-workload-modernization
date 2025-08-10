# Multi-stage Dockerfile for CRM System (Java Spring Boot)
# Optimized for enterprise-level production deployment

# Build stage
FROM openjdk:17-jdk-alpine AS builder

# Set working directory
WORKDIR /app

# Install build dependencies
RUN apk add --no-cache maven

# Copy dependency files first for better caching
COPY pom.xml .
COPY src/main/resources/application.properties src/main/resources/

# Download dependencies
RUN mvn dependency:go-offline -B

# Copy source code
COPY src/ src/

# Build application
RUN mvn clean package -DskipTests=true && \
    mkdir -p target/dependency && \
    cd target/dependency && \
    jar -xf ../*.jar

# Production stage
FROM openjdk:17-jre-alpine AS production

# Create non-root user for security
RUN addgroup -g 1001 appuser && \
    adduser -D -s /bin/sh -u 1001 -G appuser appuser

# Install security updates and required packages
RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
    ca-certificates \
    curl \
    tzdata && \
    rm -rf /var/cache/apk/*

# Set timezone
ENV TZ=UTC

# Create application directory
WORKDIR /app

# Copy JAR dependencies
COPY --from=builder --chown=appuser:appuser /app/target/dependency/BOOT-INF/lib lib
COPY --from=builder --chown=appuser:appuser /app/target/dependency/META-INF META-INF
COPY --from=builder --chown=appuser:appuser /app/target/dependency/BOOT-INF/classes .

# Set security-hardened JVM options
ENV JAVA_OPTS="-server \
    -XX:+UseG1GC \
    -XX:+UseStringDeduplication \
    -XX:+OptimizeStringConcat \
    -XX:+UseCompressedOops \
    -XX:+UseCompressedClassPointers \
    -Xms512m \
    -Xmx2048m \
    -XX:MetaspaceSize=256m \
    -XX:MaxMetaspaceSize=512m \
    -XX:+HeapDumpOnOutOfMemoryError \
    -XX:HeapDumpPath=/tmp \
    -Djava.security.egd=file:/dev/./urandom \
    -Dspring.profiles.active=production \
    -Dfile.encoding=UTF-8"

# Health check configuration
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Switch to non-root user
USER appuser

# Expose application port
EXPOSE 8080

# Application startup
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -cp app:lib/* com.company.crm.CrmApplication"]

# Metadata labels for enterprise compliance
LABEL maintainer="platform-engineering@company.com" \
      version="2.1.0" \
      description="CRM System - Modernized Legacy Application" \
      application="crm-system" \
      environment="production" \
      security.scan="enabled" \
      compliance.gdpr="compliant"
