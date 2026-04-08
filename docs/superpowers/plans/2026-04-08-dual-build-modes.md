# Dual Build Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the repository into `air-gapped/` and `goproxy/` folders, providing two independent deployment paths for building the postgres_exporter container image.

**Architecture:** Move all existing files into `air-gapped/`. Create a new `goproxy/` folder with a Dockerfile that fetches Go dependencies via an internal proxy at build time (no vendoring), a build script with `--goproxy` and `--netrc` flags, and a root README explaining both approaches.

**Tech Stack:** Bash, Docker/Podman, Docker BuildKit secrets

**Spec:** `docs/superpowers/specs/2026-04-08-dual-build-modes-design.md`

---

### Task 1: Move existing files into air-gapped/

**Files:**
- Move: `Dockerfile` → `air-gapped/Dockerfile`
- Move: `.dockerignore` → `air-gapped/.dockerignore`
- Move: `scripts/build.sh` → `air-gapped/scripts/build.sh`
- Move: `scripts/download-source.sh` → `air-gapped/scripts/download-source.sh`
- Move: `scripts/vendor-deps.sh` → `air-gapped/scripts/vendor-deps.sh`
- Modify: `.github/workflows/release.yml` — update paths

- [ ] **Step 1: Create air-gapped directory and move files**

```bash
mkdir -p air-gapped/scripts
git mv Dockerfile air-gapped/Dockerfile
git mv .dockerignore air-gapped/.dockerignore
git mv scripts/build.sh air-gapped/scripts/build.sh
git mv scripts/download-source.sh air-gapped/scripts/download-source.sh
git mv scripts/vendor-deps.sh air-gapped/scripts/vendor-deps.sh
rmdir scripts
```

- [ ] **Step 2: Update paths inside air-gapped scripts**

In `air-gapped/scripts/build.sh`, update the `DOCKERFILE` default:
```bash
DOCKERFILE="air-gapped/Dockerfile"
```

In `air-gapped/scripts/build.sh` usage and error messages, update paths from `./scripts/` to `./air-gapped/scripts/`.

In `air-gapped/scripts/vendor-deps.sh` usage examples, update paths from `./scripts/` to `./air-gapped/scripts/`.

In `air-gapped/scripts/download-source.sh` final message, update the "Next step" path to `./air-gapped/scripts/vendor-deps.sh`.

- [ ] **Step 3: Update GitHub Actions workflow**

In `.github/workflows/release.yml`, change:
```yaml
      - name: Download source
        run: ./air-gapped/scripts/download-source.sh --version ${{ env.POSTGRES_EXPORTER_VERSION }}

      - name: Vendor dependencies
        run: ./air-gapped/scripts/vendor-deps.sh
```

And update the build context for `docker/build-push-action`:
```yaml
          file: air-gapped/Dockerfile
```

- [ ] **Step 4: Test the air-gapped flow still works**

```bash
rm -rf src/
bash air-gapped/scripts/download-source.sh --version 0.19.1
bash air-gapped/scripts/vendor-deps.sh
bash air-gapped/scripts/build.sh --version 0.19.1
```

Expected: Image `postgres-exporter:0.19.1-ubi9-amd64` builds successfully.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Move existing files into air-gapped/ directory"
```

---

### Task 2: Create goproxy/Dockerfile

**Files:**
- Create: `goproxy/Dockerfile`

- [ ] **Step 1: Write the Dockerfile**

Two-stage build. Builder downloads deps via GOPROXY. Optional BuildKit secret for `.netrc` auth.

```dockerfile
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
```

- [ ] **Step 2: Commit**

```bash
git add goproxy/Dockerfile
git commit -m "Add goproxy/Dockerfile with GOPROXY and BuildKit secret support"
```

---

### Task 3: Create goproxy/.dockerignore

**Files:**
- Create: `goproxy/.dockerignore`

- [ ] **Step 1: Write .dockerignore**

Same as `air-gapped/.dockerignore` but without the vendor-related comments since vendoring is not used.

```
.git/
.gitignore
.gitattributes
.github/
.gitlab-ci.yml
Jenkinsfile
.circleci/
.tekton/
.vscode/
.idea/
*.swp
*.swo
.DS_Store
Thumbs.db
.build/
dist/
bin/
README.md
docs/
LICENSE*
*.pem
*.key
*.p12
*.pfx
.env
.env.*
secrets/
credentials/
kubeconfig
*.kubeconfig
air-gapped/
goproxy/scripts/
Makefile
docker-compose*.yml
```

- [ ] **Step 2: Commit**

```bash
git add goproxy/.dockerignore
git commit -m "Add goproxy/.dockerignore"
```

---

### Task 4: Create goproxy/scripts/build.sh

**Files:**
- Create: `goproxy/scripts/build.sh`

- [ ] **Step 1: Write the build script**

Based on `air-gapped/scripts/build.sh` with these changes: `--goproxy <url>` required, `--netrc <path>` optional, no `--src-dir`, pre-flight checks `src/go.mod` (not `src/vendor/`), passes `GOPROXY` as build-arg, passes `.netrc` as BuildKit secret.

```bash
#!/usr/bin/env bash
# =============================================================================
#  goproxy/scripts/build.sh — Build helper using internal Go proxy
#
#  Dependencies are downloaded at build time via GOPROXY.
#  No vendoring required — only src/ with source code.
#
#  Prerequisites:
#    - docker or podman
#    - src/ directory with go.mod (run air-gapped/scripts/download-source.sh)
#    - Network access to the internal Go proxy
# =============================================================================
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./goproxy/scripts/build.sh [OPTIONS]

