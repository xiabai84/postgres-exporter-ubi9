# Dual Build Modes: Air-Gapped and GoProxy

## Goal

Reorganize the repository into two top-level folders — `air-gapped/` and `goproxy/` — providing two independent deployment paths for building the postgres_exporter container image.

## Context

The current repository supports only air-gapped builds: dependencies are vendored locally and committed to git. Organizations with an internal Go proxy (e.g. Nexus) can skip vendoring entirely — the Dockerfile downloads dependencies at build time via the proxy. Both approaches produce the same artifact: a static postgres_exporter binary in a UBI9 micro image.

## Repository Structure

```
.
├── air-gapped/                       # Fully offline builds (current approach)
│   ├── Dockerfile
│   ├── .dockerignore
│   └── scripts/
│       ├── download-source.sh        # Downloads upstream source (needs internet)
│       ├── vendor-deps.sh            # Vendors Go deps in container (needs docker)
│       └── build.sh                  # Builds image from vendored src/ (offline)
│
├── goproxy/                          # Builds via internal Go proxy (new)
│   ├── Dockerfile
│   ├── .dockerignore
│   └── scripts/
│       └── build.sh                  # Builds image, deps fetched via GOPROXY
│
├── .github/workflows/release.yml     # Stays at root, uses air-gapped/
├── docs/
│   └── build-pipeline.md
└── README.md                         # Explains both approaches
```

## Air-Gapped (moved from root)

All existing files (`Dockerfile`, `.dockerignore`, `scripts/`) move into `air-gapped/`. No functional changes. The workflow remains:

1. Developer runs `download-source.sh` — downloads source to `src/`
2. Developer runs `vendor-deps.sh` — vendors Go deps into `src/vendor/`
3. Developer commits `src/` and pushes
4. Air-gapped CI runs `build.sh` — no internet needed

## GoProxy (new)

### Developer workflow

```bash
# Step 1: Download source (reuse air-gapped script)
./air-gapped/scripts/download-source.sh --version 0.19.1

# Step 2: Build image (deps fetched from internal proxy at build time)
./goproxy/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/go-proxy/

# If proxy requires authentication, pass a .netrc file:
./goproxy/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/go-proxy/ \
  --netrc ~/.netrc
```

No `vendor-deps.sh` needed. No `src/vendor/` committed. The `src/` directory contains only source code.

### goproxy/Dockerfile

Two-stage build, same as air-gapped but without vendor enforcement:

**Stage 1 — Builder (ubi-minimal):**
- Installs Go via `microdnf`
- `COPY src/ /build/`
- `GOPROXY` set via build-arg to the internal proxy URL
- If proxy requires authentication, a `.netrc` file is mounted as a BuildKit secret (`--mount=type=secret,id=netrc,target=/root/.netrc`). The secret is only available during the `go build` step and is never written into image layers.
- `go build` without `-mod=vendor` — dependencies are downloaded from the proxy

**Stage 2 — Runtime (ubi-micro):**
- Identical to air-gapped: copies static binary, CA certs, passwd/group

### goproxy/Dockerfile build-args

| Arg | Default | Description |
|-----|---------|-------------|
| `GOPROXY` | (none, required) | Internal Go proxy URL |
| `UBI_MINIMAL_IMAGE` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Builder base image |
| `UBI_MICRO_IMAGE` | `registry.access.redhat.com/ubi9/ubi-micro:latest` | Runtime base image |
| `POSTGRES_EXPORTER_VERSION` | `0.19.1` | Version embedded in binary |
| `TARGETARCH` | `amd64` | Target architecture |
| `VCS_REF` | `unknown` | Git commit SHA |
| `BUILD_DATE` | auto | ISO 8601 build timestamp |

### goproxy/scripts/build.sh

Same structure as `air-gapped/scripts/build.sh` with these differences:

- `--goproxy <url>` flag is **required** (no default)
- `--netrc <path>` flag is **optional** — path to a `.netrc` file for proxy authentication. Passed to docker/podman as `--secret id=netrc,src=<path>`. The Dockerfile mounts it only during the `go build` step.
- No `--src-dir` flag (always expects `src/` at repo root)
- Pre-flight check: `src/go.mod` must exist (but `src/vendor/` is NOT required)
- Passes `GOPROXY` as a `--build-arg` to docker/podman
- Supports same flags: `--version`, `--arch`, `--registry`, `--push`, `--scan`, `--no-cache`, `--builder-image`, `--runtime-image`
- Supports docker/podman auto-detection

## Shared

- `download-source.sh` lives in `air-gapped/scripts/` but is used by both workflows
- `docs/` stays at root
- Root `README.md` is rewritten to explain both approaches with a decision guide
- `.github/workflows/release.yml` stays at root, uses `air-gapped/` path

## What gets deleted from root

- `Dockerfile` — moves to `air-gapped/Dockerfile`
- `.dockerignore` — moves to `air-gapped/.dockerignore`
- `scripts/` — moves to `air-gapped/scripts/`

## Decision guide for README

| | Air-Gapped | GoProxy |
|---|---|---|
| CI has internet | Not needed | Needs access to internal Go proxy |
| Vendoring step | Required (`vendor-deps.sh`) | Not needed |
| `src/vendor/` in git | Yes (~15-20 MB) | No |
| Build reproducibility | Exact (pinned in vendor) | Depends on proxy cache |
| Setup complexity | Higher (vendor + commit) | Lower (just download + build) |
