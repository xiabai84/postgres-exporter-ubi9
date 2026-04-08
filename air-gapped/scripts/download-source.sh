#!/usr/bin/env bash
# downloads postgres_exporter source tarball and extracts to src/
# Requirements: bash, curl, tar
# No Docker or Go needed.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./air-gapped/scripts/download-source.sh [OPTIONS]

Downloads postgres_exporter source from GitHub and extracts to src/.
No Docker or Go required.

Options:
  --version <ver>    postgres_exporter version (default: 0.19.1)
  --src-dir <path>   destination directory (default: ./src)
  --keep-existing    do not delete src/ before extracting
  -h | --help        print this help

Examples:
  ./air-gapped/scripts/download-source.sh
  ./air-gapped/scripts/download-source.sh --version 0.19.1
USAGE
  exit 0
}

VERSION="0.19.1"
SRC_DIR="./src"
KEEP_EXISTING=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)       VERSION="$2";       shift 2 ;;
    --src-dir)       SRC_DIR="$2";       shift 2 ;;
    --keep-existing) KEEP_EXISTING=true; shift   ;;
    -h|--help)       usage ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

UPSTREAM_URL="https://github.com/prometheus-community/postgres_exporter/archive/refs/tags/v${VERSION}.tar.gz"
TMPFILE="$(mktemp /tmp/postgres_exporter-XXXXXX)"
TARBALL="${TMPFILE}.tar.gz"
trap 'rm -f "${TMPFILE}" "${TARBALL}"' EXIT

for cmd in curl tar; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is required but not found in PATH." >&2
    exit 1
  fi
done

echo "postgres_exporter — download source"
echo "─────────────────────────────────────"
printf "  %-12s %s\n" "Version:"    "${VERSION}"
printf "  %-12s %s\n" "Source dir:" "${SRC_DIR}"
printf "  %-12s %s\n" "Upstream:"   "${UPSTREAM_URL}"
echo "─────────────────────────────────────"
echo ""

# ── Download ─────────────────────────────────────────────────────────────────
echo "── Step 1/2: Downloading source tarball ─────────────────────"
curl -fsSL --progress-bar "${UPSTREAM_URL}" -o "${TARBALL}"
echo "   Saved to: ${TARBALL}"
echo "   Size:     $(du -sh "${TARBALL}" | cut -f1)"

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

# ── Extract ──────────────────────────────────────────────────────────────────
echo ""
echo "── Step 2/2: Extracting to ${SRC_DIR}/ ──────────────────────"

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
echo ""
echo "Done. Next step: ./air-gapped/scripts/vendor-deps.sh --src-dir ${SRC_DIR}"
