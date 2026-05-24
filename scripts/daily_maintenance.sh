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
# shellcheck source=scripts/lib/valkey.sh
source "${SCRIPT_DIR}/lib/valkey.sh"
# shellcheck source=scripts/lib/pgbouncer.sh
source "${SCRIPT_DIR}/lib/pgbouncer.sh"
# shellcheck source=scripts/lib/memcached.sh
source "${SCRIPT_DIR}/lib/memcached.sh"

ensure_env
load_secret_from_file POSTGRES_SUPERUSER_PASSWORD
if [[ -z "${POSTGRES_SUPERUSER_PASSWORD:-}" ]]; then
  default_secret="${ROOT_DIR}/secrets/postgres_superuser_password"
  if [[ -r "${default_secret}" ]]; then
    POSTGRES_SUPERUSER_PASSWORD=$(tr -d '\r\n' < "${default_secret}")
    export POSTGRES_SUPERUSER_PASSWORD
  fi
fi

postgres_exec_with_auth() {
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" "$@"
}

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
LOGICAL_BACKUP_HOST_OUTPUT=${LOGICAL_BACKUP_HOST_OUTPUT:-./backups/logical}

TIMESTAMP=$(date +%Y%m%d)
HOST_TARGET_DIR="${HOST_BACKUP_ROOT}/${TIMESTAMP}"
CONTAINER_TARGET_DIR="${CONTAINER_BACKUP_ROOT}/${TIMESTAMP}"

# Create backup directory, handling existing directories and symlinks
mkdir_error=""
if ! mkdir -p "${HOST_TARGET_DIR}" > /dev/null 2>&1; then
  mkdir_error=$(mkdir -p "${HOST_TARGET_DIR}" 2>&1)
fi
if [[ ! -d "${HOST_TARGET_DIR}" ]]; then
  echo "[daily] ERROR: Failed to create or access ${HOST_TARGET_DIR}" >&2
  if [[ -n "${mkdir_error}" ]]; then
    echo "[daily] mkdir error: ${mkdir_error}" >&2
  fi
  exit 1
fi
chmod 0777 "${HOST_TARGET_DIR}" 2> /dev/null || true

# Create backup directory inside container as well
compose_exec bash -lc "mkdir -p '${CONTAINER_TARGET_DIR}' && chmod 0777 '${CONTAINER_TARGET_DIR}'"

STATUS_TSV="${HOST_TARGET_DIR}/maintenance_status.tsv"
: > "${STATUS_TSV}"

