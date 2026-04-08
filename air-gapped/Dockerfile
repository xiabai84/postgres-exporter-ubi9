# =============================================================================
#  postgres_exporter – Multi-Stage Dockerfile (air-gap / disconnected build)
#  Builder : registry.access.redhat.com/ubi9/ubi-minimal
#  Runtime : registry.access.redhat.com/ubi9/ubi-micro
#
#  Target platform : OpenShift 4.x (restricted-v2 SCC)
#
#  PREREQUISITES
#  -------------
#  This Dockerfile requires NO internet access at build time.
#  All source code and Go module dependencies must be present in the
#  repository under src/ before invoking docker build.
#
#  Run scripts/vendor-source.sh once (on an internet-connected machine)
#  to populate src/ and src/vendor/, then commit both to git.
#
#  Build:
#    docker build \
#      --build-arg POSTGRES_EXPORTER_VERSION=0.19.1 \
#      --build-arg TARGETARCH=amd64 \
#      --build-arg VCS_REF=$(git rev-parse --short HEAD) \
#      --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
#      -t postgres-exporter:0.19.1-ubi9 .
#
#  Or use the helper: ./scripts/build.sh --version 0.19.1
#
#  NOTE on base image pinning:
#    For production / regulated environments, override via build-args:
#      --build-arg UBI_MINIMAL_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal@sha256:<digest>
#      --build-arg UBI_MICRO_IMAGE=registry.access.redhat.com/ubi9/ubi-micro@sha256:<digest>
#    Retrieve digests with: skopeo inspect --format '{{.Digest}}' \
#      docker://registry.access.redhat.com/ubi9/ubi-minimal:latest
# =============================================================================

# ── Base image arguments (override to pin digests or use internal mirror) ─────
ARG UBI_MINIMAL_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest
ARG UBI_MICRO_IMAGE=registry.access.redhat.com/ubi9/ubi-micro:latest

# -----------------------------------------------------------------------------
# Stage 1 – BUILDER  (ubi9-minimal)
#
# ubi-minimal provides microdnf and the UBI9 AppStream repository, giving
# access to a Red Hat–supported Go toolchain.  No external network calls are
# made beyond the internal RPM mirror — the source code and all Go module
# dependencies are copied from the repository via COPY.
# -----------------------------------------------------------------------------
FROM ${UBI_MINIMAL_IMAGE} AS builder

# ── Build arguments ───────────────────────────────────────────────────────────
ARG POSTGRES_EXPORTER_VERSION=0.19.1
ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VCS_REF=unknown
ARG BUILD_DATE

# ── Install build-time dependencies ──────────────────────────────────────────
# golang          : Go compiler from UBI9 AppStream (Go 1.21+)
# ca-certificates : TLS trust anchors — the bundle is later copied to the
#                   runtime stage so postgres_exporter can open TLS connections
#                   to PostgreSQL and https:// DSN URIs.
#
# NOT needed (removed vs. internet build):
#   curl / tar / gzip  → source is COPY-ed from the repository
#   git                → VCS metadata is injected via --build-arg, not read
#                        from a .git directory at build time
RUN microdnf install -y \
        golang \
        ca-certificates \
    && microdnf clean all \
    && rm -rf /var/cache/dnf

# ── Go environment — enforce offline build ────────────────────────────────────
# GONOSUMDB=*    : skip the Go checksum database for all modules (no network)
# GOFLAGS        : apply -mod=vendor globally so no go command can fall back
#                  to downloading modules even if -mod=vendor is omitted later
# GONOSUMCHECK=* : belt-and-suspenders; disables sum verification lookups
# GOPROXY=off    : hard-fail if any go command attempts a module download;
#                  makes accidental network calls a build error, not a hang
ENV GONOSUMDB="*" \
    GOFLAGS="-mod=vendor" \
    GONOSUMCHECK="*" \
    GOPROXY="off"

WORKDIR /build

# ── Copy source tree from the repository ─────────────────────────────────────
# src/ must contain the full postgres_exporter source and src/vendor/.
# Run scripts/vendor-source.sh on an internet-connected machine to populate
# src/, then commit it to the repository before running this build.
#
# Expected structure:
#   src/
#   ├── go.mod
#   ├── go.sum
#   ├── vendor/           ← go mod vendor output, committed to git
#   │   └── modules.txt
#   └── cmd/
#       └── postgres_exporter/
COPY src/ /build/

# ── Verify the vendor directory is intact ─────────────────────────────────────
# `go mod verify` checks the module *cache*, not vendor/.  With GOPROXY=off
# and no cache it would attempt network lookups.  Instead, verify that the
# vendor directory exists and contains modules.txt (populated by go mod vendor).
RUN test -f vendor/modules.txt \
    && echo "OK: vendor/modules.txt present ($(grep -c '^# ' vendor/modules.txt) modules)"

