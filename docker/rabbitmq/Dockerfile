# syntax=docker/dockerfile:1.7
FROM rabbitmq:4.2-management-alpine

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data RabbitMQ with hardened entrypoint"

# Add secrets group and add rabbitmq user to it for reading shared secrets
ARG SECRETS_GID=65532
RUN addgroup -g "${SECRETS_GID}" secrets && \
    addgroup rabbitmq secrets

RUN mkdir -p /opt/core_data/bin /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md
COPY rabbitmq/entrypoint.sh /opt/core_data/bin/rabbitmq-entrypoint.sh
COPY rabbitmq/healthcheck.sh /opt/core_data/bin/rabbitmq-healthcheck.sh
RUN chmod 755 /opt/core_data/bin/rabbitmq-entrypoint.sh /opt/core_data/bin/rabbitmq-healthcheck.sh

ENTRYPOINT ["/opt/core_data/bin/rabbitmq-entrypoint.sh"]
CMD ["rabbitmq-server"]
