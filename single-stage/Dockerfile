# =============================================================================
#  postgres_exporter – Runtime Dockerfile (ubi-minimal)
#
#  Packages a pre-compiled postgres_exporter binary into ubi-minimal.
#  The binary must be compiled before running docker build.
#
#  Build:
#    docker build \
#      --build-arg POSTGRES_EXPORTER_VERSION=0.19.1 \
#      -t postgres-exporter:0.19.1-ubi9 .
# =============================================================================

ARG UBI_MINIMAL_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest

FROM ${UBI_MINIMAL_IMAGE}

ARG POSTGRES_EXPORTER_VERSION=0.19.1
ARG VCS_REF=unknown
ARG BUILD_DATE

LABEL maintainer="The Prometheus Authors <prometheus-developers@googlegroups.com>" \
      org.opencontainers.image.title="postgres_exporter" \
      org.opencontainers.image.description="Prometheus exporter for PostgreSQL server metrics" \
      org.opencontainers.image.version="${POSTGRES_EXPORTER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/prometheus-community/postgres_exporter" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="Prometheus Community" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/ubi-minimal"

RUN microdnf install -y ca-certificates \
    && microdnf clean all \
    && rm -rf /var/cache/dnf

COPY postgres_exporter /usr/local/bin/postgres_exporter
RUN chmod 0755 /usr/local/bin/postgres_exporter

RUN echo "postgres_exporter:x:65534:0:postgres_exporter:/:/sbin/nologin" \
      >> /etc/passwd \
    && echo "postgres_exporter:x:65534:" \
      >> /etc/group

USER 65534:0
EXPOSE 9187
ENTRYPOINT ["/usr/local/bin/postgres_exporter"]
