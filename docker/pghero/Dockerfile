# syntax=docker/dockerfile:1.7
FROM ruby:3.3-slim

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data PgHero with hardened entrypoint"

ENV DEBIAN_FRONTEND=noninteractive \
    APP_ROOT=/opt/core_data/pghero

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      build-essential \
      pkg-config \
      libssl-dev \
      libpq-dev \
      libnss-wrapper \
      git \
      nodejs \
      tzdata \
      libreadline-dev \
      libyaml-dev && \
    rm -rf /var/lib/apt/lists/*

RUN gem install bundler pg puma

RUN mkdir -p ${APP_ROOT}

WORKDIR ${APP_ROOT}

RUN git clone --depth 1 https://github.com/ankane/pghero.git ${APP_ROOT} && \
    bundle config set without 'development test' && \
    bundle install --jobs=4 --retry=3

RUN mkdir -p /opt/core_data/scripts /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md
COPY scripts/pghero_entrypoint.sh /opt/core_data/scripts/pghero_entrypoint.sh
RUN chmod 755 /opt/core_data/scripts/pghero_entrypoint.sh

ENTRYPOINT ["/bin/sh", "/opt/core_data/scripts/pghero_entrypoint.sh"]
