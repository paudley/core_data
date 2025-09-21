#!/usr/bin/env bash
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

compose() {
  ${COMPOSE_BIN} "$@"
}

compose_exec() {
  compose exec -T --user "${POSTGRES_EXEC_USER}" "${PG_CONTAINER}" "$@"
}

compose_run() {
  compose run --rm "$@"
}

ensure_compose() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "[core_data] docker CLI not available." >&2
    exit 1
  fi
}

ensure_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[core_data] Missing .env file. Copy .env.example and customize before running commands." >&2
    exit 1
  fi
}
