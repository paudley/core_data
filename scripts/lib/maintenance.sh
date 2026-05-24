#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
set -euo pipefail

LIB_MAINTENANCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${LIB_MAINTENANCE_DIR}/common.sh"

# pgBadger and daily maintenance helpers used by manage.sh.
normalize_pgbadger_begin() {
  local value=$1
  if [[ -z ${value} ]]; then
    return 0
  fi
  if [[ ${value} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf '%s 00:00:00\n' "${value}"
    return 0
  fi
  if [[ ${value} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}$ ]]; then
    printf '%s:00\n' "${value}"
    return 0
  fi
  if [[ ${value} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  date -u -d "${value}" '+%Y-%m-%d %H:%M:%S'
}

# cmd_pgbadger_report generates a pgBadger HTML report from recent CSV logs.
cmd_pgbadger_report() {
  ensure_env
  local since=""
  local jobs=${PG_BADGER_JOBS:-2}
  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)
  local output="/backups/pgbadger-${timestamp}.html"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since)
        since=$2
        shift 2
        ;;
      --since=*)
        since=${1#*=}
        shift
        ;;
      --output)
        output=$2
        shift 2
        ;;
      --output=*)
        output=${1#*=}
        shift
        ;;
      --jobs)
        jobs=$2
        shift 2
        ;;
      --jobs=*)
        jobs=${1#*=}
        shift
        ;;
      -h | --help)
        echo "Usage: ${0##*/} pgbadger-report [--since TIMESTAMP] [--output PATH] [--jobs N]" >&2
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "Unknown option for pgbadger-report: $1" >&2
        exit 1
        ;;
    esac
  done
  if [[ -n ${since} ]]; then
    since=$(normalize_pgbadger_begin "${since}")
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "$output")'"
  local cmd=(pgbadger --quiet --format csv --jobs "$jobs" --outfile "$output")
  [[ -n $since ]] && cmd+=(--begin "$since")
  local command_string
  printf -v command_string '%q ' "${cmd[@]}"
  compose_exec bash -lc "${command_string} /var/lib/postgresql/data/log/postgresql-*.csv"
  echo "pgBadger report written to ${output}" >&2
}

# cmd_daily_maintenance orchestrates daily dumps, log copy, pgBadger, and retention.
cmd_daily_maintenance() {
  ensure_env
  local backup_root=${DAILY_BACKUP_ROOT:-./backups/daily}
  local retention=${DAILY_RETENTION_DAYS:-30}
  local since=""
  local remove_logs=false
  local container_root=${DAILY_CONTAINER_BACKUP_ROOT:-/backups/daily}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)
        backup_root=$2
        shift 2
        ;;
      --root=*)
        backup_root=${1#*=}
        shift
        ;;
      --retention)
        retention=$2
        shift 2
        ;;
      --retention=*)
        retention=${1#*=}
        shift
        ;;
      --since)
        since=$2
        shift 2
        ;;
      --since=*)
        since=${1#*=}
        shift
        ;;
      --container-root)
        container_root=$2
        shift 2
        ;;
      --container-root=*)
        container_root=${1#*=}
        shift
        ;;
      --remove-source-logs)
        remove_logs=true
        shift
        ;;
      -h | --help)
        echo "Usage: ${0##*/} daily-maintenance [--root PATH] [--retention DAYS] [--since TIME] [--remove-source-logs]" >&2
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        echo "Unknown option for daily-maintenance: $1" >&2
        exit 1
        ;;
    esac
  done
  DAILY_BACKUP_ROOT="$backup_root" \
    DAILY_CONTAINER_BACKUP_ROOT="$container_root" \
    DAILY_RETENTION_DAYS="$retention" \
    DAILY_PGBADGER_SINCE="$since" \
    DAILY_REMOVE_SOURCE_LOGS="$remove_logs" \
    PG_BADGER_JOBS="${PG_BADGER_JOBS:-2}" \
    bash "${SCRIPT_DIR}/daily_maintenance.sh"
}
