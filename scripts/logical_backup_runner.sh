#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

log() {
  printf '[logical-backup] %s\n' "$1" >&2
}

POSTGRES_HOST=${POSTGRES_HOST:-postgres}
POSTGRES_PORT=${POSTGRES_PORT:-5433}
POSTGRES_SUPERUSER=${POSTGRES_SUPERUSER:-postgres}
POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD:-}
POSTGRES_SUPERUSER_PASSWORD_FILE=${POSTGRES_SUPERUSER_PASSWORD_FILE:-}
CORE_DATA_REQUIRE_ENV_FILE=0
RUNNER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
# shellcheck disable=SC1091
if [[ -f "${RUNNER_DIR}/lib/common.sh" ]]; then
  source "${RUNNER_DIR}/lib/common.sh"
fi
LOGICAL_BACKUP_OUTPUT=${LOGICAL_BACKUP_OUTPUT:-/backups/logical}
LOGICAL_BACKUP_INTERVAL_SECONDS=${LOGICAL_BACKUP_INTERVAL_SECONDS:-86400}
LOGICAL_BACKUP_RETENTION_DAYS=${LOGICAL_BACKUP_RETENTION_DAYS:-7}
LOGICAL_BACKUP_EXCLUDE=${LOGICAL_BACKUP_EXCLUDE:-postgres}
LOGICAL_BACKUP_SSLMODE=${LOGICAL_BACKUP_SSLMODE:-require}
LOGICAL_BACKUP_METRICS_FILE=${LOGICAL_BACKUP_METRICS_FILE:-/tmp/core_data_logical_backup.prom}
LOGICAL_BACKUP_METRICS_PORT=${LOGICAL_BACKUP_METRICS_PORT:-9188}
LAST_SUCCESS_TIMESTAMP=0
LAST_SUCCESS_DURATION=0
LAST_SUCCESS_SIZE_BYTES=0
LAST_SUCCESS_FILE_COUNT=0

if [[ -z "${POSTGRES_SUPERUSER_PASSWORD}" && -n "${POSTGRES_SUPERUSER_PASSWORD_FILE}" && -r "${POSTGRES_SUPERUSER_PASSWORD_FILE}" ]]; then
  POSTGRES_SUPERUSER_PASSWORD=$(< "${POSTGRES_SUPERUSER_PASSWORD_FILE}")
fi

PG_ENV=(
  env
  PGHOST="${POSTGRES_HOST}"
  PGPORT="${POSTGRES_PORT}"
  PGUSER="${POSTGRES_SUPERUSER}"
  PGDATABASE="${POSTGRES_DB:-postgres}"
  PGSSLMODE="${LOGICAL_BACKUP_SSLMODE}"
)
if [[ -n ${POSTGRES_SUPERUSER_PASSWORD} ]]; then
  PG_ENV+=(PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD}")
fi

mkdir -p "${LOGICAL_BACKUP_OUTPUT}"
touch "${LOGICAL_BACKUP_METRICS_FILE}"

write_metrics() {
  local status=$1
  local timestamp=$2
  local duration=$3
  local size_bytes=$4
  local file_count=$5
  local failure_count=$6
  local tmp_file="${LOGICAL_BACKUP_METRICS_FILE}.tmp.$$"
  cat > "${tmp_file}" << METRICS
# HELP core_data_logical_backup_last_success_timestamp_seconds Last successful logical backup Unix timestamp.
# TYPE core_data_logical_backup_last_success_timestamp_seconds gauge
core_data_logical_backup_last_success_timestamp_seconds ${timestamp}
# HELP core_data_logical_backup_last_duration_seconds Last logical backup duration.
# TYPE core_data_logical_backup_last_duration_seconds gauge
core_data_logical_backup_last_duration_seconds ${duration}
# HELP core_data_logical_backup_last_size_bytes Last successful logical backup total size in bytes.
# TYPE core_data_logical_backup_last_size_bytes gauge
core_data_logical_backup_last_size_bytes ${size_bytes}
# HELP core_data_logical_backup_last_file_count Last successful logical backup file count.
# TYPE core_data_logical_backup_last_file_count gauge
core_data_logical_backup_last_file_count ${file_count}
# HELP core_data_logical_backup_last_status Last logical backup status where 1 is success and 0 is failure.
# TYPE core_data_logical_backup_last_status gauge
core_data_logical_backup_last_status ${status}
# HELP core_data_logical_backup_failures_total Logical backup failure count since sidecar start.
# TYPE core_data_logical_backup_failures_total counter
core_data_logical_backup_failures_total ${failure_count}
METRICS
  mv "${tmp_file}" "${LOGICAL_BACKUP_METRICS_FILE}"
}

