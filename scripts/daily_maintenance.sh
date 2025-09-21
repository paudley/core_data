#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ensure_env

echo "[daily] starting"

HOST_BACKUP_ROOT=${DAILY_BACKUP_ROOT:-./backups/daily}
CONTAINER_BACKUP_ROOT=${DAILY_CONTAINER_BACKUP_ROOT:-/backups/daily}
RETENTION_DAYS=${DAILY_RETENTION_DAYS:-30}
SINCE=${DAILY_PGBADGER_SINCE:-}
if [[ -n ${SINCE} ]]; then
  if echo "${SINCE}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    SINCE="${SINCE} 00:00:00"
  elif echo "${SINCE}" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$'; then
    SINCE="${SINCE}:00"
  fi
fi
REMOVE_SOURCE=${DAILY_REMOVE_SOURCE_LOGS:-false}
PG_BADGER_JOBS=${PG_BADGER_JOBS:-2}

TIMESTAMP=$(date +%Y%m%d)
HOST_TARGET_DIR="${HOST_BACKUP_ROOT}/${TIMESTAMP}"
CONTAINER_TARGET_DIR="${CONTAINER_BACKUP_ROOT}/${TIMESTAMP}"

mkdir -p "${HOST_TARGET_DIR}"
chmod 0777 "${HOST_TARGET_DIR}"
echo "[daily] dumping databases into ${CONTAINER_TARGET_DIR}"
databases=$(compose_exec bash -lc "psql --tuples-only --no-align --dbname='${POSTGRES_DB:-postgres}' --username='${POSTGRES_SUPERUSER:-postgres}' -c \"SELECT datname FROM pg_database WHERE datistemplate = false;\"")
while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  outfile="${CONTAINER_TARGET_DIR}/${db}-$(date +%Y%m%d%H%M%S).dump.gz"
  echo "[daily]  -> ${db}"
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" bash -lc "pg_dump --format=custom --no-owner --no-acl --dbname='${db}' --username='${POSTGRES_SUPERUSER:-postgres}' | gzip > '${outfile}'"
done <<<"${databases}"

echo "[daily] creating plain SQL dump for postgres"
compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" bash -lc "pg_dump --format=plain --create --clean --if-exists --no-owner --no-acl --dbname='${POSTGRES_DB:-postgres}' --username='${POSTGRES_SUPERUSER:-postgres}' > '${CONTAINER_TARGET_DIR}/postgres.sql'"

echo "[daily] copying logs"
compose_exec bash -lc "cp /var/lib/postgresql/data/log/postgresql-*.log '${CONTAINER_TARGET_DIR}' 2>/dev/null || true"
compose_exec bash -lc "cp /var/lib/postgresql/data/log/postgresql-*.csv '${CONTAINER_TARGET_DIR}' 2>/dev/null || true"
if [[ ${REMOVE_SOURCE} == true ]]; then
  compose_exec bash -lc "rm -f /var/lib/postgresql/data/log/postgresql-*.log /var/lib/postgresql/data/log/postgresql-*.csv"
fi

echo "[daily] generating pgBadger report"
if [[ -n ${SINCE} ]]; then
  compose_exec bash -lc "pgbadger --quiet --format csv --jobs ${PG_BADGER_JOBS} --begin '${SINCE}' --outfile '${CONTAINER_TARGET_DIR}/pgbadger.html' ${CONTAINER_TARGET_DIR}/postgresql-*.csv"
else
  compose_exec bash -lc "pgbadger --quiet --format csv --jobs ${PG_BADGER_JOBS} --outfile '${CONTAINER_TARGET_DIR}/pgbadger.html' ${CONTAINER_TARGET_DIR}/postgresql-*.csv"
fi

echo "[daily] applying retention ${RETENTION_DAYS} days"
find "${HOST_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort | head -n -${RETENTION_DAYS} | xargs -r rm -rf
echo "[daily] complete"
