#!/usr/bin/env bash
# =============================================================================
#  build.sh — Build helper for the postgres_exporter container image
#
#  This script operates fully offline.  All source code and Go dependencies
#  must already be present in src/ (run scripts/vendor-source.sh first).
#
#  Usage:
#    ./build.sh [OPTIONS]
#
#  Options:
#    --version  <ver>   postgres_exporter version embedded in image labels
#                       and binary metadata (default: 0.19.1).
#                       Must match the version in src/go.mod.
#    --arch     <arch>  Target CPU architecture: amd64 | arm64 (default: amd64)
#    --registry <url>   Registry prefix, e.g. quay.io/myorg (default: none)
#    --src-dir  <path>  Path to vendored source directory   (default: ./src)
#    --push             Push the image after a successful build
#    --scan             Run a Trivy CVE scan after the build
#    --no-cache         Pass --no-cache to docker build (base layers re-pulled
#                       from the internal registry mirror)
#    --file     <path>  Path to Dockerfile                 (default: ./Dockerfile)
#    -h | --help        Print this help
#
#  Examples:
#    ./build.sh
#    ./build.sh --version 0.19.1 --arch arm64
#    ./build.sh --registry quay.io/myorg --push --scan
# =============================================================================
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./air-gapped/scripts/build.sh [OPTIONS]

Options:
  --version  <ver>   postgres_exporter version (default: 0.19.1)
  --arch     <arch>  Target architecture: amd64 | arm64 (default: amd64)
  --registry <url>   Registry prefix, e.g. quay.io/myorg
  --src-dir  <path>  Path to vendored source directory (default: ./src)
  --push             Push the image after build
  --scan             Run Trivy CVE scan after build
  --no-cache         Pass --no-cache to docker build
  --file     <path>  Path to Dockerfile (default: ./Dockerfile)
  --builder-image <ref> Builder base image (default: registry.access.redhat.com/ubi9/ubi-minimal:latest)
  --runtime-image <ref> Runtime base image (default: registry.access.redhat.com/ubi9/ubi-micro:latest)
  -h | --help        Print this help

Examples:
  ./air-gapped/scripts/build.sh
  ./air-gapped/scripts/build.sh --version 0.19.1 --arch arm64
  ./air-gapped/scripts/build.sh --registry quay.io/myorg --push --scan
  ./air-gapped/scripts/build.sh --builder-image nexus.internal/ubi9/ubi-minimal:latest \
                     --runtime-image nexus.internal/ubi9/ubi-micro:latest
USAGE
  exit 0
}

# ── Defaults ──────────────────────────────────────────────────────────────────
VERSION="0.19.1"
ARCH="amd64"
OS="linux"
REGISTRY=""
IMAGE_NAME="postgres-exporter"
SRC_DIR="./src"
PUSH=false
SCAN=false
NO_CACHE=false
DOCKERFILE="air-gapped/Dockerfile"
BUILDER_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest"
RUNTIME_IMAGE="registry.access.redhat.com/ubi9/ubi-micro:latest"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="$2";    shift 2 ;;
    --arch)      ARCH="$2";       shift 2 ;;
    --registry)  REGISTRY="$2";   shift 2 ;;
    --src-dir)   SRC_DIR="$2";    shift 2 ;;
    --push)      PUSH=true;       shift   ;;
    --scan)      SCAN=true;       shift   ;;
    --no-cache)  NO_CACHE=true;   shift   ;;
    --file)          DOCKERFILE="$2";    shift 2 ;;
    --builder-image)    BUILDER_IMAGE="$2";   shift 2 ;;
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

if [[ ! -f "${DOCKERFILE}" ]]; then
  ERRORS+=("Dockerfile not found: ${DOCKERFILE}")
fi

if [[ ! -d "${SRC_DIR}" ]]; then
  ERRORS+=("Source directory not found: ${SRC_DIR}")
  ERRORS+=("  → Run: ./air-gapped/scripts/download-source.sh --version ${VERSION} && ./air-gapped/scripts/vendor-deps.sh")
fi

if [[ -d "${SRC_DIR}" && ! -d "${SRC_DIR}/vendor" ]]; then
  ERRORS+=("Vendor directory not found: ${SRC_DIR}/vendor/")
  ERRORS+=("  → Run: ./air-gapped/scripts/download-source.sh --version ${VERSION} && ./air-gapped/scripts/vendor-deps.sh")
fi

if [[ -d "${SRC_DIR}/vendor" && ! -f "${SRC_DIR}/vendor/modules.txt" ]]; then
  ERRORS+=("Vendor directory is incomplete (modules.txt missing): ${SRC_DIR}/vendor/")
  ERRORS+=("  → Run: ./air-gapped/scripts/download-source.sh --version ${VERSION} && ./air-gapped/scripts/vendor-deps.sh")
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
# VCS_REF refers to this packaging repository's commit, not upstream.
VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

TAG="${VERSION}-ubi9-${ARCH}"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"
[[ -n "${REGISTRY}" ]] && FULL_IMAGE="${REGISTRY}/${FULL_IMAGE}"

EXTRA_FLAGS=()
[[ "${NO_CACHE}" == "true" ]] && EXTRA_FLAGS+=(--no-cache)

# Resolve absolute path so the summary is unambiguous
ABS_SRC="$(cd "${SRC_DIR}" && pwd)"

# ── Summary ───────────────────────────────────────────────────────────────────
VENDOR_MODULES=$(grep -c "^# " "${SRC_DIR}/vendor/modules.txt" 2>/dev/null || echo "?")

echo "postgres_exporter — air-gap image build"
echo "─────────────────────────────────────────"
printf "  %-16s %s\n" "Dockerfile:"    "${DOCKERFILE}"
printf "  %-16s %s\n" "Image:"         "${FULL_IMAGE}"
printf "  %-16s %s\n" "Version:"       "${VERSION}"
printf "  %-16s %s\n" "Arch:"          "${OS}/${ARCH}"
printf "  %-16s %s\n" "Source dir:"    "${ABS_SRC}"
printf "  %-16s %s\n" "Vendored mods:" "${VENDOR_MODULES}"
printf "  %-16s %s\n" "Build date:"    "${BUILD_DATE}"
printf "  %-16s %s\n" "VCS ref:"       "${VCS_REF}"
printf "  %-16s %s\n" "Push:"          "${PUSH}"
printf "  %-16s %s\n" "CVE scan:"      "${SCAN}"
printf "  %-16s %s\n" "Builder image:"    "${BUILDER_IMAGE}"
printf "  %-16s %s\n" "Runtime image:" "${RUNTIME_IMAGE}"
printf "  %-16s %s\n" "No-cache:"      "${NO_CACHE}"
echo "─────────────────────────────────────────"
echo ""

# ── Build ─────────────────────────────────────────────────────────────────────
${CONTAINER_RT} build \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
  --file="${DOCKERFILE}" \
  --build-arg UBI_MINIMAL_IMAGE="${BUILDER_IMAGE}" \
  --build-arg UBI_MICRO_IMAGE="${RUNTIME_IMAGE}" \
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
    echo "   Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
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
