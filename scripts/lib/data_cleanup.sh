#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
set -euo pipefail

DATA_CLEANUP_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
# shellcheck disable=SC1091
source "${DATA_CLEANUP_LIB_DIR}/common.sh"

DATA_CLEANUP_DEFAULT_RETENTION=${DATA_CLEANUP_DEFAULT_RETENTION:-7d}
CORE_DATA_DATA_ROOT=${CORE_DATA_DATA_ROOT:-${ROOT_DIR}/data}

data_cleanup_usage() {
  cat <<'USAGE'
Usage: manage.sh data-cleanup [options]

Remove stale pytest data stashes left under data/.pytest_backups.

Options:
  --older-than AGE       Retain entries newer than AGE (default: 7d).
                         AGE accepts s, m, h, or d suffixes.
  --execute             Delete matching entries. Without this, only report.
  --force               Allow execution even when compose containers are running.
  --json                Emit a JSON summary.
  -h, --help            Show this help.
USAGE
}

data_cleanup_parse_age() {
  local age=$1
  local number
  local suffix

  if [[ "${age}" =~ ^([0-9]+)([smhd])$ ]]; then
    number=${BASH_REMATCH[1]}
    suffix=${BASH_REMATCH[2]}
  elif [[ "${age}" =~ ^([0-9]+)$ ]]; then
    number=${BASH_REMATCH[1]}
    suffix=d
  else
    echo "[data-cleanup] invalid age '${age}'; expected values like 24h or 7d." >&2
    return 1
  fi

  case "${suffix}" in
    s) echo "${number}" ;;
    m) echo $((number * 60)) ;;
    h) echo $((number * 60 * 60)) ;;
    d) echo $((number * 24 * 60 * 60)) ;;
  esac
}

data_cleanup_compose_running() {
  local output
  if ! output=$(compose ps -q 2>/dev/null); then
    return 2
  fi
  [[ -n "${output}" ]]
}

data_cleanup_json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "${value}"
}

cmd_data_cleanup() {
  local older_than=${DATA_CLEANUP_DEFAULT_RETENTION}
  local execute=false
  local force=false
  local json=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --older-than)
        if [[ $# -lt 2 ]]; then
          echo "[data-cleanup] --older-than requires an age value." >&2
          return 1
        fi
        older_than=$2
        shift 2
        ;;
      --older-than=*)
        older_than=${1#*=}
        shift
        ;;
      --execute)
        execute=true
        shift
        ;;
      --force)
        force=true
        shift
        ;;
      --json)
        json=true
        shift
        ;;
      -h | --help)
        data_cleanup_usage
        return 0
        ;;
      *)
        echo "[data-cleanup] unknown option: $1" >&2
        data_cleanup_usage >&2
        return 1
        ;;
    esac
  done

  local retention_seconds
  retention_seconds=$(data_cleanup_parse_age "${older_than}")
  local now
  now=$(date +%s)
  local cutoff=$((now - retention_seconds))
  local backup_root="${CORE_DATA_DATA_ROOT%/}/.pytest_backups"
  local candidates=()
  local candidate_count=0
  local total_bytes=0

  if [[ -d "${backup_root}" ]]; then
    local path
    while IFS= read -r -d '' path; do
      local modified
      modified=$(stat -c '%Y' "${path}")
      if ((modified <= cutoff)); then
        local bytes
        bytes=$(du -s -B1 "${path}" | awk '{print $1}')
        candidates+=("${path}")
        candidate_count=$((candidate_count + 1))
        total_bytes=$((total_bytes + bytes))
      fi
    done < <(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  fi

  if [[ "${execute}" == "true" && "${force}" != "true" ]]; then
    local compose_state=0
    data_cleanup_compose_running || compose_state=$?
    case "${compose_state}" in
      0)
        echo "[data-cleanup] refusing to delete while compose containers are running; rerun after shutdown or pass --force." >&2
        return 1
        ;;
      2)
        echo "[data-cleanup] unable to determine compose state; pass --force to execute anyway." >&2
        return 1
        ;;
    esac
  fi

  if [[ "${json}" == "true" ]]; then
    printf '{"mode":"%s","backup_root":"%s","older_than":"%s","candidates":%d,"bytes":%d,"paths":[' \
      "$([[ "${execute}" == "true" ]] && echo execute || echo dry-run)" \
      "$(data_cleanup_json_escape "${backup_root}")" \
      "$(data_cleanup_json_escape "${older_than}")" \
      "${candidate_count}" \
      "${total_bytes}"
    local first=true
    local candidate
    for candidate in "${candidates[@]}"; do
      if [[ "${first}" == "true" ]]; then
        first=false
      else
        printf ','
      fi
      printf '"%s"' "$(data_cleanup_json_escape "${candidate}")"
    done
    printf ']}\n'
  else
    printf '[data-cleanup] mode: %s\n' "$([[ "${execute}" == "true" ]] && echo execute || echo dry-run)"
    printf '[data-cleanup] backup root: %s\n' "${backup_root}"
    printf '[data-cleanup] retention: older than %s\n' "${older_than}"
    printf '[data-cleanup] candidates: %d\n' "${candidate_count}"
    printf '[data-cleanup] reclaimable bytes: %d\n' "${total_bytes}"
    local candidate
    for candidate in "${candidates[@]}"; do
      printf '%s\n' "${candidate}"
    done
    if [[ "${execute}" != "true" ]]; then
      printf '[data-cleanup] dry run only; pass --execute to delete matching entries.\n'
    fi
  fi

  if [[ "${execute}" == "true" ]]; then
    local candidate
    for candidate in "${candidates[@]}"; do
      rm -rf -- "${candidate}"
    done
  fi
}
