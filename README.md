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
│   ├── vendor-source.sh        # Downloads source + vendors Go deps (needs internet)
│   └── build.sh                # Builds the Docker image (offline)
└── src/                        # Vendored source — committed to git
    ├── go.mod / go.sum
    ├── cmd/postgres_exporter/
    └── vendor/                 # Go dependencies (go mod vendor output)
```

## Quick Start

### 1. Vendor the source (once, requires internet)

The build is designed for air-gapped environments. Before you can build the
image, you need to download the postgres_exporter source code and bundle all
Go dependencies into the repository. This is done once on a machine with
internet access using `scripts/vendor-source.sh`.

#### Prerequisites

| Tool | Minimum version | Check with |
|---|---|---|
| `bash` | 4.0+ | `bash --version` |
| `curl` | any | `curl --version` |
| `tar` | any | `tar --version` |
| `go` | 1.21+ | `go version` |
| `git` | any | `git --version` |

You also need internet access to `github.com` and `proxy.golang.org`.

#### Run the vendor script

```bash
# Default: vendors postgres_exporter v0.19.1 into ./src/
./scripts/vendor-source.sh

# Or specify a version explicitly
./scripts/vendor-source.sh --version 0.19.1
```

The script runs four steps automatically:

1. Downloads the source tarball from GitHub (verifies SHA-256 if available)
2. Extracts it into `src/`
3. Runs `go mod download` + `go mod vendor` to bundle all Go dependencies
4. Compiles the binary once to verify the vendor directory is complete

When finished, `src/` contains the full source tree and `src/vendor/` contains
all Go dependencies — everything needed for an offline build.

#### Options

| Flag | Default | Description |
|---|---|---|
| `--version <ver>` | `0.19.1` | postgres_exporter version to download |
| `--src-dir <path>` | `./src` | Where to place the vendored source |
| `--keep-existing` | off | Don't wipe `src/` before extracting (useful for re-vendoring) |
| `-h`, `--help` | | Print usage information |

#### Commit the result

After the script completes, commit `src/` so that CI and other developers can
build without internet:

```bash
git add src/
git commit -m "vendor: postgres_exporter v0.19.1"
git push
```

> **Note:** `src/vendor/` adds ~15-20 MB to the repository. This is the
> expected trade-off for fully reproducible, offline builds.

### 2. Build the image (offline)

Once `src/` is committed, no internet access is needed. Run:

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
| `-h`, `--help` | | Print usage information |

### 3. Run

```bash
docker run --rm -e DATA_SOURCE_NAME="postgresql://user:pass@host:5432/db?sslmode=disable" \
  -p 9187:9187 postgres-exporter:0.19.1-ubi9-amd64
```

Metrics are available at `http://localhost:9187/metrics`.

## Upgrading

Re-run the vendor script with the new version, then rebuild:

```bash
./scripts/vendor-source.sh --version 0.20.0
git add src/
git commit -m "vendor: upgrade postgres_exporter to v0.20.0"
git push

./scripts/build.sh --version 0.20.0
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
