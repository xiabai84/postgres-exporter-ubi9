# postgres_exporter — UBI 9 Container Build

Prometheus exporter for PostgreSQL, packaged as a minimal container image on Red Hat UBI 9. Two build modes are provided for different infrastructure environments.

| Property | Value |
|---|---|
| Upstream | [prometheus-community/postgres_exporter](https://github.com/prometheus-community/postgres_exporter) |
| Metrics port | `9187` |
| Builder image | `ubi9/ubi-minimal` |
| Runtime image | `ubi9/ubi-micro` (distroless-style, no shell) |
| Binary | Fully static (`CGO_ENABLED=0`) |
| Runtime user | `65534:0` (OpenShift arbitrary-UID compatible) |

## Which Build Mode?

| | Air-Gapped | GoProxy | Single-Stage |
|---|---|---|---|
| **Use when** | CI has no internet | CI has Go proxy access | Same as GoProxy, simpler Dockerfile |
| **Vendoring step** | Required | Not needed | Not needed |
| **`src/vendor/` in git** | Yes (~15-20 MB) | No | No |
| **Build reproducibility** | Exact (pinned) | Depends on proxy | Depends on proxy |
| **Runtime image** | `ubi-micro` (~38 MB) | `ubi-micro` (~38 MB) | `ubi-minimal` (~413 MB) |
| **Dockerfile stages** | 2 (multi-stage) | 2 (multi-stage) | 1 (single-stage) |
| **Shell in runtime** | No | No | Yes (debug-friendly) |

## Repository Structure

```
.
├── air-gapped/                       # Fully offline builds
│   ├── Dockerfile
│   ├── .dockerignore
│   └── scripts/
│       ├── download-source.sh        # Downloads upstream source
│       ├── vendor-deps.sh            # Vendors Go deps in container
│       └── build.sh                  # Builds image from vendored src/
│
├── goproxy/                          # Builds via internal Go proxy (multi-stage)
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── Jenkinsfile
│   └── scripts/
│       └── build.sh                  # Builds image, deps fetched via GOPROXY
│
├── single-stage/                     # Single-stage build on ubi-minimal
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── Jenkinsfile
│   └── scripts/
│       └── build.sh                  # Same as goproxy but single-stage
│
├── docs/
│   └── build-pipeline.md            # Detailed pipeline documentation
└── README.md
```

---

## Air-Gapped Build

For environments where CI has no internet access. Dependencies are vendored locally and committed to git.

### Quick Start

```bash
# 1. Download source (requires internet)
./air-gapped/scripts/download-source.sh --version 0.19.1

# 2. Vendor Go dependencies (requires docker/podman)
./air-gapped/scripts/vendor-deps.sh

# 3. Commit and push to internal git repository
git add src/
git commit -m "vendor: postgres_exporter v0.19.1"
git push

# 4. Build the image (no internet needed)
./air-gapped/scripts/build.sh --version 0.19.1
```

### download-source.sh

Downloads and extracts the upstream source tarball. Prerequisites: `bash`, `curl`, `tar`

| Flag | Default | Description |
|---|---|---|
| `--version <ver>` | `0.19.1` | postgres_exporter version to download |
| `--src-dir <path>` | `./src` | Where to extract the source |
| `--keep-existing` | off | Don't wipe `src/` before extracting |

### vendor-deps.sh

Vendors Go dependencies inside a UBI9 container. Prerequisites: `bash`, `docker` or `podman`

| Flag | Default | Description |
|---|---|---|
| `--src-dir <path>` | `./src` | Source directory containing `go.mod` |
| `--image <ref>` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Container image for vendoring |
| `--goproxy <url>` | `https://proxy.golang.org,direct` | Go module proxy URL |
| `--netrc <path>` | none | `.netrc` file for proxy authentication |

### build.sh (air-gapped)

Builds the container image from vendored source. Prerequisites: `bash`, `docker` or `podman`

| Flag | Default | Description |
|---|---|---|
| `--version <ver>` | `0.19.1` | Version to embed in the binary and image labels |
| `--arch <arch>` | `amd64` | Target architecture: `amd64` or `arm64` |
| `--registry <url>` | none | Registry prefix for tagging |
| `--push` | off | Push the image after build |
| `--scan` | off | Run a Trivy CVE scan after build |
| `--no-cache` | off | Force Docker to re-pull base images |
| `--builder-image <ref>` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Builder stage image |
| `--runtime-image <ref>` | `registry.access.redhat.com/ubi9/ubi-micro:latest` | Runtime stage image |

### Upgrading (air-gapped)

```bash
./air-gapped/scripts/download-source.sh --version 0.20.0
./air-gapped/scripts/vendor-deps.sh
git add src/
git commit -m "vendor: upgrade postgres_exporter to v0.20.0"
git push
./air-gapped/scripts/build.sh --version 0.20.0
```

---

## GoProxy Build

For environments with an internal Go proxy (e.g. Nexus, Artifactory). Dependencies are downloaded at build time — no vendoring needed.

### Quick Start

```bash
# 1. Download source (requires internet)
./air-gapped/scripts/download-source.sh --version 0.19.1

# 2. Build the image (deps fetched from internal proxy)
./goproxy/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/go-proxy/
```

No `vendor-deps.sh`, no `src/vendor/` in git, no committing source.

### With proxy authentication

If the Go proxy requires credentials, create a `~/.netrc` file:

```
machine nexus.internal
login your-username
password your-password
```

Then pass it with `--netrc`:

```bash
./goproxy/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/go-proxy/ \
  --netrc ~/.netrc
```

Credentials are mounted as a BuildKit secret during build only — they are never written into image layers.

### build.sh (goproxy)

| Flag | Default | Description |
|---|---|---|
| `--goproxy <url>` | (required) | Internal Go proxy URL |
| `--netrc <path>` | none | `.netrc` file for proxy authentication |
| `--version <ver>` | `0.19.1` | Version to embed in the binary and image labels |
| `--arch <arch>` | `amd64` | Target architecture: `amd64` or `arm64` |
| `--registry <url>` | none | Registry prefix for tagging |
| `--push` | off | Push the image after build |
| `--scan` | off | Run a Trivy CVE scan after build |
| `--no-cache` | off | Force Docker to re-pull base images |
| `--builder-image <ref>` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Builder stage image |
| `--runtime-image <ref>` | `registry.access.redhat.com/ubi9/ubi-micro:latest` | Runtime stage image |

### Upgrading (goproxy)

```bash
./air-gapped/scripts/download-source.sh --version 0.20.0
./goproxy/scripts/build.sh --version 0.20.0 \
  --goproxy https://nexus.internal/repository/go-proxy/
```

---

## Single-Stage Build

Same as GoProxy but uses a single Dockerfile stage on `ubi-minimal`. The Go toolchain is installed, source compiled, and Go removed — all in one layer. The resulting image is larger (~413 MB vs ~38 MB) but includes a shell for debugging.

### Quick Start

```bash
# 1. Download source
./air-gapped/scripts/download-source.sh --version 0.19.1

# 2. Build (single-stage, deps from proxy)
./single-stage/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/go-proxy/

# With proxy authentication:
./single-stage/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/go-proxy/ \
  --netrc ~/.netrc
```

### build.sh (single-stage)

| Flag | Default | Description |
|---|---|---|
| `--goproxy <url>` | (required) | Internal Go proxy URL |
| `--netrc <path>` | none | `.netrc` file for proxy authentication |
| `--version <ver>` | `0.19.1` | Version to embed in the binary and image labels |
| `--arch <arch>` | `amd64` | Target architecture: `amd64` or `arm64` |
| `--registry <url>` | none | Registry prefix for tagging |
| `--push` | off | Push the image after build |
| `--scan` | off | Run a Trivy CVE scan after build |
| `--no-cache` | off | Force Docker to re-pull base images |
| `--image <ref>` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Base image |

---

## Using an Internal Container Registry

All build modes support overriding the base image URLs:

```bash
# Air-gapped
./air-gapped/scripts/build.sh --version 0.19.1 \
  --builder-image nexus.internal/ubi9/ubi-minimal:latest \
  --runtime-image nexus.internal/ubi9/ubi-micro:latest

# GoProxy
./goproxy/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/go-proxy/ \
  --builder-image nexus.internal/ubi9/ubi-minimal:latest \
  --runtime-image nexus.internal/ubi9/ubi-micro:latest

# Single-Stage
./single-stage/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/go-proxy/ \
  --image nexus.internal/ubi9/ubi-minimal:latest
```

## Run

```bash
docker run --rm -e DATA_SOURCE_NAME="postgresql://user:pass@host:5432/db?sslmode=disable" \
  -p 9187:9187 postgres-exporter:0.19.1-ubi9-amd64
```

Metrics are available at `http://localhost:9187/metrics`.

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
- Air-gapped: `GOPROXY=off` enforced at build time — zero network calls during compilation
- GoProxy: credentials mounted as BuildKit secrets — never baked into image layers
- All Go dependencies auditable (in `src/vendor/` for air-gapped, via proxy logs for goproxy)
