#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
set -euo pipefail

CI_METADATA_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
# shellcheck disable=SC1091
source "${CI_METADATA_LIB_DIR}/common.sh"

ci_service_images() {
  local -a entries=()
  local registry=${CORE_DATA_STACK_REGISTRY:-}
  if [[ -z "${registry}" && -n "${POSTGRES_IMAGE_NAME:-}" ]]; then
    registry=${POSTGRES_IMAGE_NAME%/*}
  fi
  if [[ -z "${registry}" && -n "${CORE_DATA_IMAGE:-}" ]]; then
    registry=${CORE_DATA_IMAGE%/*}
  fi
  local release_tag=${CORE_DATA_STACK_TAG:-${POSTGRES_IMAGE_TAG:-${CORE_DATA_TAG:-latest}}}
  local registry_default=${registry:-ghcr.io/paudley/core_data}
  local postgres_image="${POSTGRES_IMAGE_NAME:-${registry_default}/postgres}:${POSTGRES_IMAGE_TAG:-${release_tag}}"
  local valkey_default="${registry_default}/valkey:${release_tag}"
  local rabbitmq_default="${registry_default}/rabbitmq:${release_tag}"
  local pgbouncer_default="${registry_default}/pgbouncer:${release_tag}"
  local memcached_default="${registry_default}/memcached:${release_tag}"
  local network_probe_default="${registry_default}/network-probe:${release_tag}"
  local network_guard_default="${registry_default}/network-guard:${release_tag}"
  entries+=("postgres=${postgres_image}")
  entries+=("logical_backup=${postgres_image}")
  entries+=("volume_prep=${postgres_image}")
  entries+=("network_probe=${NETWORK_PROBE_IMAGE:-${network_probe_default}}")
  entries+=("network_guard=${NETWORK_GUARD_IMAGE:-${network_guard_default}}")
  entries+=("valkey=${VALKEY_IMAGE:-${valkey_default}}")
  entries+=("rabbitmq=${RABBITMQ_IMAGE:-${rabbitmq_default}}")
  entries+=("pgbouncer=${PGBOUNCER_IMAGE:-${pgbouncer_default}}")
  entries+=("memcached=${MEMCACHED_IMAGE:-${memcached_default}}")
  entries+=("postgres_exporter=${POSTGRES_EXPORTER_IMAGE:-prometheuscommunity/postgres-exporter:latest}")
  entries+=("pgbouncer_exporter=${PGBOUNCER_EXPORTER_IMAGE:-prometheuscommunity/pgbouncer-exporter:latest}")
  entries+=("valkey_exporter=${VALKEY_EXPORTER_IMAGE:-oliver006/redis_exporter:latest}")
  entries+=("memcached_exporter=${MEMCACHED_EXPORTER_IMAGE:-prom/memcached-exporter:latest}")
  entries+=("node_exporter=${NODE_EXPORTER_IMAGE:-prom/node-exporter:latest}")
  entries+=("cadvisor=${CADVISOR_IMAGE:-gcr.io/cadvisor/cadvisor:latest}")
  entries+=("prometheus=${PROMETHEUS_IMAGE:-prom/prometheus:latest}")
  entries+=("grafana=${GRAFANA_IMAGE:-grafana/grafana-oss:latest}")
  printf '%s\n' "${entries[@]}"
}

ci_emit_outputs() {
  local output_path=$1
  python3 - "$output_path" << 'PY'
import json
import os
import sys

output = sys.argv[1]
root_dir = os.environ.get("ROOT_DIR", os.getcwd())
data = {
    "composeProfiles": os.environ.get("COMPOSE_PROFILES", ""),
    "services": {
        "postgres": {
            "host": os.environ.get("POSTGRES_HOST", "127.0.0.1"),
            "port": int(os.environ.get("POSTGRES_PORT", "5433")),
            "superuser": os.environ.get("POSTGRES_SUPERUSER", "postgres"),
            "passwordFile": os.path.relpath(os.environ.get("POSTGRES_SUPERUSER_PASSWORD_FILE", "secrets/postgres_superuser_password"), start=root_dir),
        },
        "pgbouncer": {
            "host": os.environ.get("PGBOUNCER_HOST", "127.0.0.1"),
            "port": int(os.environ.get("PGBOUNCER_HOST_PORT", os.environ.get("PGBOUNCER_PORT", "6432"))),
        },
        "valkey": {
            "host": os.environ.get("VALKEY_HOST", "127.0.0.1"),
            "port": int(os.environ.get("VALKEY_HOST_PORT", os.environ.get("VALKEY_PORT", "6379"))),
            "passwordFile": os.path.relpath(os.environ.get("VALKEY_PASSWORD_FILE", "secrets/valkey_password"), start=root_dir),
        },
        "prometheus": {
            "host": os.environ.get("PROMETHEUS_HOST", "127.0.0.1"),
            "port": int(os.environ.get("PROMETHEUS_HOST_PORT", "9090")),
        },
        "grafana": {
            "host": os.environ.get("GRAFANA_HOST", "127.0.0.1"),
            "port": int(os.environ.get("GRAFANA_HOST_PORT", "3000")),
            "adminUser": os.environ.get("GRAFANA_ADMIN_USER", "admin"),
        },
    },
}
out_dir = os.path.dirname(output) or "."
os.makedirs(out_dir, exist_ok=True)
with open(output, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
print(output)
PY
}
