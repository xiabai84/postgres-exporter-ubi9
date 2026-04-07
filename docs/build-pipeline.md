# Build Pipeline: From Source to Container Image

This document explains how the three scripts work together to produce a
postgres_exporter container image, with a focus on how Go manages dependencies
through the vendor directory for air-gapped builds.

## Overview

The build pipeline has three stages, each handled by a separate script.
The first two run on a developer workstation with internet access.
The third runs on an air-gapped CI agent with only Docker/Podman available.

```
                Internet boundary
                     |
  download-source.sh | vendor-deps.sh          build.sh
  (curl, tar)        | (docker/podman)         (docker/podman)
                     |
  ┌────────────┐     | ┌──────────────┐        ┌──────────────────┐
  │ GitHub     │     | │ UBI9 container│        │ Dockerfile       │
  │ tarball    │────>| │ go mod vendor │──────> │ COPY src/ /build │
  │ v0.19.1    │     | │              │  src/   │ go build -mod=   │
  └────────────┘     | └──────────────┘ vendor/ │   vendor         │
        │            |       │                  │                  │
        v            |       v                  │  ┌────────────┐  │
    src/go.mod       | src/vendor/              │  │ static ELF │  │
    src/go.sum       | src/vendor/modules.txt   │  │ binary     │  │
    src/cmd/         | src/vendor/github.com/   │  └─────┬──────┘  │
    src/collector/   | src/vendor/golang.org/   │        │         │
                     |                          │        v         │
                     |                          │  ubi9-micro      │
                     |                          │  (38 MB image)   │
                     |                          └──────────────────┘
```

## Stage 1: download-source.sh

**Purpose:** Download and extract the upstream source code.

**Needs:** `curl`, `tar` (no Docker, no Go)

```bash
./scripts/download-source.sh --version 0.19.1
```

**What it does:**

1. Downloads the release tarball from GitHub:
   `https://github.com/prometheus-community/postgres_exporter/archive/refs/tags/v0.19.1.tar.gz`

2. Attempts to verify SHA-256 checksum against the upstream release checksums.

3. Extracts into `src/`, producing the Go source tree:

```
src/
├── go.mod                 ← module definition (name + Go version + dependencies)
├── go.sum                 ← cryptographic checksums for every dependency version
├── cmd/
│   └── postgres_exporter/ ← main package (entrypoint)
├── collector/             ← Prometheus metric collectors
├── config/                ← configuration loading
└── exporter/              ← core exporter logic
```

At this point `src/` has source code but no dependencies. The code cannot be
compiled yet because `import` statements reference external packages that are
not present on disk.

## Stage 2: vendor-deps.sh

**Purpose:** Download all Go dependencies and bundle them into `src/vendor/`.

**Needs:** `docker` or `podman` (no Go installation on the host)

```bash
./scripts/vendor-deps.sh
```

**What it does:**

The script starts a temporary UBI9 container, installs the Go toolchain via
`microdnf`, and runs the Go module commands against the mounted `src/` directory.

### How Go module vendoring works

Go modules use three files to manage dependencies:

**`go.mod`** declares the module name, required Go version, and direct
dependencies with their versions:

```
module github.com/prometheus-community/postgres_exporter

go 1.24.0

require (
    github.com/lib/pq v1.10.9
    github.com/prometheus/client_golang v1.21.1
    github.com/prometheus/common v0.63.0
    ...
)
```

**`go.sum`** contains SHA-256 checksums for every dependency (including
transitive ones). Go uses this to verify that downloaded modules have not been
tampered with:

```
github.com/lib/pq v1.10.9 h1:YXG7RB+JIjhP29X+OtkiDnYaXQwpS4JEWq7dtCCRUEw=
github.com/lib/pq v1.10.9/go.mod h1:AlVN5x4E4T544tWzH6hKFbGRn7nbIqu9HhEDnDfBij=
```

**`vendor/`** is a directory created by `go mod vendor` that contains a
local copy of all dependency source code. When present, `go build -mod=vendor`
reads dependencies from this directory instead of downloading them from the
internet.

### The three Go commands

The script runs three commands inside the container:

**`go mod download`** fetches all modules listed in `go.mod` (and their
transitive dependencies) from `proxy.golang.org` into the container's module
cache (`$GOPATH/pkg/mod/`). This is the only step that requires internet.

**`go mod verify`** checks that every downloaded module matches its checksum
in `go.sum`. If any module has been modified after download (corrupted mirror,
MITM attack), this command fails.

**`go mod vendor`** copies all dependency source code from the module cache
into `src/vendor/`, organized by import path:

