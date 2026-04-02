#!/usr/bin/env bash
# =============================================================================
#  scripts/vendor-source.sh
#
#  PURPOSE
#  -------
#  Prepares the src/ directory for an air-gapped CI build.
#  Run this script ONCE on an internet-connected machine whenever you need
#  to initialise or upgrade postgres_exporter.
#
#  What it does:
#    1. Downloads the postgres_exporter source tarball from GitHub
#    2. Extracts it to src/
#    3. Runs `go mod vendor` to bundle all Go module dependencies
#    4. Prints the git commands needed to commit the result
#
#  After running, commit src/ to git and push to the internal repository.
#  The CI pipeline can then build the Docker image with zero internet access.
#
#  Usage:
#    ./scripts/vendor-source.sh [OPTIONS]
#
#  Options:
#    --version <ver>    postgres_exporter version to vendor (default: 0.19.1)
#    --src-dir <path>   destination directory              (default: ./src)
#    --keep-existing    do not delete src/ before vendoring
#    -h | --help        print this help
#
#  Examples:
#    ./scripts/vendor-source.sh
#    ./scripts/vendor-source.sh --version 0.19.1
#    ./scripts/vendor-source.sh --version 0.19.1 --src-dir ./upstream/src
#
#  Requirements:
#    - bash, curl, tar, go (any recent version)
#    - Internet access to github.com and proxy.golang.org
# =============================================================================
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/vendor-source.sh [OPTIONS]

Prepares the src/ directory for an air-gapped CI build.
Run once on an internet-connected machine.

Options:
  --version <ver>    postgres_exporter version to vendor (default: 0.19.1)
  --src-dir <path>   destination directory (default: ./src)
  --keep-existing    do not delete src/ before vendoring
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
TARBALL="$(mktemp /tmp/postgres_exporter-XXXXXX.tar.gz)"
trap 'rm -f "${TARBALL}"' EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────
for cmd in curl tar go git; do
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
echo "── Step 1/4: Downloading source tarball ─────────────────────"
curl -fsSL --progress-bar "${UPSTREAM_URL}" -o "${TARBALL}"
echo "   Saved to: ${TARBALL}"
echo "   Size:     $(du -sh "${TARBALL}" | cut -f1)"

# Verify checksum if a .sha256 sidecar exists on GitHub releases
CHECKSUM_URL="https://github.com/prometheus-community/postgres_exporter/releases/download/v${VERSION}/sha256sums.txt"
if CHECKSUMS="$(curl -fsSL "${CHECKSUM_URL}" 2>/dev/null)"; then
  EXPECTED="$(echo "${CHECKSUMS}" | grep "postgres_exporter-${VERSION}.tar.gz" | awk '{print $1}')"
  if [[ -n "${EXPECTED}" ]]; then
    ACTUAL="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
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
echo "── Step 2/4: Extracting to ${SRC_DIR}/ ──────────────────────"

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

echo "   Extracted $(find "${SRC_DIR}" -type f | wc -l) files."

# ── Step 3: Vendor Go module dependencies ─────────────────────────────────────
echo ""
echo "── Step 3/4: Vendoring Go dependencies ──────────────────────"
echo "   Running: go mod download && go mod vendor"
echo "   (This may take a minute the first time …)"

pushd "${SRC_DIR}" > /dev/null

# Download modules into the local module cache first, then vendor them.
go mod download
go mod verify
go mod vendor

VENDOR_COUNT=$(find vendor -type f | wc -l)
VENDOR_SIZE=$(du -sh vendor | cut -f1)
echo "   Vendored ${VENDOR_COUNT} files, total size: ${VENDOR_SIZE}"

popd > /dev/null

# ── Step 4: Verify the vendor directory is complete ───────────────────────────
echo ""
echo "── Step 4/4: Verifying vendor consistency ───────────────────"
pushd "${SRC_DIR}" > /dev/null
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS="-mod=vendor" go build -v -o /dev/null ./cmd/postgres_exporter
echo "   OK — vendor directory is complete and buildable."
popd > /dev/null

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
