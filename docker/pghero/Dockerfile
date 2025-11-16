# syntax=docker/dockerfile:1.7
ARG PGHERO_BASE_TAG=latest
FROM ankane/pghero:${PGHERO_BASE_TAG}

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data PgHero with hardened entrypoint"

RUN apk add --no-cache curl build-base cmake && \
    curl -fsSL https://ftp.samba.org/pub/cwrap/nss_wrapper-1.1.16.tar.gz -o /tmp/nss_wrapper.tar.gz && \
    tar -xzf /tmp/nss_wrapper.tar.gz -C /tmp && \
    mkdir -p /tmp/nss_wrapper-build && \
    cd /tmp/nss_wrapper-build && \
    cmake /tmp/nss_wrapper-* && \
    make && make install && \
    cd / && rm -rf /tmp/nss_wrapper* /tmp/nss_wrapper-build /tmp/nss_wrapper.tar.gz && \
    apk del build-base cmake curl

RUN mkdir -p /opt/core_data/scripts /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md
COPY scripts/pghero_entrypoint.sh /opt/core_data/scripts/pghero_entrypoint.sh
RUN chmod 755 /opt/core_data/scripts/pghero_entrypoint.sh

ENTRYPOINT ["/bin/sh", "/opt/core_data/scripts/pghero_entrypoint.sh"]
