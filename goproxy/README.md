# GoProxy Multi-Stage Build

Builds the postgres_exporter container image using an internal Go module proxy (e.g. Nexus). Dependencies are downloaded at build time inside Docker — no vendoring, no `src/vendor/` in git.

## How It Works

```
Developer workstation                    Jenkins CI (cing-go agent)
════════════════════                     ═══════════════════════════

download-source.sh                      checkout scm
  └─ curl → GitHub tarball                └─ src/ already in repo
  └─ tar → src/
git add src/ && git commit && push      build.sh --goproxy <url> --netrc <path>
                                          └─ docker build
                                               ├─ Stage 1 (builder): ubi-minimal
                                               │    microdnf install golang
                                               │    COPY src/ /build/
                                               │    go mod download (via GOPROXY → Nexus)
                                               │    go build → static binary
                                               │
                                               └─ Stage 2 (runtime): ubi-micro
                                                    COPY binary + ca-certs + passwd
                                                    → ~38 MB image
```

The developer commits only source code (`src/` without `vendor/`). The CI pipeline runs `build.sh` which calls `docker build`. All Go dependency resolution happens inside the Docker builder stage via the internal proxy.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build: compile in ubi-minimal, run in ubi-micro |
| `.dockerignore` | Excludes non-essential files from the build context |
| `scripts/build.sh` | Wrapper around `docker build` with all build-args and secret handling |
| `Jenkinsfile` | Jenkins pipeline: checkout → build image → push |

## Dockerfile Details

### Stage 1 — Builder (`ubi-minimal`)

```
FROM ubi-minimal AS builder
  │
  ├─ microdnf install golang ca-certificates
  │
  ├─ COPY src/ /build/
  │
  ├─ RUN --mount=type=secret,id=netrc,target=/root/.netrc
  │      GOPROXY="${GOPROXY}" go mod download && go mod verify
  │
  ├─ CGO_ENABLED=0 go build -trimpath -ldflags="..." -o postgres_exporter
  │
  ├─ Smoke-test: --version + ldd (assert static linking)
  │
  └─ Create /etc/passwd + /etc/group entries for UID 65534
```

**Dependency download (`go mod download`):** Go fetches modules from the URL provided via the `GOPROXY` build-arg. This is your internal Nexus Go proxy repository, which caches modules from `proxy.golang.org`. The download step is the only network-dependent operation in the build.

**Authentication:** If the proxy requires credentials, a `.netrc` file is mounted as a BuildKit secret (`--mount=type=secret,id=netrc`). The secret is available only during the `RUN` instruction — it is never written to any image layer and cannot be extracted from the final image.

**Static binary:** `CGO_ENABLED=0` produces a pure Go binary with zero libc dependency. This is essential because the runtime image (`ubi-micro`) has no shared libraries. The `ldd` smoke-test verifies static linking.

**ldflags:** Version metadata is injected at compile time via `-X` linker flags. This populates the `--version` output without requiring git or version files at runtime.

### Stage 2 — Runtime (`ubi-micro`)

```
FROM ubi-micro
  │
  ├─ COPY ca-bundle.crt          (TLS trust anchors for PostgreSQL connections)
  ├─ COPY /etc/passwd + group    (named identity for UID 65534)
  ├─ COPY postgres_exporter      (static binary, 0755)
  │
  ├─ USER 65534:0                (non-root, OpenShift arbitrary-UID compatible)
  ├─ EXPOSE 9187
  └─ ENTRYPOINT ["/usr/local/bin/postgres_exporter"]
```

Only three artifacts cross the stage boundary. The final image is ~38 MB with no shell, no package manager, no compilers.

### Build-args

| Arg | Default | Description |
|-----|---------|-------------|
| `GOPROXY` | (none, required) | Internal Go proxy URL |
| `UBI_MINIMAL_IMAGE` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Builder base image |
| `UBI_MICRO_IMAGE` | `registry.access.redhat.com/ubi9/ubi-micro:latest` | Runtime base image |
| `POSTGRES_EXPORTER_VERSION` | `0.19.1` | Version embedded in binary |
| `TARGETOS` | `linux` | Target OS |
| `TARGETARCH` | `amd64` | Target architecture |
| `VCS_REF` | `unknown` | Git commit SHA |
| `BUILD_DATE` | auto | ISO 8601 build timestamp |

## Jenkinsfile Details

### Pipeline stages

```
Checkout  →  Build Image  →  Push Image
```

**Checkout:** `checkout scm` — source code (`src/`) is already committed to the repository.

**Build Image:** Creates a temporary `.netrc` file from Jenkins credentials (`nexus-credentials`), then calls `build.sh` which runs `docker build` with:
- `--build-arg GOPROXY=...` — the internal proxy URL, composed from `NEXUS_URL` + `NEXUS_REPOSITORY`
- `--secret id=netrc,src=...` — the `.netrc` file for proxy authentication (BuildKit secret)
- All other build-args (version, arch, VCS ref, build date)

The `.netrc` file is created inside a `withCredentials` block and cleaned up via `trap` on exit.

**Push Image:** Placeholder for your shared library integration.

### Environment variables

| Variable | Value | Description |
|----------|-------|-------------|
| `APP` | `postgres-exporter` | Image name |
| `NEXUS_URL` | `https://nexus.internal` | Nexus base URL |
| `NEXUS_REPOSITORY` | `internet-go-proxy.golang.org-proxy` | Go proxy repository name |
| `VERSION` | `0.19.1` | postgres_exporter version |
| `GOPROXY` | `${NEXUS_URL}/repository/${NEXUS_REPOSITORY}/` | Composed proxy URL |

### Jenkins prerequisites

- **Agent label:** `cing-go` — must have Docker or Podman installed
- **Credential:** `nexus-credentials` — username/password type for Nexus authentication

### Credential flow

```
Jenkins Credential Store
  └─ nexus-credentials (username/password)
       │
       ▼
withCredentials block
  └─ NEXUS_USER, NEXUS_PASS env vars
       │
       ▼
Temporary .netrc file (mktemp)
  └─ machine nexus.internal / login / password
       │
       ▼
build.sh --netrc <path>
  └─ docker build --secret id=netrc,src=<path>
       │
       ▼
Dockerfile: RUN --mount=type=secret,id=netrc,target=/root/.netrc
  └─ go mod download (authenticates via .netrc)
       │
       ▼
Secret discarded — never in image layers
```

## build.sh Reference

| Flag | Default | Description |
|---|---|---|
| `--goproxy <url>` | (required) | Internal Go proxy URL |
| `--netrc <path>` | none | `.netrc` file for proxy authentication |
| `--version <ver>` | `0.19.1` | Version to embed |
| `--arch <arch>` | `amd64` | Target architecture |
| `--registry <url>` | none | Registry prefix for tagging |
| `--push` | off | Push after build |
| `--scan` | off | Trivy CVE scan after build |
| `--no-cache` | off | Force fresh base image pull |
| `--builder-image <ref>` | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | Builder image |
| `--runtime-image <ref>` | `registry.access.redhat.com/ubi9/ubi-micro:latest` | Runtime image |

## Local Usage

```bash
# Download source (once)
./air-gapped/scripts/download-source.sh --version 0.19.1

# Build with public proxy (for local testing)
./goproxy/scripts/build.sh --version 0.19.1 \
  --goproxy "https://proxy.golang.org,direct"

# Build with internal proxy + auth
./goproxy/scripts/build.sh --version 0.19.1 \
  --goproxy https://nexus.internal/repository/internet-go-proxy.golang.org-proxy/ \
  --netrc ~/.netrc
```