write_metrics 0 0 0 0 0 0

LOGICAL_BACKUP_METRICS_FILE="${LOGICAL_BACKUP_METRICS_FILE}" \
  LOGICAL_BACKUP_METRICS_PORT="${LOGICAL_BACKUP_METRICS_PORT}" \
  python3 - << 'PY' &
import http.server
import os
import pathlib
import socketserver
import time

metrics_path = pathlib.Path(os.environ["LOGICAL_BACKUP_METRICS_FILE"])
port = int(os.environ["LOGICAL_BACKUP_METRICS_PORT"])
default_payload = (
    "# HELP core_data_logical_backup_last_success_timestamp_seconds "
    "Last successful logical backup Unix timestamp.\n"
    "# TYPE core_data_logical_backup_last_success_timestamp_seconds gauge\n"
    "core_data_logical_backup_last_success_timestamp_seconds 0\n"
    "# HELP core_data_logical_backup_last_status "
    "Last logical backup status where 1 is success and 0 is failure/unknown.\n"
    "# TYPE core_data_logical_backup_last_status gauge\n"
    "core_data_logical_backup_last_status 0"
)


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in {"/", "/metrics"}:
            self.send_error(404)
            return
        if metrics_path.exists():
            payload = metrics_path.read_text(encoding="utf-8")
        else:
            timestamp = int(time.time())
            payload = (
                default_payload
                + f"\ncore_data_logical_backup_metrics_timestamp_seconds {timestamp}\n"
            )
        body = payload.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


with ReusableTCPServer(("", port), MetricsHandler) as httpd:
    httpd.serve_forever()
PY
METRICS_PID=$!

