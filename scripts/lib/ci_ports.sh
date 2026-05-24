#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
set -euo pipefail

CI_PORTS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
# shellcheck disable=SC1091
source "${CI_PORTS_LIB_DIR}/common.sh"

ci_port_available() {
  local port=$1
  python3 - "$port" << 'PY' > /dev/null 2>&1
import socket
import sys

port = int(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        sys.exit(1)
sys.exit(0)
PY
}

ci_check_ports() {
  local skip=$1
  shift
  if [[ "${skip}" == "true" ]]; then
    return 0
  fi
  local failures=0
  for mapping in "$@"; do
    local name=${mapping%%:*}
    local port=${mapping##*:}
    if [[ -z "${port}" ]]; then
      continue
    fi
    if ! ci_port_available "${port}"; then
      echo "[ci] port ${port} for ${name} appears to be in use." >&2
      failures=$((failures + 1))
    else
      ci_log "port ${port} for ${name} available."
    fi
  done
  if ((failures > 0)); then
    return 1
  fi
  return 0
}

ci_check_required_ports() {
  local skip_ports=$1
  ci_check_ports "${skip_ports}" \
    "postgres:${POSTGRES_PORT:-5433}" \
    "pgbouncer:${PGBOUNCER_HOST_PORT:-${PGBOUNCER_PORT:-6432}}" \
    "pgbouncer-extra:${PGBOUNCER_EXTRA_HOST_PORT:-5432}" \
    "valkey:${VALKEY_HOST_PORT:-${VALKEY_PORT:-6379}}" \
    "memcached:${MEMCACHED_PORT:-11211}" \
    "rabbitmq:${RABBITMQ_HOST_PORT:-${RABBITMQ_PORT:-5672}}" \
    "rabbitmq-management:${RABBITMQ_MANAGEMENT_HOST_PORT:-${RABBITMQ_MANAGEMENT_PORT:-15672}}" \
    "rabbitmq-prometheus:${RABBITMQ_PROMETHEUS_HOST_PORT:-${RABBITMQ_PROMETHEUS_PORT:-15692}}" \
    "rabbitmq-stream:${RABBITMQ_STREAM_HOST_PORT:-${RABBITMQ_STREAM_PORT:-5552}}" \
    "prometheus:${PROMETHEUS_HOST_PORT:-9090}" \
    "grafana:${GRAFANA_HOST_PORT:-3000}" \
    "postgres-exporter:${POSTGRES_EXPORTER_HOST_PORT:-9187}" \
    "pgbouncer-exporter:${PGBOUNCER_EXPORTER_HOST_PORT:-9127}" \
    "valkey-exporter:${VALKEY_EXPORTER_HOST_PORT:-9121}" \
    "memcached-exporter:${MEMCACHED_EXPORTER_HOST_PORT:-9150}" \
    "node-exporter:${NODE_EXPORTER_HOST_PORT:-9100}" \
    "cadvisor:${CADVISOR_HOST_PORT:-8080}"
}
