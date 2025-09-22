#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Common helpers shared by manage.sh and supporting scripts.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMPOSE_BIN=${COMPOSE_BIN:-docker compose}
POSTGRES_SERVICE_NAME=${POSTGRES_SERVICE_NAME:-postgres}
PG_CONTAINER=${PG_CONTAINER:-${POSTGRES_SERVICE_NAME}}
ENV_FILE=${ENV_FILE:-${ROOT_DIR}/.env}
PGBACKREST_CONF=${PGBACKREST_CONF:-/var/lib/postgresql/data/pgbackrest.conf}
POSTGRES_HOST=${POSTGRES_HOST:-localhost}
POSTGRES_EXEC_USER=${POSTGRES_EXEC_USER:-postgres}

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
else
  echo "[core_data] WARNING: ${ENV_FILE} not found; using defaults where possible." >&2
fi

HOST_UID=$(id -u)
HOST_GID=$(id -g)
POSTGRES_UID=${POSTGRES_UID:-${HOST_UID}}
POSTGRES_GID=${POSTGRES_GID:-${HOST_GID}}
POSTGRES_RUNTIME_USER=${POSTGRES_RUNTIME_USER:-postgres}
POSTGRES_RUNTIME_GECOS=${POSTGRES_RUNTIME_GECOS:-"Core Data PostgreSQL"}
POSTGRES_RUNTIME_HOME=${POSTGRES_RUNTIME_HOME:-/home/postgres}
export POSTGRES_UID POSTGRES_GID POSTGRES_RUNTIME_USER POSTGRES_RUNTIME_GECOS POSTGRES_RUNTIME_HOME

load_secret_from_file() {
  local var_name=$1
  local file_var_name="${var_name}_FILE"
  local current_value="${!var_name-}"
  local file_path="${!file_var_name-}"

  if [[ -n "${current_value}" ]]; then
    return
  fi

  if [[ -n "${file_path}" ]]; then
    if [[ -r "${file_path}" ]]; then
      local secret
      secret=$(tr -d '\r\n' <"${file_path}")
      export "${var_name}=${secret}"
    else
      echo "[core_data] WARNING: unable to read ${file_var_name}=${file_path}" >&2
    fi
  fi
}

load_secret_from_file POSTGRES_SUPERUSER_PASSWORD
load_secret_from_file VALKEY_PASSWORD
load_secret_from_file PGBOUNCER_AUTH_PASSWORD
load_secret_from_file PGBOUNCER_STATS_PASSWORD

compose_exec_service() {
  local service=$1
  shift
  compose exec -T "$service" "$@"
}

compose_has_service() {
  local service=$1
  compose config --services 2>/dev/null | grep -Fxq "${service}"
}

# compose runs docker compose with the arguments provided.
compose() {
  ${COMPOSE_BIN} "$@"
}

# compose_exec runs docker compose exec with the postgres user (no TTY).
compose_exec() {
  compose exec -T --user "${POSTGRES_EXEC_USER}" "${PG_CONTAINER}" "$@"
}

# compose_run runs docker compose run for ephemeral helper containers.
compose_run() {
  compose run --rm "$@"
}

# ensure_compose exits early if the docker CLI is not available.
ensure_compose() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "[core_data] docker CLI not available." >&2
    exit 1
  fi
}

# ensure_env makes sure a populated .env file exists before continuing.
ensure_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[core_data] Missing .env file. Copy .env.example and customize before running commands." >&2
    exit 1
  fi
}