Options:
  --goproxy <url>        Internal Go proxy URL (required)
  --netrc <path>         .netrc file for proxy authentication (optional)
  --version <ver>        postgres_exporter version (default: 0.19.1)
  --arch <arch>          Target architecture: amd64 | arm64 (default: amd64)
  --registry <url>       Registry prefix, e.g. quay.io/myorg
  --push                 Push the image after build
  --scan                 Run Trivy CVE scan after build
  --no-cache             Pass --no-cache to docker build
  --builder-image <ref>  Builder stage base image
  --runtime-image <ref>  Runtime stage base image
  -h | --help            Print this help

Examples:
  ./goproxy/scripts/build.sh --goproxy https://nexus.internal/repository/go-proxy/
  ./goproxy/scripts/build.sh --goproxy https://nexus.internal/repository/go-proxy/ \
                             --netrc ~/.netrc --version 0.19.1
USAGE
  exit 0
}

# ── Defaults ──────────────────────────────────────────────────────────────────
VERSION="0.19.1"
ARCH="amd64"
OS="linux"
REGISTRY=""
IMAGE_NAME="postgres-exporter"
PUSH=false
SCAN=false
NO_CACHE=false
DOCKERFILE="goproxy/Dockerfile"
BUILDER_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest"
RUNTIME_IMAGE="registry.access.redhat.com/ubi9/ubi-micro:latest"
GO_PROXY=""
NETRC_FILE=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --goproxy)       GO_PROXY="$2";      shift 2 ;;
    --netrc)         NETRC_FILE="$2";    shift 2 ;;
    --version)       VERSION="$2";       shift 2 ;;
    --arch)          ARCH="$2";          shift 2 ;;
    --registry)      REGISTRY="$2";      shift 2 ;;
    --push)          PUSH=true;          shift   ;;
    --scan)          SCAN=true;          shift   ;;
    --no-cache)      NO_CACHE=true;      shift   ;;
    --builder-image) BUILDER_IMAGE="$2"; shift 2 ;;
    --runtime-image) RUNTIME_IMAGE="$2"; shift 2 ;;
    -h|--help)       usage ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────
ERRORS=()

if command -v docker &>/dev/null; then
  CONTAINER_RT=docker
elif command -v podman &>/dev/null; then
  CONTAINER_RT=podman
else
  ERRORS+=("'docker' or 'podman' is required but neither was found in PATH.")
fi

if [[ -z "${GO_PROXY}" ]]; then
  ERRORS+=("--goproxy <url> is required.")
fi

if [[ ! -f "${DOCKERFILE}" ]]; then
  ERRORS+=("Dockerfile not found: ${DOCKERFILE}")
fi

if [[ ! -f "src/go.mod" ]]; then
  ERRORS+=("src/go.mod not found.")
  ERRORS+=("  → Run: ./air-gapped/scripts/download-source.sh --version ${VERSION}")
fi

if [[ -n "${NETRC_FILE}" && ! -f "${NETRC_FILE}" ]]; then
  ERRORS+=("netrc file not found: ${NETRC_FILE}")
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "Pre-flight check FAILED" >&2
  echo "──────────────────────────" >&2
  for err in "${ERRORS[@]}"; do
    echo "  ✘ ${err}" >&2
  done
  echo "" >&2
  exit 1
fi

# ── Derived metadata ──────────────────────────────────────────────────────────
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

TAG="${VERSION}-ubi9-${ARCH}"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"
[[ -n "${REGISTRY}" ]] && FULL_IMAGE="${REGISTRY}/${FULL_IMAGE}"

EXTRA_FLAGS=()
[[ "${NO_CACHE}" == "true" ]] && EXTRA_FLAGS+=(--no-cache)

