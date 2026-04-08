# =============================================================================
#  postgres_exporter – Multi-Stage Dockerfile (GoProxy build)
#  Builder : registry.access.redhat.com/ubi9/ubi-minimal
#  Runtime : registry.access.redhat.com/ubi9/ubi-micro
#
#  This Dockerfile downloads Go dependencies at build time via GOPROXY.
#  It requires network access to the internal Go proxy during build.
#
#  Build:
#    docker build \
#      --build-arg GOPROXY=https://nexus.internal/repository/go-proxy/ \
#      --build-arg POSTGRES_EXPORTER_VERSION=0.19.1 \
#      -t postgres-exporter:0.19.1-ubi9 .
#
#  With proxy authentication:
#    docker build \
#      --secret id=netrc,src=$HOME/.netrc \
#      --build-arg GOPROXY=https://nexus.internal/repository/go-proxy/ \
#      -t postgres-exporter:0.19.1-ubi9 .
# =============================================================================

# syntax=docker/dockerfile:1

ARG UBI_MINIMAL_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
ARG UBI_MICRO_IMAGE=registry.access.redhat.com/ubi9/ubi-micro:latest

# -----------------------------------------------------------------------------
# Stage 1 – BUILDER
# -----------------------------------------------------------------------------
FROM ${UBI_MINIMAL_IMAGE} AS builder

ARG POSTGRES_EXPORTER_VERSION=0.19.1
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VCS_REF=unknown
ARG BUILD_DATE
ARG GOPROXY

RUN microdnf install -y \
        golang \
        ca-certificates \
    && microdnf clean all \
    && rm -rf /var/cache/dnf

WORKDIR /build

COPY src/ /build/

# Download dependencies via internal Go proxy.
# --mount=type=secret mounts .netrc for proxy authentication if provided.
# The secret is never written into image layers.
RUN --mount=type=secret,id=netrc,target=/root/.netrc \
    GOPROXY="${GOPROXY}" \
    go mod download \
    && go mod verify

# Compile a fully static binary.
RUN set -eu; \
    RESOLVED_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; \
    LDFLAGS="-s -w \
      -X github.com/prometheus/common/version.Version=${POSTGRES_EXPORTER_VERSION} \
      -X github.com/prometheus/common/version.Revision=${VCS_REF} \
      -X github.com/prometheus/common/version.Branch=release \
      -X github.com/prometheus/common/version.BuildUser=dockerfile \
      -X github.com/prometheus/common/version.BuildDate=${RESOLVED_DATE}"; \
    CGO_ENABLED=0 \
    GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -ldflags="${LDFLAGS}" \
      -o /build/postgres_exporter \
      ./cmd/postgres_exporter

RUN /build/postgres_exporter --version \
    && if ldd /build/postgres_exporter 2>&1 | grep -q "=>"; then \
         echo "ERROR: binary has unexpected dynamic library dependencies:" >&2; \
         ldd /build/postgres_exporter >&2; \
         exit 1; \
       fi \
    && echo "OK: binary is statically linked"

RUN echo "postgres_exporter:x:65534:0:postgres_exporter:/:/sbin/nologin" \
      >> /etc/passwd \
    && echo "postgres_exporter:x:65534:" \
      >> /etc/group

# -----------------------------------------------------------------------------
# Stage 2 – RUNTIME
# -----------------------------------------------------------------------------
FROM ${UBI_MICRO_IMAGE}

ARG POSTGRES_EXPORTER_VERSION=0.19.1
ARG VCS_REF=unknown
ARG BUILD_DATE

LABEL maintainer="The Prometheus Authors <prometheus-developers@googlegroups.com>" \
      org.opencontainers.image.title="postgres_exporter" \
      org.opencontainers.image.description="Prometheus exporter for PostgreSQL server metrics" \
      org.opencontainers.image.version="${POSTGRES_EXPORTER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/prometheus-community/postgres_exporter" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Prometheus Community" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/ubi-micro"

COPY --from=builder /etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group
COPY --from=builder --chmod=0755 /build/postgres_exporter /usr/local/bin/postgres_exporter

USER 65534:0
EXPOSE 9187
ENTRYPOINT ["/usr/local/bin/postgres_exporter"]
