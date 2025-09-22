#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Orchestrates dumps, log capture, pgBadger reports, and retention pruning.
# Intended to be called by manage.sh daily-maintenance.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/audit.sh
source "${SCRIPT_DIR}/lib/audit.sh"

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
PG_STAT_LIMIT=${DAILY_PG_STAT_LIMIT:-100}
BUFFERCACHE_LIMIT=${DAILY_BUFFERCACHE_LIMIT:-50}
DEAD_TUPLE_THRESHOLD=${DAILY_DEAD_TUPLE_THRESHOLD:-100000}
DEAD_TUPLE_RATIO=${DAILY_DEAD_TUPLE_RATIO:-0.2}
REPLICATION_LAG_THRESHOLD=${DAILY_REPLICATION_LAG_THRESHOLD:-300}
INDEX_MIN_SIZE_MB=${DAILY_INDEX_MIN_SIZE_MB:-10}
GENERATE_HTML=${DAILY_HTML_REPORT:-true}
EMAIL_REPORT=${DAILY_EMAIL_REPORT:-false}
REPORT_RECIPIENT=${DAILY_REPORT_RECIPIENT:-}

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

echo "[daily] capturing pg_stat_statements baseline"
snapshot_pg_stat_statements "${CONTAINER_TARGET_DIR}/pg_stat_statements.csv" "${PG_STAT_LIMIT}" || true

echo "[daily] snapshotting buffer cache allocation"
audit_pg_buffercache "${CONTAINER_TARGET_DIR}/pg_buffercache.csv" "${BUFFERCACHE_LIMIT}" || true

echo "[daily] running pg_partman maintenance"
while IFS= read -r db; do
  [[ -z "${db}" ]] && continue
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" <<'SQL' >/dev/null || true
SELECT n.nspname AS partman_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'pg_partman'
\gset
\if :{?partman_schema}
SELECT format('CALL %I.run_maintenance_proc();', :'partman_schema');
\gexec
\endif
SQL
done <<<"${databases}"

echo "[daily] auditing roles"
audit_roles "${CONTAINER_TARGET_DIR}/role_audit.csv" || true

echo "[daily] auditing extensions"
audit_extensions "${CONTAINER_TARGET_DIR}/extension_audit.csv" || true

echo "[daily] auditing autovacuum health"
audit_autovacuum "${CONTAINER_TARGET_DIR}/autovacuum_findings.csv" "${DEAD_TUPLE_THRESHOLD}" "${DEAD_TUPLE_RATIO}" || true

echo "[daily] auditing replication lag"
audit_replication_lag "${CONTAINER_TARGET_DIR}/replication_lag.csv" "${REPLICATION_LAG_THRESHOLD}" || true

echo "[daily] auditing security posture"
audit_security "${CONTAINER_TARGET_DIR}/security_audit.txt" || true

echo "[daily] auditing pg_cron schedule"
audit_pg_cron "${CONTAINER_TARGET_DIR}/cron_schedule.csv" || true

echo "[daily] auditing pg_squeeze activity"
audit_pg_squeeze "${CONTAINER_TARGET_DIR}/pg_squeeze.csv" || true

echo "[daily] auditing index bloat"
audit_index_bloat "${CONTAINER_TARGET_DIR}/index_bloat.csv" "${INDEX_MIN_SIZE_MB}" || true

echo "[daily] capturing schema snapshot"
audit_schema_snapshot "${CONTAINER_TARGET_DIR}/schema_snapshot.csv" || true

echo "[daily] summarizing pgaudit events"
summarize_pgaudit_logs "${CONTAINER_TARGET_DIR}" || true

if [[ ${GENERATE_HTML} == true ]]; then
  echo "[daily] generating html maintenance summary"
  compose_exec python3 /opt/core_data/scripts/generate_report.py \
    --input "${CONTAINER_TARGET_DIR}" \
    --output "${CONTAINER_TARGET_DIR}/maintenance_report.html" || true
fi

if [[ ${EMAIL_REPORT} == true && -n ${REPORT_RECIPIENT} ]]; then
  echo "[daily] emailing maintenance report to ${REPORT_RECIPIENT}"
  compose_exec bash -lc "if command -v sendmail >/dev/null 2>&1; then \n    ( \n      echo 'To: ${REPORT_RECIPIENT}'; \n      echo 'Subject: core_data maintenance report'; \n      echo 'Content-Type: text/html'; \n      echo; \n      cat '${CONTAINER_TARGET_DIR}/maintenance_report.html'; \n    ) | sendmail -t \n  else \n    echo '[daily] sendmail not available in container' >&2; \n  fi" || true
fi

echo "[daily] applying retention ${RETENTION_DAYS} days"
find "${HOST_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort | head -n -"${RETENTION_DAYS}" | xargs -r rm -rf
echo "[daily] complete"
