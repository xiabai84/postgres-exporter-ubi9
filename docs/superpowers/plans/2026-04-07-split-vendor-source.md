# Split vendor-source.sh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `vendor-source.sh` into `download-source.sh` (download + extract) and `vendor-deps.sh` (Go vendoring in container), so each script has a single responsibility and minimal dependencies.

**Architecture:** Two scripts replace one. `download-source.sh` handles internet-facing work (curl + tar only). `vendor-deps.sh` runs Go vendoring inside a Docker container on an existing `src/` directory. The CI workflow and README are updated to call both scripts. `build.sh` and `Dockerfile` are unchanged.

**Tech Stack:** Bash, curl, tar, Docker

---

### Task 1: Create download-source.sh

**Files:**
- Create: `scripts/download-source.sh`

- [ ] **Step 1: Write the script**

Extract steps 1-2 from `vendor-source.sh` into a new script. Dependencies: `bash`, `curl`, `tar` only.

```bash
#!/usr/bin/env bash
# downloads postgres_exporter source tarball and extracts to src/
# Requirements: bash, curl, tar
# No Docker or Go needed.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./scripts/download-source.sh [OPTIONS]

Downloads postgres_exporter source from GitHub and extracts to src/.
No Docker or Go required.

Options:
  --version <ver>    postgres_exporter version (default: 0.19.1)
  --src-dir <path>   destination directory (default: ./src)
  --keep-existing    do not delete src/ before extracting
  -h | --help        print this help

Examples:
  ./scripts/download-source.sh
  ./scripts/download-source.sh --version 0.19.1
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
echo "Done. Next step: ./scripts/vendor-deps.sh --src-dir ${SRC_DIR}"
```

- [ ] **Step 2: Make executable and test**

Run: `chmod 755 scripts/download-source.sh && bash scripts/download-source.sh --version 0.19.1`
Expected: Downloads tarball, extracts to `src/`, prints "Done. Next step" message. No Docker or Go required.

- [ ] **Step 3: Commit**

```bash
git add scripts/download-source.sh
git commit -m "Add download-source.sh for downloading upstream source"
```

---

### Task 2: Create vendor-deps.sh

**Files:**
- Create: `scripts/vendor-deps.sh`

- [ ] **Step 1: Write the script**

Extract step 3 from `vendor-source.sh` into a new script. Dependencies: `bash`, `docker` only.

```bash
#!/usr/bin/env bash
# Vendors Go dependencies inside a container for an existing src/ directory.
# Requirements: bash, docker
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

# ── Pre-flight checks ────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "ERROR: 'docker' is required but not found in PATH." >&2
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
echo "─────────────────────────────────────────"
echo ""

echo "── Vendoring Go dependencies (in container) ────────────────"

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
```

- [ ] **Step 2: Make executable and test**

Run: `chmod 755 scripts/vendor-deps.sh && bash scripts/vendor-deps.sh`
Expected: Runs go mod vendor inside container, prints vendor stats, prints git instructions.
Prerequisite: `src/` must exist from Task 1.

- [ ] **Step 3: Commit**

```bash
git add scripts/vendor-deps.sh
git commit -m "Add vendor-deps.sh for containerized Go vendoring"
```

---

### Task 3: Delete vendor-source.sh

**Files:**
- Delete: `scripts/vendor-source.sh`

- [ ] **Step 1: Remove the file**

```bash
rm scripts/vendor-source.sh
```

- [ ] **Step 2: Commit**

```bash
git add -u scripts/vendor-source.sh
git commit -m "Remove vendor-source.sh, replaced by download-source.sh + vendor-deps.sh"
```

---

### Task 4: Update GitHub Actions workflow

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Replace vendor-source.sh call with two new scripts**

Change the "Vendor source" step to call both scripts:

```yaml
      - name: Download source
        run: ./scripts/download-source.sh --version ${{ env.POSTGRES_EXPORTER_VERSION }}

      - name: Vendor dependencies
        run: ./scripts/vendor-deps.sh
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Update workflow to use download-source.sh + vendor-deps.sh"
```

---

### Task 5: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite README to reflect two-script workflow**

Key changes:
- Update repository structure to show `download-source.sh` and `vendor-deps.sh` instead of `vendor-source.sh`
- Split "Vendor the source" section into two sub-steps: download then vendor
- Separate prerequisites per script (curl/tar for download, docker for vendor)
- Clarify that the internal CI only runs `build.sh` against committed `src/`
- Update the Upgrading section

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Update README for two-script vendor workflow"
```

---

### Task 6: End-to-end verification

- [ ] **Step 1: Clean src/ and run full flow**

```bash
rm -rf src/
bash scripts/download-source.sh --version 0.19.1
bash scripts/vendor-deps.sh
bash scripts/build.sh --version 0.19.1
```

Expected: Image `postgres-exporter:0.19.1-ubi9-amd64` builds successfully.

- [ ] **Step 2: Verify help flags**

```bash
bash scripts/download-source.sh --help
bash scripts/vendor-deps.sh --help
```

Expected: Both print usage information and exit 0.

- [ ] **Step 3: Push to GitHub**

```bash
git push origin main
```