IFS=',' read -ra EXCLUDE_RAW <<< "${LOGICAL_BACKUP_EXCLUDE}"
declare -A EXCLUDE_MAP=()
for entry in "${EXCLUDE_RAW[@]}"; do
  entry=${entry// /}
  if [[ -n ${entry} ]]; then
    EXCLUDE_MAP["${entry}"]=1
  fi
done

RUNNING=true
FAILURE_COUNT=0
trap 'RUNNING=false; kill "${METRICS_PID}" 2>/dev/null || true' TERM INT EXIT

wait_for_postgres() {
  local attempts=${LOGICAL_BACKUP_WAIT_ATTEMPTS:-120}
  local delay=2
  local attempt=1
  while ((attempt <= attempts)); do
    if "${PG_ENV[@]}" pg_isready -q > /dev/null 2>&1 && "${PG_ENV[@]}" psql -Atqc "SELECT 1;" > /dev/null 2>&1; then
      return 0
    fi
    log "waiting for postgres at ${POSTGRES_HOST}:${POSTGRES_PORT} (attempt ${attempt})"
    sleep "${delay}"
    if ((attempt % 10 == 0 && delay < 10)); then
      delay=$((delay + 1))
    fi
    attempt=$((attempt + 1))
  done
  log "postgres never became ready; giving up"
  return 1
}

perform_backup() {
  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)
  local started_at
  started_at=$(date +%s)
  local target_dir="${LOGICAL_BACKUP_OUTPUT}/${timestamp}"
  local tmp_dir="${target_dir}.tmp"
  rm -rf "${tmp_dir}"
  mkdir -p "${tmp_dir}"

  log "starting logical backup into ${target_dir}"

  cleanup_failed_backup() {
    touch "${tmp_dir}/_FAILED" 2> /dev/null || true
    rm -rf "${tmp_dir}"
  }

  local databases
  databases=$("${PG_ENV[@]}" psql -Atqc "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;") || {
    cleanup_failed_backup
    return 1
  }
  local dumped_dbs=()
  while IFS= read -r db; do
    [[ -z "${db}" ]] && continue
    if [[ -n ${EXCLUDE_MAP["${db}"]+x} ]]; then
      continue
    fi
    local outfile="${tmp_dir}/${db}.dump"
    log "  -> dumping ${db}"
    "${PG_ENV[@]}" pg_dump --format=custom --no-owner --no-acl --file="${outfile}" --dbname="${db}" || {
      cleanup_failed_backup
      return 1
    }
    pg_restore --list "${outfile}" > /dev/null || {
      cleanup_failed_backup
      return 1
    }
    dumped_dbs+=("${db}")
  done <<< "${databases}"

  log "  -> dumping globals"
  "${PG_ENV[@]}" pg_dumpall --globals-only --no-password > "${tmp_dir}/globals.sql" || {
    cleanup_failed_backup
    return 1
  }

  local completed_at
  completed_at=$(date +%s)
  local duration=$((completed_at - started_at))
  local size_bytes
  size_bytes=$(du -sb "${tmp_dir}" 2> /dev/null | awk '{print $1}')
  local file_count
  file_count=$(find "${tmp_dir}" -type f | wc -l | tr -d ' ')
  if ! python3 - "${tmp_dir}/manifest.json" "${timestamp}" "${started_at}" "${completed_at}" "${duration}" "${size_bytes:-0}" "${file_count}" "${dumped_dbs[@]}" << 'PY'; then
import hashlib
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
target = manifest_path.parent
dumped = sys.argv[8:]
files = []
for path in sorted(target.iterdir()):
    if path.name == "manifest.json" or not path.is_file():
        continue
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    files.append({"name": path.name, "size_bytes": path.stat().st_size, "sha256": digest})
manifest = {
    "timestamp": sys.argv[2],
    "started_at_epoch": int(sys.argv[3]),
    "completed_at_epoch": int(sys.argv[4]),
    "duration_seconds": int(sys.argv[5]),
    "size_bytes": int(sys.argv[6]),
    "file_count": int(sys.argv[7]),
    "databases": dumped,
    "files": files,
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    cleanup_failed_backup
    return 1
  fi
  touch "${tmp_dir}/_SUCCESS" || {
    cleanup_failed_backup
    return 1
  }
  mv "${tmp_dir}" "${target_dir}" || {
    cleanup_failed_backup
    return 1
  }
  LAST_SUCCESS_TIMESTAMP=${completed_at}
  LAST_SUCCESS_DURATION=${duration}
  LAST_SUCCESS_SIZE_BYTES=${size_bytes:-0}
  LAST_SUCCESS_FILE_COUNT=${file_count}
  write_metrics 1 "${LAST_SUCCESS_TIMESTAMP}" "${LAST_SUCCESS_DURATION}" "${LAST_SUCCESS_SIZE_BYTES}" "${LAST_SUCCESS_FILE_COUNT}" "${FAILURE_COUNT}"

  if ((LOGICAL_BACKUP_RETENTION_DAYS > 0)); then
    find "${LOGICAL_BACKUP_OUTPUT}" -mindepth 1 -maxdepth 1 -type d ! -name '*.tmp' -mtime +"${LOGICAL_BACKUP_RETENTION_DAYS}" -print -exec rm -rf {} + 2> /dev/null || true
  fi

  log "completed backup at ${timestamp}"
}

main_loop() {
  if ! wait_for_postgres; then
    exit 1
  fi
  while ${RUNNING}; do
    local cycle_start
    cycle_start=$(date +%s)
    if ! perform_backup; then
      FAILURE_COUNT=$((FAILURE_COUNT + 1))
      write_metrics 0 "${LAST_SUCCESS_TIMESTAMP}" "${LAST_SUCCESS_DURATION}" "${LAST_SUCCESS_SIZE_BYTES}" "${LAST_SUCCESS_FILE_COUNT}" "${FAILURE_COUNT}"
      log "backup cycle failed"
    fi
    if ! ${RUNNING}; then
      break
    fi
    local cycle_end
    cycle_end=$(date +%s)
    local elapsed=$((cycle_end - cycle_start))
    local sleep_seconds=$((LOGICAL_BACKUP_INTERVAL_SECONDS - elapsed))
    if ((sleep_seconds < 60)); then
      sleep_seconds=60
    fi
    log "sleeping ${sleep_seconds}s before next backup"
    sleep "${sleep_seconds}" &
    wait $! || true
    if ! wait_for_postgres; then
      exit 1
    fi
  done
}

main_loop