record_step_status() {
  local name=$1
  local status=$2
  local duration=$3
  local message=${4:-}
  local clean_message=${message//$'\t'/ }
  clean_message=${clean_message//$'\r'/ }
  clean_message=${clean_message//$'\n'/ }
  printf '%s\t%s\t%s\t%s\n' "${name}" "${status}" "${duration}" "${clean_message}" >> "${STATUS_TSV}"
}

run_optional_step() {
  local name=$1
  shift
  local start end duration output status
  start=$(date +%s)
  if output=$("$@" 2>&1); then
    status=0
  else
    status=$?
  fi
  end=$(date +%s)
  duration=$((end - start))
  if ((status == 0)); then
    record_step_status "${name}" "ok" "${duration}" ""
    if [[ -n "${output}" ]]; then
      printf '%s\n' "${output}" >&2
    fi
  else
    record_step_status "${name}" "warn" "${duration}" "${output}"
    echo "[daily] WARNING: ${name} failed." >&2
    if [[ -n "${output}" ]]; then
      printf '%s\n' "${output}" >&2
    fi
  fi
  return 0
}

echo "[daily] capturing optional cache / pool services"

if compose_has_service rabbitmq; then
  echo "[daily]  -> rabbitmq snapshot"
  # shellcheck disable=SC2016
  if compose exec -T rabbitmq sh -c '
    PASS=$(tr -d " \r\n" </run/secrets/rabbitmq_default_pass 2>/dev/null || echo "")
    USER=${RABBITMQ_DEFAULT_USER:-coredata}
    PORT=${RABBITMQ_MANAGEMENT_PORT:-15672}
    if [ -z "$PASS" ]; then
      echo "[daily] missing RabbitMQ secret" >&2
      exit 1
    fi
    AUTH=$(printf "%s:%s" "$USER" "$PASS" | base64)
    wget --quiet --header "Authorization: Basic $AUTH" -O - "http://127.0.0.1:${PORT}/api/definitions"
  ' > "${HOST_TARGET_DIR}/rabbitmq-definitions.json"; then
    chmod 0600 "${HOST_TARGET_DIR}/rabbitmq-definitions.json" 2> /dev/null || true
  else
    echo "[daily] WARNING: RabbitMQ definitions export failed." >&2
    rm -f "${HOST_TARGET_DIR}/rabbitmq-definitions.json" 2> /dev/null || true
  fi
  # shellcheck disable=SC2016
  if compose exec -T rabbitmq sh -c '
    PASS=$(tr -d " \r\n" </run/secrets/rabbitmq_default_pass 2>/dev/null || echo "")
    USER=${RABBITMQ_DEFAULT_USER:-coredata}
    PORT=${RABBITMQ_MANAGEMENT_PORT:-15672}
    if [ -z "$PASS" ]; then
      exit 1
    fi
    AUTH=$(printf "%s:%s" "$USER" "$PASS" | base64)
    wget --quiet --header "Authorization: Basic $AUTH" -O - "http://127.0.0.1:${PORT}/api/health/checks/node"
  ' > "${HOST_TARGET_DIR}/rabbitmq-status.txt"; then
    chmod 0600 "${HOST_TARGET_DIR}/rabbitmq-status.txt" 2> /dev/null || true
  else
    echo "[daily] WARNING: RabbitMQ status snapshot failed." >&2
    rm -f "${HOST_TARGET_DIR}/rabbitmq-status.txt" 2> /dev/null || true
  fi
fi

if compose_has_service valkey; then
  echo "[daily]  -> valkey snapshot"
  if compose exec -T valkey sh -c "test -r /run/secrets/valkey_password"; then
    if compose exec -T valkey sh -c "rm -f /tmp/core_data_valkey.rdb && VALKEY_PASS=\$(cat /run/secrets/valkey_password) valkey-cli -a \"\${VALKEY_PASS}\" --rdb /tmp/core_data_valkey.rdb"; then
      if compose exec -T valkey sh -c "test -f /tmp/core_data_valkey.rdb"; then
        compose exec -T valkey sh -c "cat /tmp/core_data_valkey.rdb" > "${HOST_TARGET_DIR}/valkey-dump.rdb" || true
        compose exec -T valkey sh -c "rm -f /tmp/core_data_valkey.rdb" || true
        if [[ -f "${HOST_TARGET_DIR}/valkey-dump.rdb" ]]; then
          chmod 0600 "${HOST_TARGET_DIR}/valkey-dump.rdb" || true
        fi
      fi
    else
      echo "[daily] WARNING: valkey-cli --rdb failed" >&2
    fi
    compose exec -T valkey sh -c "VALKEY_PASS=\$(cat /run/secrets/valkey_password) valkey-cli -a \"\${VALKEY_PASS}\" info" > "${HOST_TARGET_DIR}/valkey-info.txt" || true
    if [[ -f "${HOST_TARGET_DIR}/valkey-info.txt" ]]; then
      chmod 0600 "${HOST_TARGET_DIR}/valkey-info.txt" || true
    fi
  else
    echo "[daily] WARNING: /run/secrets/valkey_password not available; skipping." >&2
  fi
fi

if compose_has_service pgbouncer; then
  echo "[daily]  -> pgbouncer stats"
  load_secret_from_file PGBOUNCER_STATS_PASSWORD
  stats_password="${PGBOUNCER_STATS_PASSWORD:-}"
  stats_user="${PGBOUNCER_STATS_USER:-pgbouncer_stats}"
  pgbouncer_port="${PGBOUNCER_PORT:-6432}"
  if [[ -z ${stats_password} ]]; then
    echo "[daily] WARNING: PGBOUNCER_STATS_PASSWORD not available; skipping." >&2
  else
    compose exec -T postgres env \
      PGPASSWORD="${stats_password}" \
      psql --host pgbouncer --port "${pgbouncer_port}" --username "${stats_user}" --dbname pgbouncer --csv --command "SHOW STATS;" \
      > "${HOST_TARGET_DIR}/pgbouncer-stats.csv" || true
    compose exec -T postgres env \
      PGPASSWORD="${stats_password}" \
      psql --host pgbouncer --port "${pgbouncer_port}" --username "${stats_user}" --dbname pgbouncer --csv --command "SHOW POOLS;" \
      > "${HOST_TARGET_DIR}/pgbouncer-pools.csv" || true
    if [[ -f "${HOST_TARGET_DIR}/pgbouncer-stats.csv" ]]; then
      chmod 0600 "${HOST_TARGET_DIR}/pgbouncer-stats.csv" 2> /dev/null || true
    fi
    if [[ -f "${HOST_TARGET_DIR}/pgbouncer-pools.csv" ]]; then
      chmod 0600 "${HOST_TARGET_DIR}/pgbouncer-pools.csv" 2> /dev/null || true
    fi
  fi
  unset PGBOUNCER_STATS_PASSWORD
fi

if compose_has_service memcached; then
  echo "[daily]  -> memcached stats"
  if compose exec -T memcached sh -c "printf 'stats\\r\\n' | nc -w 2 127.0.0.1 11211" > "${HOST_TARGET_DIR}/memcached-stats.txt"; then
    chmod 0600 "${HOST_TARGET_DIR}/memcached-stats.txt" 2> /dev/null || true
  else
    echo "[daily] WARNING: memcached stats command failed." >&2
  fi
fi

echo "[daily] dumping databases into ${CONTAINER_TARGET_DIR}"
databases=$(postgres_exec_with_auth bash -lc "psql --tuples-only --no-align --dbname='${POSTGRES_DB:-postgres}' --username='${POSTGRES_SUPERUSER:-postgres}' -c \"SELECT datname FROM pg_database WHERE datistemplate = false;\"")
while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  outfile="${CONTAINER_TARGET_DIR}/${db}-$(date +%Y%m%d%H%M%S).dump.gz"
  echo "[daily]  -> ${db}"
  postgres_exec_with_auth bash -lc "pg_dump --format=custom --no-owner --no-acl --dbname='${db}' --username='${POSTGRES_SUPERUSER:-postgres}' | gzip > '${outfile}'"
done <<< "${databases}"

echo "[daily] creating plain SQL dump for postgres"
postgres_exec_with_auth bash -lc "pg_dump --format=plain --create --clean --if-exists --no-owner --no-acl --dbname='${POSTGRES_DB:-postgres}' --username='${POSTGRES_SUPERUSER:-postgres}' > '${CONTAINER_TARGET_DIR}/postgres.sql'"

echo "[daily] copying logs"
compose_exec bash -lc "cp /var/lib/postgresql/data/log/postgresql-*.log '${CONTAINER_TARGET_DIR}' 2>/dev/null || true"
compose_exec bash -lc "cp /var/lib/postgresql/data/log/postgresql-*.csv '${CONTAINER_TARGET_DIR}' 2>/dev/null || true"
if [[ ${REMOVE_SOURCE} == true ]]; then
  compose_exec bash -lc "rm -f /var/lib/postgresql/data/log/postgresql-*.log /var/lib/postgresql/data/log/postgresql-*.csv"
fi

echo "[daily] generating pgBadger report"
if compose_exec bash -lc "compgen -G '${CONTAINER_TARGET_DIR}/postgresql-*.csv' >/dev/null"; then
  if [[ -n ${SINCE} ]]; then
    compose_exec bash -lc "pgbadger --quiet --format csv --jobs ${PG_BADGER_JOBS} --begin '${SINCE}' --outfile '${CONTAINER_TARGET_DIR}/pgbadger.html' ${CONTAINER_TARGET_DIR}/postgresql-*.csv"
  else
    compose_exec bash -lc "pgbadger --quiet --format csv --jobs ${PG_BADGER_JOBS} --outfile '${CONTAINER_TARGET_DIR}/pgbadger.html' ${CONTAINER_TARGET_DIR}/postgresql-*.csv"
  fi
else
  echo "[daily] skipping pgBadger (no CSV logs present)" >&2
fi

echo "[daily] capturing pg_stat_statements baseline"
run_optional_step "pg_stat_statements" snapshot_pg_stat_statements "${CONTAINER_TARGET_DIR}/pg_stat_statements.csv" "${PG_STAT_LIMIT}"

echo "[daily] snapshotting buffer cache allocation"
run_optional_step "pg_buffercache" audit_pg_buffercache "${CONTAINER_TARGET_DIR}/pg_buffercache.csv" "${BUFFERCACHE_LIMIT}"

echo "[daily] running pg_partman maintenance"
while IFS= read -r db; do
  [[ -z "${db}" ]] && continue
  postgres_exec_with_auth psql --host "${POSTGRES_HOST}" --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" << 'SQL' > /dev/null || true
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
done <<< "${databases}"

echo "[daily] auditing roles"
run_optional_step "audit_roles" audit_roles "${CONTAINER_TARGET_DIR}/role_audit.csv"

echo "[daily] auditing extensions"
run_optional_step "audit_extensions" audit_extensions "${CONTAINER_TARGET_DIR}/extension_audit.csv"

echo "[daily] auditing autovacuum health"
run_optional_step "audit_autovacuum" audit_autovacuum "${CONTAINER_TARGET_DIR}/autovacuum_findings.csv" "${DEAD_TUPLE_THRESHOLD}" "${DEAD_TUPLE_RATIO}"

echo "[daily] auditing replication lag"
run_optional_step "audit_replication_lag" audit_replication_lag "${CONTAINER_TARGET_DIR}/replication_lag.csv" "${REPLICATION_LAG_THRESHOLD}"

echo "[daily] auditing security posture"
run_optional_step "audit_security" audit_security "${CONTAINER_TARGET_DIR}/security_audit.txt"

echo "[daily] auditing pg_cron schedule"
run_optional_step "audit_pg_cron" audit_pg_cron "${CONTAINER_TARGET_DIR}/cron_schedule.csv"

echo "[daily] auditing pg_squeeze activity"
run_optional_step "audit_pg_squeeze" audit_pg_squeeze "${CONTAINER_TARGET_DIR}/pg_squeeze.csv"

echo "[daily] auditing index bloat"
run_optional_step "audit_index_bloat" audit_index_bloat "${CONTAINER_TARGET_DIR}/index_bloat.csv" "${INDEX_MIN_SIZE_MB}"

echo "[daily] capturing schema snapshot"
run_optional_step "audit_schema_snapshot" audit_schema_snapshot "${CONTAINER_TARGET_DIR}/schema_snapshot.csv"

echo "[daily] summarizing pgaudit events"
run_optional_step "summarize_pgaudit_logs" summarize_pgaudit_logs "${CONTAINER_TARGET_DIR}"

echo "[daily] checking extension version drift"
python3 "${SCRIPT_DIR}/version_status.py" \
  --only-outdated \
  --quiet \
  --output "${HOST_TARGET_DIR}/version_status.csv" || record_step_status "version_status" "warn" 0 "version status failed"

echo "[daily] summarizing logical backup sidecar"
LOGICAL_STATUS_FILE="${HOST_TARGET_DIR}/logical_backup_status.txt"
if [[ -d "${LOGICAL_BACKUP_HOST_OUTPUT}" ]]; then
  latest_dir=$(find "${LOGICAL_BACKUP_HOST_OUTPUT}" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
  if [[ -n "${latest_dir}" ]]; then
    latest_name=$(basename "${latest_dir}")
    latest_epoch=$(stat -c %Y "${latest_dir}" 2> /dev/null || stat -f %m "${latest_dir}" 2> /dev/null || echo 0)
    now_epoch=$(date +%s)
    age_seconds=$((now_epoch - latest_epoch))
    file_count=$(find "${latest_dir}" -type f | wc -l | tr -d ' ')
    size_bytes=$(du -sb "${latest_dir}" 2> /dev/null | awk '{print $1}')
    {
      echo "latest_directory=${latest_name}"
      echo "age_seconds=${age_seconds}"
      echo "file_count=${file_count}"
      echo "size_bytes=${size_bytes:-0}"
    } > "${LOGICAL_STATUS_FILE}"
  else
    echo "status=no_backups_detected" > "${LOGICAL_STATUS_FILE}"
  fi
else
  echo "status=logical_backup_path_missing" > "${LOGICAL_STATUS_FILE}"
fi

python3 - "${STATUS_TSV}" "${HOST_TARGET_DIR}/maintenance_status.json" << 'PY'
import json
import sys
from pathlib import Path

rows = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    name, status, duration, message = (line.split("\t", 3) + ["", "", "", ""])[:4]
    rows.append({
        "name": name,
        "status": status,
        "duration_seconds": int(duration or 0),
        "message": message,
    })
overall = "ok"
if any(row["status"] == "fail" for row in rows):
    overall = "fail"
elif any(row["status"] == "warn" for row in rows):
    overall = "warn"
Path(sys.argv[2]).write_text(json.dumps({"overall": overall, "steps": rows}, indent=2) + "\n", encoding="utf-8")
PY

if [[ ${GENERATE_HTML} == true ]]; then
  echo "[daily] generating html maintenance summary"
  python3 "${SCRIPT_DIR}/generate_report.py" \
    --input "${HOST_TARGET_DIR}" \
    --output "${HOST_TARGET_DIR}/maintenance_report.html" || true
fi

if [[ ${EMAIL_REPORT} == true && -n ${REPORT_RECIPIENT} ]]; then
  echo "[daily] emailing maintenance report to ${REPORT_RECIPIENT}"
  compose_exec bash -lc "if command -v sendmail >/dev/null 2>&1; then \n    ( \n      echo 'To: ${REPORT_RECIPIENT}'; \n      echo 'Subject: core_data maintenance report'; \n      echo 'Content-Type: text/html'; \n      echo; \n      cat '${CONTAINER_TARGET_DIR}/maintenance_report.html'; \n    ) | sendmail -t \n  else \n    echo '[daily] sendmail not available in container' >&2; \n  fi" || true
fi

echo "[daily] applying retention ${RETENTION_DAYS} days"
find "${HOST_BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort | head -n -"${RETENTION_DAYS}" | xargs -r rm -rf
echo "[daily] complete"
