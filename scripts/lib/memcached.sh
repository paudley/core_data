#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

MEMCACHED_SERVICE_NAME=${MEMCACHED_SERVICE_NAME:-memcached}
MEMCACHED_HOST=${MEMCACHED_HOST:-127.0.0.1}
MEMCACHED_PORT=${MEMCACHED_PORT:-11211}

cmd_memcached_stats() {
  ensure_env
  compose_exec_service "${MEMCACHED_SERVICE_NAME}" sh -c "printf 'stats\\r\\n' | nc -w 2 ${MEMCACHED_HOST} ${MEMCACHED_PORT}"
}