# Pass .netrc as BuildKit secret if provided
SECRET_FLAGS=()
if [[ -n "${NETRC_FILE}" ]]; then
  ABS_NETRC="$(cd "$(dirname "${NETRC_FILE}")" && pwd)/$(basename "${NETRC_FILE}")"
  SECRET_FLAGS=(--secret "id=netrc,src=${ABS_NETRC}")
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "postgres_exporter — goproxy image build"
echo "─────────────────────────────────────────"
printf "  %-16s %s\n" "Dockerfile:"     "${DOCKERFILE}"
printf "  %-16s %s\n" "Image:"          "${FULL_IMAGE}"
printf "  %-16s %s\n" "Version:"        "${VERSION}"
printf "  %-16s %s\n" "Arch:"           "${OS}/${ARCH}"
printf "  %-16s %s\n" "GOPROXY:"        "${GO_PROXY}"
printf "  %-16s %s\n" "Netrc:"          "${NETRC_FILE:-none}"
printf "  %-16s %s\n" "Builder image:"  "${BUILDER_IMAGE}"
printf "  %-16s %s\n" "Runtime image:"  "${RUNTIME_IMAGE}"
printf "  %-16s %s\n" "Build date:"     "${BUILD_DATE}"
printf "  %-16s %s\n" "VCS ref:"        "${VCS_REF}"
printf "  %-16s %s\n" "Push:"           "${PUSH}"
printf "  %-16s %s\n" "CVE scan:"       "${SCAN}"
printf "  %-16s %s\n" "No-cache:"       "${NO_CACHE}"
echo "─────────────────────────────────────────"
echo ""

# ── Build ─────────────────────────────────────────────────────────────────────
DOCKER_BUILDKIT=1 ${CONTAINER_RT} build \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
  ${SECRET_FLAGS[@]+"${SECRET_FLAGS[@]}"} \
  --file="${DOCKERFILE}" \
  --build-arg UBI_MINIMAL_IMAGE="${BUILDER_IMAGE}" \
  --build-arg UBI_MICRO_IMAGE="${RUNTIME_IMAGE}" \
  --build-arg GOPROXY="${GO_PROXY}" \
  --build-arg POSTGRES_EXPORTER_VERSION="${VERSION}" \
  --build-arg TARGETOS="${OS}" \
  --build-arg TARGETARCH="${ARCH}" \
  --build-arg BUILD_DATE="${BUILD_DATE}" \
  --build-arg VCS_REF="${VCS_REF}" \
  --tag="${FULL_IMAGE}" \
  --progress=plain \
  .

echo ""
echo "✔  Build complete: ${FULL_IMAGE}"

# ── Optional: Trivy CVE scan ─────────────────────────────────────────────────
if [[ "${SCAN}" == "true" ]]; then
  echo ""
  echo "── CVE scan (Trivy) ─────────────────────────────────────────"
  if ! command -v trivy &>/dev/null; then
    echo "⚠  trivy not found — skipping scan."
  else
    if trivy image \
      --exit-code 1 \
      --severity HIGH,CRITICAL \
      --ignore-unfixed \
      "${FULL_IMAGE}"; then
      echo "✔  No HIGH/CRITICAL fixable CVEs found."
    else
      echo "✘  HIGH/CRITICAL fixable CVEs detected." >&2
      exit 1
    fi
  fi
fi

# ── Optional: push ────────────────────────────────────────────────────────────
if [[ "${PUSH}" == "true" ]]; then
  echo ""
  if [[ -z "${REGISTRY}" ]]; then
    echo "⚠  --push requires --registry to be set." >&2
    exit 1
  fi
  echo "── Pushing image ────────────────────────────────────────────"
  ${CONTAINER_RT} push "${FULL_IMAGE}"
  echo "✔  Pushed: ${FULL_IMAGE}"
fi

echo ""
echo "Done."
```

- [ ] **Step 2: Make executable**

```bash
chmod 755 goproxy/scripts/build.sh
```

- [ ] **Step 3: Test help output**

```bash
bash goproxy/scripts/build.sh --help
```

Expected: Prints usage with `--goproxy` and `--netrc` flags.

- [ ] **Step 4: Commit**

```bash
git add goproxy/scripts/build.sh
git commit -m "Add goproxy/scripts/build.sh with --goproxy and --netrc support"
```

---

### Task 5: Update root README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite README with both approaches**

The README should cover:
- Overview of both build modes
- Decision guide table (when to use which)
- Quick start for air-gapped (updated paths)
- Quick start for goproxy (new)
- Shared sections: environment variables, health probes, security notes

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Rewrite README for dual build modes (air-gapped + goproxy)"
```

---

### Task 6: End-to-end verification

- [ ] **Step 1: Test air-gapped flow with new paths**

```bash
rm -rf src/
bash air-gapped/scripts/download-source.sh --version 0.19.1
bash air-gapped/scripts/vendor-deps.sh
bash air-gapped/scripts/build.sh --version 0.19.1
```

Expected: Image `postgres-exporter:0.19.1-ubi9-amd64` builds.

- [ ] **Step 2: Test goproxy flow**

```bash
rm -rf src/
bash air-gapped/scripts/download-source.sh --version 0.19.1
bash goproxy/scripts/build.sh --version 0.19.1 \
  --goproxy https://proxy.golang.org,direct
```

Expected: Image `postgres-exporter:0.19.1-ubi9-amd64` builds. Dependencies downloaded at build time via proxy.

- [ ] **Step 3: Verify help flags for all scripts**

```bash
bash air-gapped/scripts/download-source.sh --help
bash air-gapped/scripts/vendor-deps.sh --help
bash air-gapped/scripts/build.sh --help
bash goproxy/scripts/build.sh --help
```

Expected: All print usage and exit 0.

- [ ] **Step 4: Push to GitHub**

```bash
git push origin main
```
