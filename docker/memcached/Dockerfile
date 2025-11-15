# syntax=docker/dockerfile:1.7
FROM memcached:1.6-alpine

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data Memcached"

RUN mkdir -p /opt/core_data/docs
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md
