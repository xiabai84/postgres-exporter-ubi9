#!/usr/bin/env bash
# Vendors Go dependencies inside a container for an existing src/ directory.
# Requirements: bash, docker or podman
# No Go installation needed.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/vendor-deps.sh [OPTIONS]

Vendors Go dependencies for an existing src/ directory.
Runs inside a golang container — no Go installation needed.

Options:
  --src-dir <path>   source directory containing go.mod (default: ./src)
  --image <ref>      container image with microdnf + Go support
                     (default: registry.access.redhat.com/ubi9/ubi-minimal:latest)
  --goproxy <url>    Go module proxy URL (default: https://proxy.golang.org,direct)
                     Use for internal Nexus/Artifactory Go proxy repositories.
                     Also reads GOPROXY env var if set.
  --netrc <path>     Mount a .netrc file for proxy authentication (optional)
  -h | --help        print this help

Examples:
  ./scripts/vendor-deps.sh
  ./scripts/vendor-deps.sh --image nexus.internal/ubi9/ubi-minimal:latest
  ./scripts/vendor-deps.sh --goproxy https://nexus.internal/repository/go-proxy/
  ./scripts/vendor-deps.sh --goproxy https://nexus.internal/repository/go-proxy/ \
                           --netrc ~/.netrc
USAGE
  exit 0
}

SRC_DIR="./src"
VENDOR_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest"
GO_PROXY="${GOPROXY:-https://proxy.golang.org,direct}"
NETRC_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-dir)   SRC_DIR="$2";       shift 2 ;;
    --image)     VENDOR_IMAGE="$2";  shift 2 ;;
    --goproxy)   GO_PROXY="$2";      shift 2 ;;
    --netrc)     NETRC_FILE="$2";    shift 2 ;;
    -h|--help)   usage ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Detect container runtime ──────────────────────────────────────────────────
if command -v docker &>/dev/null; then
  CONTAINER_RT=docker
elif command -v podman &>/dev/null; then
  CONTAINER_RT=podman
else
  echo "ERROR: 'docker' or 'podman' is required but neither was found in PATH." >&2
  exit 1
fi

if [[ ! -f "${SRC_DIR}/go.mod" ]]; then
  echo "ERROR: ${SRC_DIR}/go.mod not found." >&2
  echo "  Run ./scripts/download-source.sh first." >&2
  exit 1
fi

ABS_SRC="$(cd "${SRC_DIR}" && pwd)"

echo "postgres_exporter — vendor dependencies"
echo "─────────────────────────────────────────"
printf "  %-12s %s\n" "Source dir:" "${ABS_SRC}"
printf "  %-12s %s\n" "Image:"      "${VENDOR_IMAGE}"
printf "  %-12s %s\n" "GOPROXY:"    "${GO_PROXY}"
printf "  %-12s %s\n" "Runtime:"    "${CONTAINER_RT}"
echo "─────────────────────────────────────────"
echo ""

echo "── Vendoring Go dependencies (in container) ────────────────"

NETRC_MOUNT=()
if [[ -n "${NETRC_FILE}" ]]; then
  if [[ ! -f "${NETRC_FILE}" ]]; then
    echo "ERROR: netrc file not found: ${NETRC_FILE}" >&2
    exit 1
  fi
  ABS_NETRC="$(cd "$(dirname "${NETRC_FILE}")" && pwd)/$(basename "${NETRC_FILE}")"
  NETRC_MOUNT=(-v "${ABS_NETRC}:/root/.netrc:ro")
fi

${CONTAINER_RT} run --rm \
  --platform linux/amd64 \
  -e GOPROXY="${GO_PROXY}" \
  ${NETRC_MOUNT[@]+"${NETRC_MOUNT[@]}"} \
  -v "${ABS_SRC}:/src" \
  -w /src \
  "${VENDOR_IMAGE}" \
  sh -c '
    set -eu
    echo "   Installing Go toolchain ..."
    microdnf install -y golang > /dev/null 2>&1
    microdnf clean all > /dev/null 2>&1
    echo "   go mod download ..."
    go mod download
    echo "   go mod verify ..."
    go mod verify
    echo "   go mod vendor ..."
    go mod vendor
    echo "   Verifying vendor is complete ..."
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS="-mod=vendor" \
      go build -o /dev/null ./cmd/postgres_exporter
    echo "   OK — vendor directory is complete and buildable."
  '

VENDOR_COUNT=$(find "${SRC_DIR}/vendor" -type f | wc -l | tr -d ' ')
VENDOR_SIZE=$(du -sh "${SRC_DIR}/vendor" | cut -f1)
echo "   Vendored ${VENDOR_COUNT} files, total size: ${VENDOR_SIZE}"

echo ""
echo "Done. Commit the result and push to the internal repository:"
echo "───────────────────────────────────────────────────────────────"
echo ""
echo "  git add src/"
echo "  git commit -m \"vendor: postgres_exporter with Go modules\""
echo "  git push"
echo ""
echo "  The air-gapped CI pipeline can then build with:"
echo "  ./scripts/build.sh --version <ver>"
echo ""
