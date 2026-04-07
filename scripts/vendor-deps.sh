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
  -h | --help        print this help

Examples:
  ./scripts/vendor-deps.sh
  ./scripts/vendor-deps.sh --src-dir ./upstream/src
USAGE
  exit 0
}

SRC_DIR="./src"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-dir)  SRC_DIR="$2"; shift 2 ;;
    -h|--help)  usage ;;
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
printf "  %-12s %s\n" "Runtime:"    "${CONTAINER_RT}"
echo "─────────────────────────────────────────"
echo ""

echo "── Vendoring Go dependencies (in container) ────────────────"

${CONTAINER_RT} run --rm \
  --platform linux/amd64 \
  -v "${ABS_SRC}:/src" \
  -w /src \
  registry.access.redhat.com/ubi9/ubi-minimal:latest \
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
