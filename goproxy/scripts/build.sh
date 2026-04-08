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
