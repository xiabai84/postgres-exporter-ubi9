#!/usr/bin/env bash
# =============================================================================
#  scripts/vendor-source.sh
#
#  PURPOSE
#  -------
#  Downloads the postgres_exporter source and vendors Go dependencies
#  for an air-gapped CI build. No Go installation required — vendoring
#  runs inside a container.
#
#  Usage:
#    ./scripts/vendor-source.sh [OPTIONS]
#
#  Options:
#    --version <ver>    postgres_exporter version to vendor (default: 0.19.1)
#    --src-dir <path>   destination directory              (default: ./src)
#    --keep-existing    do not delete src/ before extracting
#    -h | --help        print this help
#
#  Requirements:
#    - bash, curl, tar, docker
#    - Internet access to github.com and proxy.golang.org
# =============================================================================
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/vendor-source.sh [OPTIONS]

Downloads postgres_exporter source and vendors Go dependencies.
No Go installation required — vendoring runs inside a container.

Options:
  --version <ver>    postgres_exporter version to vendor (default: 0.19.1)
  --src-dir <path>   destination directory (default: ./src)
  --keep-existing    do not delete src/ before extracting
  -h | --help        print this help

Examples:
  ./scripts/vendor-source.sh
  ./scripts/vendor-source.sh --version 0.19.1
  ./scripts/vendor-source.sh --version 0.19.1 --src-dir ./upstream/src
USAGE
  exit 0
}

# ── Defaults ──────────────────────────────────────────────────────────────────
VERSION="0.19.1"
SRC_DIR="./src"
KEEP_EXISTING=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)      VERSION="$2";      shift 2 ;;
    --src-dir)      SRC_DIR="$2";      shift 2 ;;
    --keep-existing) KEEP_EXISTING=true; shift  ;;
    -h|--help)      usage ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

UPSTREAM_URL="https://github.com/prometheus-community/postgres_exporter/archive/refs/tags/v${VERSION}.tar.gz"
TMPFILE="$(mktemp /tmp/postgres_exporter-XXXXXX)"
TARBALL="${TMPFILE}.tar.gz"
trap 'rm -f "${TMPFILE}" "${TARBALL}"' EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────
for cmd in curl tar docker; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is required but not found in PATH." >&2
    exit 1
  fi
done

echo "postgres_exporter — vendor-source initialiser"
echo "───────────────────────────────────────────────"
printf "  %-12s %s\n" "Version:"    "${VERSION}"
printf "  %-12s %s\n" "Source dir:" "${SRC_DIR}"
printf "  %-12s %s\n" "Upstream:"   "${UPSTREAM_URL}"
echo "───────────────────────────────────────────────"
echo ""

# ── Step 1: Download source tarball ──────────────────────────────────────────
echo "── Step 1/3: Downloading source tarball ─────────────────────"
curl -fsSL --progress-bar "${UPSTREAM_URL}" -o "${TARBALL}"
echo "   Saved to: ${TARBALL}"
echo "   Size:     $(du -sh "${TARBALL}" | cut -f1)"

# Verify checksum if a .sha256 sidecar exists on GitHub releases
CHECKSUM_URL="https://github.com/prometheus-community/postgres_exporter/releases/download/v${VERSION}/sha256sums.txt"
CHECKSUMS="$(curl -fsSL "${CHECKSUM_URL}" 2>/dev/null || true)"
if [[ -n "${CHECKSUMS}" ]]; then
  EXPECTED="$(echo "${CHECKSUMS}" | grep "postgres_exporter-${VERSION}.tar.gz" | awk '{print $1}' || true)"
  if [[ -n "${EXPECTED}" ]]; then
    ACTUAL="$(sha256sum "${TARBALL}" 2>/dev/null || shasum -a 256 "${TARBALL}" | awk '{print $1}')"
    ACTUAL="$(echo "${ACTUAL}" | awk '{print $1}')"
    if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
      echo "ERROR: SHA-256 checksum mismatch!" >&2
      echo "  expected: ${EXPECTED}" >&2
      echo "  actual:   ${ACTUAL}" >&2
      exit 1
    fi
    echo "   SHA-256:  ${ACTUAL} (verified)"
  else
    echo "   SHA-256:  checksum file found but no matching entry — skipping verification"
  fi
else
  echo "   SHA-256:  no upstream checksum available — skipping verification"
fi

# ── Step 2: Extract to src/ ───────────────────────────────────────────────────
echo ""
echo "── Step 2/3: Extracting to ${SRC_DIR}/ ──────────────────────"

if [[ "${KEEP_EXISTING}" == "false" ]]; then
  if [[ -d "${SRC_DIR}" ]]; then
    echo "   Removing existing ${SRC_DIR}/ ..."
    rm -rf "${SRC_DIR}"
  fi
fi

mkdir -p "${SRC_DIR}"
tar -xzf "${TARBALL}" \
    --strip-components=1 \
    -C "${SRC_DIR}"

echo "   Extracted $(find "${SRC_DIR}" -type f | wc -l | tr -d ' ') files."

# ── Step 3: Vendor Go dependencies inside a container ────────────────────────
echo ""
echo "── Step 3/3: Vendoring Go dependencies (in container) ───────"

ABS_SRC="$(cd "${SRC_DIR}" && pwd)"

docker run --rm \
  -v "${ABS_SRC}:/src" \
  -w /src \
  golang:1.24-bookworm \
  sh -c '
    set -eu
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

# ── Summary and next steps ────────────────────────────────────────────────────
echo ""
echo "Done. Commit the following to git, then push to the"
echo "internal repository so the CI pipeline can build offline."
echo "───────────────────────────────────────────────────────────"
echo ""
echo "  git add src/"
echo "  git commit -m \"vendor: postgres_exporter v${VERSION} with Go modules\""
echo "  git push"
echo ""
echo "  To build the image afterward (internet not required):"
echo "  ./scripts/build.sh --version ${VERSION}"
echo ""
