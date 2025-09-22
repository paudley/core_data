#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

log() {
  printf '[logical-backup] %s\n' "$1" >&2
}

POSTGRES_HOST=${POSTGRES_HOST:-postgres}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
POSTGRES_SUPERUSER=${POSTGRES_SUPERUSER:-postgres}
POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD:-}
POSTGRES_SUPERUSER_PASSWORD_FILE=${POSTGRES_SUPERUSER_PASSWORD_FILE:-}
LOGICAL_BACKUP_OUTPUT=${LOGICAL_BACKUP_OUTPUT:-/backups/logical}
LOGICAL_BACKUP_INTERVAL_SECONDS=${LOGICAL_BACKUP_INTERVAL_SECONDS:-86400}
LOGICAL_BACKUP_RETENTION_DAYS=${LOGICAL_BACKUP_RETENTION_DAYS:-7}
LOGICAL_BACKUP_EXCLUDE=${LOGICAL_BACKUP_EXCLUDE:-postgres}

if [[ -z "${POSTGRES_SUPERUSER_PASSWORD}" && -n "${POSTGRES_SUPERUSER_PASSWORD_FILE}" && -r "${POSTGRES_SUPERUSER_PASSWORD_FILE}" ]]; then
  POSTGRES_SUPERUSER_PASSWORD=$(<"${POSTGRES_SUPERUSER_PASSWORD_FILE}")
fi

PG_ENV=(
  env
  PGHOST="${POSTGRES_HOST}"
  PGPORT="${POSTGRES_PORT}"
  PGUSER="${POSTGRES_SUPERUSER}"
  PGDATABASE="${POSTGRES_DB:-postgres}"
  PGSSLMODE=require
)
if [[ -n ${POSTGRES_SUPERUSER_PASSWORD} ]]; then
  PG_ENV+=(PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}")
fi

mkdir -p "${LOGICAL_BACKUP_OUTPUT}"

IFS=',' read -ra EXCLUDE_RAW <<<"${LOGICAL_BACKUP_EXCLUDE}"
declare -A EXCLUDE_MAP=()
for entry in "${EXCLUDE_RAW[@]}"; do
  entry=${entry// /}
  if [[ -n ${entry} ]]; then
    EXCLUDE_MAP["${entry}"]=1
  fi
done

RUNNING=true
trap 'RUNNING=false' TERM INT

wait_for_postgres() {
  until "${PG_ENV[@]}" pg_isready -q; do
    log "waiting for postgres at ${POSTGRES_HOST}:${POSTGRES_PORT}"
    sleep 5
  done
}

perform_backup() {
  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)
  local target_dir="${LOGICAL_BACKUP_OUTPUT}/${timestamp}"
  mkdir -p "${target_dir}"

  log "starting logical backup into ${target_dir}"

  local databases
  databases=$("${PG_ENV[@]}" psql -Atqc "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;")
  while IFS= read -r db; do
    [[ -z "${db}" ]] && continue
    if [[ -n ${EXCLUDE_MAP["${db}"]+x} ]]; then
      continue
    fi
    local outfile="${target_dir}/${db}.dump"
    log "  -> dumping ${db}"
    "${PG_ENV[@]}" pg_dump --format=custom --no-owner --no-acl --file="${outfile}" --dbname="${db}"
  done <<<"${databases}"

  log "  -> dumping globals"
  "${PG_ENV[@]}" pg_dumpall --globals-only --no-password > "${target_dir}/globals.sql"

  if (( LOGICAL_BACKUP_RETENTION_DAYS > 0 )); then
    find "${LOGICAL_BACKUP_OUTPUT}" -mindepth 1 -maxdepth 1 -type d -mtime +"${LOGICAL_BACKUP_RETENTION_DAYS}" -print -exec rm -rf {} + 2>/dev/null || true
  fi

  log "completed backup at ${timestamp}"
}

main_loop() {
  wait_for_postgres
  while ${RUNNING}; do
    local cycle_start
    cycle_start=$(date +%s)
    if ! perform_backup; then
      log "backup cycle failed"
    fi
    if ! ${RUNNING}; then
      break
    fi
    local cycle_end
    cycle_end=$(date +%s)
    local elapsed=$((cycle_end - cycle_start))
    local sleep_seconds=$((LOGICAL_BACKUP_INTERVAL_SECONDS - elapsed))
    if (( sleep_seconds < 60 )); then
      sleep_seconds=60
    fi
    log "sleeping ${sleep_seconds}s before next backup"
    sleep "${sleep_seconds}" &
    wait $! || true
    wait_for_postgres
  done
}

main_loop
