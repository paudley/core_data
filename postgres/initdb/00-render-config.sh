#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

if [[ "${CORE_DATA_SKIP_CONFIG_RENDER:-0}" == "1" ]]; then
  exit 0
fi

TEMPLATE_DIR="/opt/core_data/conf"
SENTINEL="${PGDATA}/.core_data_config_rendered"
PGBACKREST_CONF_PATH="${PGDATA}/pgbackrest.conf"
NETWORK_ACCESS_DIR=${NETWORK_ACCESS_DIR:-/opt/core_data/network_access}
NETWORK_ALLOW_FILE=${NETWORK_ALLOW_FILE:-${NETWORK_ACCESS_DIR}/allow.list}
FORCE_RENDER_CONFIG=${FORCE_RENDER_CONFIG:-0}

# shellcheck disable=SC1091
# shellcheck source=/opt/core_data/scripts/lib/extensions_list.sh
source /opt/core_data/scripts/lib/extensions_list.sh

# Enforce that all required libraries are present in shared_preload_libraries.
# Called on every startup to prevent config drift from manual edits.
# Returns 0 if no changes needed, 1 if config was corrected (reload required).
enforce_shared_preload_libraries() {
  local conf_file="${PGDATA}/postgresql.conf"
  [[ -f "${conf_file}" ]] || return 0

  local current
  current=$(grep -E "^shared_preload_libraries" "${conf_file}" | sed "s/shared_preload_libraries *= *'\\(.*\\)'/\\1/")

  local missing=()
  for lib in "${REQUIRED_PRELOAD_LIBRARIES[@]}"; do
    if ! echo ",${current}," | grep -q ",${lib},"; then
      missing+=("${lib}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[core_data] WARNING: shared_preload_libraries missing required entries: ${missing[*]}" >&2
    local new_value="${current}"
    for lib in "${missing[@]}"; do
      new_value="${new_value},${lib}"
    done
    sed -i "s|^shared_preload_libraries *= *'.*'|shared_preload_libraries = '${new_value}'|" "${conf_file}"
    echo "[core_data] Corrected shared_preload_libraries to: ${new_value}" >&2
    return 1
  fi
  return 0
}

apply_network_allow_entries() {
  local hba_path="${PGDATA}/pg_hba.conf"
  if [[ ! -f "${hba_path}" ]]; then
    return
  fi
  # Remove previously rendered block (if present)
  if grep -q "# --- BEGIN networks.allow entries ---" "${hba_path}"; then
    tmp_file=$(mktemp)
    sed '/# --- BEGIN networks.allow entries ---/,/# --- END networks.allow entries ---/d' "${hba_path}" > "${tmp_file}"
    mv "${tmp_file}" "${hba_path}"
  fi
  if [[ -r "${NETWORK_ALLOW_FILE}" ]]; then
    {
      echo ""
      echo "# --- BEGIN networks.allow entries ---"
    } >> "${hba_path}"
    while IFS= read -r cidr; do
      trimmed=$(echo "${cidr}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "${trimmed}" ]] && continue
      [[ "${trimmed}" == \#* ]] && continue
      echo "host all all ${trimmed} scram-sha-256" >> "${hba_path}"
      echo "host replication all ${trimmed} scram-sha-256" >> "${hba_path}"
    done < "${NETWORK_ALLOW_FILE}"
    echo "# --- END networks.allow entries ---" >> "${hba_path}"
  else
    echo "[core_data] WARNING: ${NETWORK_ALLOW_FILE} not found; using template defaults only." >&2
  fi
}

: "${TZ:=UTC}"
: "${POSTGRES_LISTEN_ADDRESSES:=0.0.0.0}"
: "${POSTGRES_MAX_CONNECTIONS:=200}"
: "${PG_SHARED_BUFFERS:=1GB}"
: "${PG_EFFECTIVE_CACHE_SIZE:=3GB}"
: "${PG_WORK_MEM:=16MB}"
: "${PG_MAINTENANCE_WORK_MEM:=256MB}"
: "${PG_RANDOM_PAGE_COST:=1.1}"
: "${PG_EFFECTIVE_IO_CONCURRENCY:=200}"
# PostgreSQL 18 accepts effective_io_concurrency in range 0-1000; clamp invalid values
if [[ "${PG_EFFECTIVE_IO_CONCURRENCY}" -lt 0 ]]; then
  echo "[core_data] WARNING: PG_EFFECTIVE_IO_CONCURRENCY=${PG_EFFECTIVE_IO_CONCURRENCY} is negative; clamping to 0." >&2
  PG_EFFECTIVE_IO_CONCURRENCY=0
elif [[ "${PG_EFFECTIVE_IO_CONCURRENCY}" -gt 1000 ]]; then
  echo "[core_data] WARNING: PG_EFFECTIVE_IO_CONCURRENCY=${PG_EFFECTIVE_IO_CONCURRENCY} exceeds max (1000); clamping to 1000." >&2
  PG_EFFECTIVE_IO_CONCURRENCY=1000
fi
: "${PG_MAX_WAL_SIZE:=2GB}"
: "${PG_MIN_WAL_SIZE:=1GB}"
: "${PG_WAL_KEEP_SIZE:=2GB}"
: "${PG_MAX_WAL_SENDERS:=10}"
: "${PG_CHECKPOINT_COMPLETION_TARGET:=0.9}"
: "${PG_LOG_MIN_DURATION_STATEMENT:=500}"
: "${POSTGRES_SSL_ENABLED:=on}"
: "${POSTGRES_SSL_CERT_FILE:=${PGDATA}/tls/server.crt}"
: "${POSTGRES_SSL_KEY_FILE:=${PGDATA}/tls/server.key}"
: "${POSTGRES_SSL_SELF_SIGNED_SUBJECT:=/CN=core_data_postgres}"
: "${POSTGRES_SSL_SELF_SIGNED_DAYS:=730}"

export \
  TZ \
  POSTGRES_LISTEN_ADDRESSES \
  POSTGRES_MAX_CONNECTIONS \
  PG_SHARED_BUFFERS \
  PG_EFFECTIVE_CACHE_SIZE \
  PG_WORK_MEM \
  PG_MAINTENANCE_WORK_MEM \
  PG_RANDOM_PAGE_COST \
  PG_EFFECTIVE_IO_CONCURRENCY \
  PG_MAX_WAL_SIZE \
  PG_MIN_WAL_SIZE \
  PG_WAL_KEEP_SIZE \
  PG_MAX_WAL_SENDERS \
  PG_CHECKPOINT_COMPLETION_TARGET \
  PG_LOG_MIN_DURATION_STATEMENT \
  POSTGRES_SSL_ENABLED \
  POSTGRES_SSL_CERT_FILE \
  POSTGRES_SSL_KEY_FILE

mkdir -p "${PGDATA}"

first_render=1
if [[ -f "${SENTINEL}" ]]; then
  first_render=0
  if [[ "${FORCE_RENDER_CONFIG}" != "1" ]]; then
    echo "[core_data] Configuration already rendered; refreshing network allow entries." >&2
    apply_network_allow_entries
    needs_reload=0
    if ! enforce_shared_preload_libraries; then
      needs_reload=1
    fi
    if pg_ctl -D "${PGDATA}" status > /dev/null 2>&1; then
      if [[ "${needs_reload}" -eq 1 ]]; then
        echo "[core_data] Restarting PostgreSQL to apply corrected shared_preload_libraries." >&2
        if ! pg_ctl -D "${PGDATA}" -m fast -w restart > /dev/null 2>&1; then
          echo "[core_data] WARNING: pg_ctl restart failed after shared_preload_libraries correction." >&2
        fi
      elif ! pg_ctl -D "${PGDATA}" reload > /dev/null 2>&1; then
        echo "[core_data] WARNING: pg_ctl reload failed while refreshing network allow entries." >&2
      fi
    fi
    exit 0
  fi
  echo "[core_data] FORCE_RENDER_CONFIG=1 set; re-rendering templates." >&2
  rm -f "${SENTINEL}"
fi

# During initial Docker init (first_render=1), we need to stop the Docker
# entrypoint's temporary postgres so we can start it with our rendered config
# (which includes shared_preload_libraries for extensions like pgaudit).
#
# On subsequent runs (first_render=0 with FORCE_RENDER_CONFIG=1), we also need
# to stop postgres before re-rendering configs.
if [[ "${first_render}" -eq 1 ]]; then
  if pg_ctl -D "${PGDATA}" status > /dev/null 2>&1; then
    echo "[core_data] Stopping PostgreSQL before initial configuration render." >&2
    pg_ctl -D "${PGDATA}" -m fast -w stop > /dev/null 2>&1 || true
  fi
fi

if [[ "${POSTGRES_SSL_ENABLED}" == "on" ]]; then
  CERT_DIR=$(dirname "${POSTGRES_SSL_CERT_FILE}")
  KEY_DIR=$(dirname "${POSTGRES_SSL_KEY_FILE}")
  mkdir -p "${CERT_DIR}" "${KEY_DIR}"
  if [[ ! -f "${POSTGRES_SSL_CERT_FILE}" || ! -f "${POSTGRES_SSL_KEY_FILE}" ]]; then
    echo "[core_data] Generating self-signed TLS certificate for PostgreSQL." >&2
    if ! command -v openssl > /dev/null 2>&1; then
      echo "[core_data] ERROR: openssl not available; cannot create TLS assets." >&2
      exit 1
    fi
    openssl req -x509 -nodes -newkey rsa:4096 \
      -keyout "${POSTGRES_SSL_KEY_FILE}" \
      -out "${POSTGRES_SSL_CERT_FILE}" \
      -days "${POSTGRES_SSL_SELF_SIGNED_DAYS}" \
      -subj "${POSTGRES_SSL_SELF_SIGNED_SUBJECT}" > /dev/null 2>&1
    chmod 600 "${POSTGRES_SSL_KEY_FILE}"
    chmod 644 "${POSTGRES_SSL_CERT_FILE}"
  fi
fi

if command -v envsubst > /dev/null 2>&1; then
  envsubst < "${TEMPLATE_DIR}/postgresql.conf.tpl" > "${PGDATA}/postgresql.conf"
  envsubst < "${TEMPLATE_DIR}/pg_hba.conf.tpl" > "${PGDATA}/pg_hba.conf"
else
  echo "envsubst not installed inside container" >&2
  exit 1
fi

if [[ -d "${TEMPLATE_DIR}/pg_hba.d" ]]; then
  shopt -s nullglob
  extra_files=("${TEMPLATE_DIR}/pg_hba.d"/*)
  shopt -u nullglob
  if [[ ${#extra_files[@]} -gt 0 ]]; then
    {
      echo ""
      echo "# --- BEGIN pg_hba.d drop-ins ---"
    } >> "${PGDATA}/pg_hba.conf"
    for extra_file in "${extra_files[@]}"; do
      echo "[core_data] Appending pg_hba drop-in ${extra_file}" >&2
      if command -v envsubst > /dev/null 2>&1; then
        envsubst < "${extra_file}" >> "${PGDATA}/pg_hba.conf"
      else
        cat "${extra_file}" >> "${PGDATA}/pg_hba.conf"
      fi
    done
    echo "# --- END pg_hba.d drop-ins ---" >> "${PGDATA}/pg_hba.conf"
  fi
fi

apply_network_allow_entries

cat > "${PGBACKREST_CONF_PATH}" << CONF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=${PGBACKREST_RETENTION_FULL:-7}
repo1-retention-full-type=${PGBACKREST_RETENTION_FULL_TYPE:-time}
repo1-retention-diff=${PGBACKREST_RETENTION_DIFF:-7}
repo1-retention-archive=${PGBACKREST_RETENTION_ARCHIVE:-7}
repo1-retention-archive-type=${PGBACKREST_RETENTION_ARCHIVE_TYPE:-diff}
process-max=${PGBACKREST_PROCESS_MAX:-4}
start-fast=y
log-level-console=info
archive-check=${PGBACKREST_ARCHIVE_CHECK:-y}

[main]
pg1-path=${PGDATA}
pg1-port=5433
CONF

# Safety belt: enforce shared_preload_libraries even after fresh render
# to catch any drift between the template and the canonical list.
enforce_shared_preload_libraries || true

echo "[core_data] Rendered PostgreSQL configs and pgBackRest configuration." >&2

# Start postgres with our rendered config (which includes shared_preload_libraries).
# On first_render=1, we stopped the Docker entrypoint's temp postgres earlier and now
# start it with our config so extensions like pgaudit can be created.
# On first_render=0 (FORCE_RENDER_CONFIG), restart if it was running.
if [[ "${first_render}" -eq 1 ]]; then
  if ! pg_ctl -D "${PGDATA}" -w start > /dev/null 2>&1; then
    echo "[core_data] WARNING: pg_ctl start failed during initial configuration." >&2
  fi
elif pg_ctl -D "${PGDATA}" status > /dev/null 2>&1; then
  if ! pg_ctl -D "${PGDATA}" -m fast -w restart > /dev/null 2>&1; then
    echo "[core_data] WARNING: pg_ctl restart failed during configuration refresh." >&2
  fi
fi

touch "${SENTINEL}"