```
src/vendor/
├── modules.txt                          ← manifest: which modules are vendored
├── github.com/
│   ├── lib/pq/                          ← PostgreSQL driver
│   ├── prometheus/
│   │   ├── client_golang/prometheus/    ← Prometheus client library
│   │   ├── client_model/go/            ← Prometheus metric data model
│   │   └── common/                      ← shared Prometheus utilities
│   └── ...
├── golang.org/x/
│   ├── crypto/                          ← supplementary crypto packages
│   ├── net/                             ← supplementary network packages
│   └── ...
└── google.golang.org/protobuf/          ← protocol buffers runtime
```

The key file is **`vendor/modules.txt`**. It is the manifest that tells
`go build -mod=vendor` which module each vendored package belongs to:

```
# github.com/lib/pq v1.10.9
## explicit; go 1.13
github.com/lib/pq
github.com/lib/pq/oid
github.com/lib/pq/scram
```

Each `#` line declares a module and version. The `## explicit` marker means
this module is a direct dependency (listed in `go.mod`). The indented lines
list the packages from that module that are actually imported by the project.

### Verification build

After vendoring, the script runs a test compilation:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS="-mod=vendor" \
  go build -o /dev/null ./cmd/postgres_exporter
```

This proves that:
- All required packages are present in `vendor/`
- The code compiles for the target platform (linux/amd64)
- No missing or incompatible dependencies

The binary is discarded (`-o /dev/null`) — this is only a validation step.

### After vendoring

The `src/` directory now contains everything needed for an offline build:

```
src/
├── go.mod          ← what to build
├── go.sum          ← checksums to verify integrity
├── cmd/            ← source code
├── collector/
├── config/
├── exporter/
└── vendor/         ← all dependencies, locally bundled
    └── modules.txt ← vendor manifest
```

This is committed to git and pushed to the internal repository:

```bash
git add src/
git commit -m "vendor: postgres_exporter v0.19.1"
git push
```

## Stage 3: build.sh + Dockerfile

**Purpose:** Compile the binary and produce the container image.

**Needs:** `docker` or `podman` (no internet access required)

```bash
./scripts/build.sh --version 0.19.1
```

### How the Dockerfile uses the vendor directory

The Dockerfile is a two-stage build. The builder stage enforces a fully
offline build through four environment variables:

```dockerfile
ENV GOPROXY="off"           # hard-fail if Go tries to download anything
    GOFLAGS="-mod=vendor"   # always read dependencies from vendor/
    GONOSUMDB="*"           # skip checksum database lookups
    GONOSUMCHECK="*"        # skip sum verification network calls
```

**`GOPROXY=off`** is the critical setting. Normally, Go downloads missing
modules from `proxy.golang.org`. Setting this to `off` causes an immediate
build failure if any module is not found in `vendor/`. This turns a potential
silent network call in an air-gapped environment (which would hang
indefinitely) into a clear, fast error.

**`GOFLAGS="-mod=vendor"`** tells every `go` command to resolve imports from
`vendor/` instead of `$GOPATH/pkg/mod/`. Without this, Go would look for a
module cache that does not exist in the container, fail, and attempt to
download — which would then be blocked by `GOPROXY=off`.

The build command itself:

```dockerfile
COPY src/ /build/

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -mod=vendor -trimpath \
      -ldflags="-s -w ..." \
      -o /build/postgres_exporter \
      ./cmd/postgres_exporter
```

When Go processes `import "github.com/lib/pq"`, it:

1. Reads `vendor/modules.txt` to find which module provides the `github.com/lib/pq` package
2. Finds the source files at `vendor/github.com/lib/pq/*.go`
3. Compiles them — no network access, no module cache, no proxy

**`CGO_ENABLED=0`** produces a statically linked binary with zero libc
dependency. This is essential because the runtime image (`ubi9-micro`) has no
shared libraries.

**`-trimpath`** removes the build host's filesystem paths from the binary,
preventing information leakage.

### Runtime stage

The second Dockerfile stage copies only three things from the builder:

```
ubi9-micro (no shell, no package manager)
├── /etc/ssl/certs/ca-bundle.crt         ← TLS certificates
├── /etc/passwd + /etc/group             ← user identity
└── /usr/local/bin/postgres_exporter     ← static binary (one file)
```

The final image is ~38 MB.

## Putting it all together

```
Developer workstation                    Air-gapped CI
═══════════════════════                  ═══════════════

1. download-source.sh
   curl → GitHub
   tar → src/
         │
2. vendor-deps.sh
   docker run ubi9-minimal
     microdnf install golang
     go mod download  ← internet
     go mod verify    ← checksums
     go mod vendor    ← copy to src/vendor/
     go build         ← verify
         │
3. git add src/
   git commit
   git push ─────────────────────────>  git clone/pull
                                              │
                                        4. build.sh
                                           docker build
                                             GOPROXY=off
                                             COPY src/ /build/
                                             go build -mod=vendor
                                             → static binary
                                             → ubi9-micro image
```

**The key insight:** Steps 1-2 require internet. Step 3 transfers the result
via git. Step 4 needs zero internet access — every byte of source code and
every dependency is already inside `src/vendor/`, committed to the repository.
