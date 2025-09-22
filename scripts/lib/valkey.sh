#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

VALKEY_SERVICE_NAME=${VALKEY_SERVICE_NAME:-valkey}
VALKEY_HOST=${VALKEY_HOST:-127.0.0.1}
VALKEY_PORT=${VALKEY_PORT:-6379}

valkey_exec_cli() {
  local pass_args=()
  if compose exec -T "${VALKEY_SERVICE_NAME}" test -r /run/secrets/valkey_password 2>/dev/null; then
    pass_args=(--passfile /run/secrets/valkey_password)
  elif [[ -n ${VALKEY_PASSWORD:-} ]]; then
    pass_args=(--no-auth-warning -a "${VALKEY_PASSWORD}")
  fi
  compose_exec_service "${VALKEY_SERVICE_NAME}" valkey-cli "${pass_args[@]}" -h "${VALKEY_HOST}" -p "${VALKEY_PORT}" "$@"
}

cmd_valkey_cli() {
  ensure_env
  valkey_exec_cli "$@"
}

cmd_valkey_bgsave() {
  ensure_env
  echo "[valkey] Triggering BGSAVE" >&2
  if valkey_exec_cli BGSAVE >/dev/null; then
    echo "[valkey] Background save triggered (RDB will be stored under valkey_data volume)." >&2
  else
    echo "[valkey] ERROR: BGSAVE command failed." >&2
    return 1
  fi
}
