# =============================================================================
#  postgres_exporter – Single-Stage Dockerfile (GoProxy build on ubi-minimal)
#
#  Uses ubi-minimal for both compilation and runtime.
#  Go toolchain is installed, source is compiled, then Go is removed —
#  all in a single RUN layer to keep the image small.
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

FROM ${UBI_MINIMAL_IMAGE}

ARG POSTGRES_EXPORTER_VERSION=0.19.1
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VCS_REF=unknown
ARG BUILD_DATE
ARG GOPROXY

# ── OCI-standard image labels ────────────────────────────────────────────────
LABEL maintainer="The Prometheus Authors <prometheus-developers@googlegroups.com>" \
      org.opencontainers.image.title="postgres_exporter" \
      org.opencontainers.image.description="Prometheus exporter for PostgreSQL server metrics" \
      org.opencontainers.image.version="${POSTGRES_EXPORTER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/prometheus-community/postgres_exporter" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Prometheus Community" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/ubi-minimal"

WORKDIR /build

# ── Copy source ──────────────────────────────────────────────────────────────
COPY src/ /build/

# ── Install Go, compile, clean up — all in one layer ─────────────────────────
# Everything happens in a single RUN so that the Go toolchain, gcc, and build
# artifacts never persist in a layer. Only the static binary and ca-certs remain.
RUN --mount=type=secret,id=netrc,target=/root/.netrc \
    set -eu; \
    microdnf install -y golang ca-certificates; \
    microdnf clean all; \
    GOPROXY="${GOPROXY}" go mod download; \
    go mod verify; \
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
      ./cmd/postgres_exporter; \
    /build/postgres_exporter --version; \
    cp /build/postgres_exporter /usr/local/bin/postgres_exporter; \
    chmod 0755 /usr/local/bin/postgres_exporter; \
    rm -rf /build /root/go /tmp/*; \
    rm -rf /usr/lib/golang /usr/lib64/golang /usr/bin/go /usr/bin/gofmt; \
    rm -rf /usr/lib/gcc /usr/libexec/gcc /usr/bin/gcc /usr/bin/g++ /usr/bin/c++ /usr/bin/cc /usr/bin/cpp; \
    rm -rf /usr/lib64/libgo* /usr/lib64/libasan* /usr/lib64/libubsan*; \
    rm -rf /usr/include /usr/share/doc /usr/share/man /usr/share/info; \
    rm -rf /var/cache/dnf

# ── Create unprivileged user ──────────────────────────────────────────────────
RUN echo "postgres_exporter:x:65534:0:postgres_exporter:/:/sbin/nologin" \
      >> /etc/passwd \
    && echo "postgres_exporter:x:65534:" \
      >> /etc/group

USER 65534:0
EXPOSE 9187
ENTRYPOINT ["/usr/local/bin/postgres_exporter"]
