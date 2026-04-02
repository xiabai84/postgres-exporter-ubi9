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

```bash
./scripts/vendor-source.sh --version 0.19.1
git add src/
git commit -m "vendor: postgres_exporter v0.19.1"
```

Options: `--version <ver>`, `--src-dir <path>`, `--keep-existing`

### 2. Build the image (offline)

```bash
./scripts/build.sh --version 0.19.1
```

Produces: `postgres-exporter:0.19.1-ubi9-amd64`

Options:

| Flag | Description |
|---|---|
| `--version <ver>` | Version to embed (default: `0.19.1`) |
| `--arch <arch>` | `amd64` or `arm64` (default: `amd64`) |
| `--registry <url>` | Registry prefix for tagging |
| `--push` | Push after build (requires `--registry`) |
| `--scan` | Run Trivy CVE scan after build |
| `--no-cache` | Force fresh base image pull |

### 3. Run

```bash
docker run --rm -e DATA_SOURCE_NAME="postgresql://user:pass@host:5432/db?sslmode=disable" \
  -p 9187:9187 postgres-exporter:0.19.1-ubi9-amd64
```

## Upgrading

```bash
./scripts/vendor-source.sh --version 0.20.0
git add src/
git commit -m "vendor: upgrade postgres_exporter to v0.20.0"
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