# ── Compile a fully static binary ─────────────────────────────────────────────
# CGO_ENABLED=0   → pure-Go binary, zero libc dependency → safe in ubi-micro
# -mod=vendor     → explicitly use src/vendor/ (also set via GOFLAGS above;
#                   stated here for clarity and defence-in-depth)
# -trimpath       → strip build-host filesystem paths from the binary
# -s -w           → omit symbol table + DWARF debug info (smaller binary,
#                   no build-host path leakage)
# LDFLAGS var     → assigned before go build to avoid quoting edge cases in
#                   older shell implementations used by some CI runners
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
      -mod=vendor \
      -trimpath \
      -ldflags="${LDFLAGS}" \
      -o /build/postgres_exporter \
      ./cmd/postgres_exporter

# ── Smoke-test: binary executes + no dynamic library dependencies ─────────────
# `ldd` (from glibc, present in ubi-minimal) prints "=>" for each shared
# library a dynamic binary links.  A static binary produces none — the grep
# inverts that to assert full static linking.
RUN /build/postgres_exporter --version \
    && if ldd /build/postgres_exporter 2>&1 | grep -q "=>"; then \
         echo "ERROR: binary has unexpected dynamic library dependencies:" >&2; \
         ldd /build/postgres_exporter >&2; \
         exit 1; \
       fi \
    && echo "OK: binary is statically linked"

# ── Prepare the unprivileged runtime user ────────────────────────────────────
# ubi-micro has no useradd / groupadd.  We append the entry to the builder's
# /etc/passwd and /etc/group and COPY both files to the runtime stage.
#
# GID 0 (root group) follows the OpenShift arbitrary-UID pattern:
#   - OpenShift restricted-v2 SCC overrides the container UID at runtime with
#     a random value from the project's UID range (e.g. 1000680000).
#   - The GID is NOT overridden — it stays 0.
#   - Files owned by GID 0 with group-read permission remain accessible
#     regardless of which UID is injected.
RUN echo "postgres_exporter:x:65534:0:postgres_exporter:/:/sbin/nologin" \
      >> /etc/passwd \
    && echo "postgres_exporter:x:65534:" \
      >> /etc/group


# -----------------------------------------------------------------------------
# Stage 2 – RUNTIME  (ubi9-micro)
#
# ubi-micro is distroless-style: no shell, no package manager, no compilers,
# no interpreters.  Minimal attack surface; patched by Red Hat.
# The build stage transfers only three artefacts to this stage.
# -----------------------------------------------------------------------------
FROM ${UBI_MICRO_IMAGE}

# Redeclare ARGs so they are in scope for LABEL.
ARG POSTGRES_EXPORTER_VERSION=0.19.1
ARG VCS_REF=unknown
ARG BUILD_DATE

# ── OCI-standard image labels ─────────────────────────────────────────────────
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

# ── Copy only what the runtime needs ─────────────────────────────────────────

# 1. CA certificate bundle – required for TLS connections to PostgreSQL
#    and any https:// DSN URIs passed via DATA_SOURCE_NAME / DATA_SOURCE_URI.
COPY --from=builder /etc/ssl/certs/ca-bundle.crt \
                    /etc/ssl/certs/ca-bundle.crt

# 2. Modified passwd / group files containing the postgres_exporter entry.
#    Prevents "I have no name!" from Go runtime when UID lookup fails.
COPY --from=builder /etc/passwd  /etc/passwd
COPY --from=builder /etc/group   /etc/group

# 3. The fully static binary — no shared libraries required.
COPY --from=builder --chmod=0755 \
     /build/postgres_exporter \
     /usr/local/bin/postgres_exporter

# ── Drop privileges ───────────────────────────────────────────────────────────
# GID 0: OpenShift arbitrary-UID pattern (see builder stage comment).
# Numeric UID:GID ensures runAsNonRoot admission passes even when the runtime
# UID injected by OpenShift is not present in /etc/passwd.
USER 65534:0

# ── Network ───────────────────────────────────────────────────────────────────
EXPOSE 9187

# ── Health probes ─────────────────────────────────────────────────────────────
# Docker HEALTHCHECK is silently ignored by OpenShift / Kubernetes.
# Define livenessProbe / readinessProbe / startupProbe in the Deployment
# manifest (see README.md → "Health Probes").

# ── Entrypoint ────────────────────────────────────────────────────────────────
# Exec form is mandatory: ubi-micro has no /bin/sh.
# Append extra flags as CMD or via the Deployment manifest args field.
ENTRYPOINT ["/usr/local/bin/postgres_exporter"]
