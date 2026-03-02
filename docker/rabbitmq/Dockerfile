# syntax=docker/dockerfile:1.7
FROM rabbitmq:4.2-management-alpine

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data RabbitMQ with hardened entrypoint and core plugins"

# Enable tier-1 core plugins required by the cognitive architecture and
# production operations tooling.  The management image already enables
# rabbitmq_management, rabbitmq_management_agent, rabbitmq_web_dispatch,
# and rabbitmq_prometheus.
#
# Core requirements:
#   consistent_hash_exchange – session affinity for LLM prefix-cache
#   stream / stream_management – append-only Cognitive_Stream, Dreaming offsets
#
# Production operations:
#   shovel / shovel_management – queue draining, dead-letter reprocessing
#   event_exchange            – broker events as AMQP messages (observability)
#   tracing                   – message-level tracing via management UI
#   top                       – per-process resource monitoring
RUN rabbitmq-plugins enable --offline \
    rabbitmq_consistent_hash_exchange \
    rabbitmq_stream \
    rabbitmq_stream_management \
    rabbitmq_shovel \
    rabbitmq_shovel_management \
    rabbitmq_event_exchange \
    rabbitmq_tracing \
    rabbitmq_top

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
