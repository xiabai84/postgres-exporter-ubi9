# postgres_exporter — UBI 9 Air-Gap Build

Prometheus exporter for PostgreSQL, packaged as a minimal container image on Red Hat UBI 9. Designed for offline/air-gapped CI builds targeting OpenShift 4.x (`restricted-v2` SCC).

| Property | Value |
|---|---|
| Upstream | [prometheus-community/postgres_exporter](https://github.com/prometheus-community/postgres_exporter) |
| Metrics port | `9187` |
| Builder image | `ubi9/ubi-minimal` |
| Runtime image | `ubi9/ubi-micro` (distroless-style, no shell) |
| Binary | Fully static (`CGO_ENABLED=0`) |
| Runtime user | `65534:0` (OpenShift arbitrary-UID compatible) |

## Repository Structure

```
.
├── Dockerfile                  # Multi-stage build (builder + runtime)
├── .dockerignore
├── scripts/
│   ├── download-source.sh      # Downloads upstream source (needs internet)
│   ├── vendor-deps.sh          # Vendors Go dependencies in container (needs docker)
│   └── build.sh                # Builds the Docker image (offline)
└── src/                        # Vendored source — committed to git
    ├── go.mod / go.sum
    ├── cmd/postgres_exporter/
    └── vendor/                 # Go dependencies (go mod vendor output)
```

## How It Works

The build is split into two phases to separate internet-facing preparation from offline CI builds:

```
Developer workstation (internet)         Internal CI (air-gapped)
─────────────────────────────────        ────────────────────────────
1. download-source.sh                   git clone / pull
2. vendor-deps.sh                       build.sh --version 0.19.1
3. git add src/ && git commit && push   → produces container image
```

The developer downloads source and vendors dependencies once. After committing `src/` to git, the air-gapped CI pipeline only needs Docker to build the image — no internet, no Go, no curl.

## Quick Start

### Step 1: Download source (requires internet)

```bash
./scripts/download-source.sh --version 0.19.1
```

Downloads the postgres_exporter source tarball from GitHub, verifies SHA-256 if available, and extracts it into `src/`.

Prerequisites: `bash`, `curl`, `tar`

| Flag | Default | Description |
|---|---|---|
| `--version <ver>` | `0.19.1` | postgres_exporter version to download |
| `--src-dir <path>` | `./src` | Where to extract the source |
| `--keep-existing` | off | Don't wipe `src/` before extracting |

### Step 2: Vendor Go dependencies (requires Docker)

```bash
./scripts/vendor-deps.sh
```

Runs `go mod vendor` inside a UBI9 container to bundle all Go dependencies into `src/vendor/`. Also verifies the vendor directory compiles successfully.

Prerequisites: `bash`, `docker` or `podman` (no Go installation needed)

| Flag | Default | Description |
|---|---|---|
| `--src-dir <path>` | `./src` | Source directory containing `go.mod` |
| `--image <ref>` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Container image for vendoring |

### Step 3: Commit and push

```bash
git add src/
git commit -m "vendor: postgres_exporter v0.19.1"
git push   # to internal git repository
```

> **Note:** `src/vendor/` adds ~15-20 MB to the repository. This is the
> expected trade-off for fully reproducible, offline builds.

### Step 4: Build the image (offline)

On the air-gapped CI or locally — no internet access needed:

```bash
./scripts/build.sh --version 0.19.1
```

Produces: `postgres-exporter:0.19.1-ubi9-amd64`

| Flag | Default | Description |
|---|---|---|
| `--version <ver>` | `0.19.1` | Version to embed in the binary and image labels |
| `--arch <arch>` | `amd64` | Target architecture: `amd64` or `arm64` |
| `--registry <url>` | none | Registry prefix for tagging (e.g. `quay.io/myorg`) |
| `--push` | off | Push the image after build (requires `--registry`) |
| `--scan` | off | Run a Trivy CVE scan after build |
| `--no-cache` | off | Force Docker to re-pull base images |
| `--file <path>` | `Dockerfile` | Path to an alternative Dockerfile |
| `--builder-image <ref>` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Builder stage image (compiles the binary) |
| `--runtime-image <ref>` | `registry.access.redhat.com/ubi9/ubi-micro:latest` | Runtime stage base image |

### Step 5: Run

```bash
docker run --rm -e DATA_SOURCE_NAME="postgresql://user:pass@host:5432/db?sslmode=disable" \
  -p 9187:9187 postgres-exporter:0.19.1-ubi9-amd64
```

Metrics are available at `http://localhost:9187/metrics`.

## Upgrading

```bash
./scripts/download-source.sh --version 0.20.0
./scripts/vendor-deps.sh
git add src/
git commit -m "vendor: upgrade postgres_exporter to v0.20.0"
git push

# On CI or locally:
./scripts/build.sh --version 0.20.0
```

## Using an Internal Registry

If your organization mirrors container images to an internal registry (e.g. Nexus, Artifactory), override the default image URLs:

```bash
# Vendor using a mirrored UBI9 image
./scripts/vendor-deps.sh --image nexus.internal/ubi9/ubi-minimal:latest

# Build using mirrored base images
./scripts/build.sh --version 0.19.1 \
  --builder-image nexus.internal/ubi9/ubi-minimal:latest \
  --runtime-image nexus.internal/ubi9/ubi-micro:latest
```

All scripts default to `registry.access.redhat.com/...` when no override is provided.

## Re-Vendoring (after patching go.mod)

If you edit `src/go.mod` directly (e.g. to pin a dependency), re-vendor without re-downloading:

```bash
./scripts/vendor-deps.sh
git add src/
git commit -m "vendor: re-vendor after go.mod change"
```

## Environment Variables

| Variable | Description |
|---|---|
| `DATA_SOURCE_NAME` | Full PostgreSQL DSN (URI or key=value format) |
| `DATA_SOURCE_URI` | Host/port/db without credentials |
| `DATA_SOURCE_USER` / `DATA_SOURCE_PASS` | Credentials (with `DATA_SOURCE_URI`) |
| `DATA_SOURCE_*_FILE` | File-based variants for mounted secrets |
| `PG_EXPORTER_WEB_LISTEN_ADDRESS` | Listen address (default `:9187`) |
| `PG_EXPORTER_EXTEND_QUERY_PATH` | Path to custom queries YAML |
| `PG_EXPORTER_DISABLE_DEFAULT_METRICS` | Set `true` to disable built-in metrics |
| `PG_EXPORTER_CONSTANT_LABELS` | Comma-separated `key=value` labels |

See the [upstream docs](https://github.com/prometheus-community/postgres_exporter) for the full configuration reference.

## Health Probes

The image does not include a Docker `HEALTHCHECK`. On Kubernetes/OpenShift, configure probes in the Deployment manifest:

| Probe | Path | Port | Purpose |
|---|---|---|---|
| `startupProbe` | `/metrics` | `9187` | Wait for initial scrape before activating other probes |
| `livenessProbe` | `/metrics` | `9187` | Restart on hang/deadlock |
| `readinessProbe` | `/metrics` | `9187` | Remove from Service endpoints if unhealthy |

## Security Notes

- Runs as non-root (`USER 65534:0`), compatible with OpenShift `restricted-v2` SCC
- Runtime image has no shell, no package manager — minimal attack surface
- `GOPROXY=off` enforced at build time — no network calls possible during compilation
- All Go dependencies vendored and auditable in `src/vendor/`
