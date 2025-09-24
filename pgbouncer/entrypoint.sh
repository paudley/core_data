#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

export PGBOUNCER_PORT=${PGBOUNCER_PORT:-6432}
export PGBOUNCER_POOL_MODE=${PGBOUNCER_POOL_MODE:-transaction}
export PGBOUNCER_MAX_CLIENT_CONN=${PGBOUNCER_MAX_CLIENT_CONN:-200}
export PGBOUNCER_DEFAULT_POOL_SIZE=${PGBOUNCER_DEFAULT_POOL_SIZE:-20}
export PGBOUNCER_RESERVE_POOL_SIZE=${PGBOUNCER_RESERVE_POOL_SIZE:-5}
export PGBOUNCER_RESERVE_POOL_TIMEOUT=${PGBOUNCER_RESERVE_POOL_TIMEOUT:-5}
export PGBOUNCER_MIN_POOL_SIZE=${PGBOUNCER_MIN_POOL_SIZE:-5}
export PGBOUNCER_ADMIN_USERS=${PGBOUNCER_ADMIN_USERS:-postgres}
export PGBOUNCER_STATS_USER=${PGBOUNCER_STATS_USER:-pgbouncer_stats}
export PGBOUNCER_STATS_USERS=${PGBOUNCER_STATS_USERS:-${PGBOUNCER_STATS_USER}}
export POSTGRES_HOST=${POSTGRES_HOST:-postgres}
export POSTGRES_PORT=${POSTGRES_PORT:-5432}
export PGBOUNCER_AUTH_USER=${PGBOUNCER_AUTH_USER:-pgbouncer_auth}

log_dir=${PGBOUNCER_LOG_DIR:-/tmp/pgbouncer/log}
run_dir=${PGBOUNCER_RUN_DIR:-/tmp/pgbouncer/run}
tmp_dir=${PGBOUNCER_TMP_DIR:-/tmp}
config_path=${PGBOUNCER_CONF_FILE:-${tmp_dir}/pgbouncer.ini}
userlist_path=${PGBOUNCER_AUTH_FILE:-${tmp_dir}/userlist.txt}
export PGBOUNCER_LOG_DIR="${log_dir}"
export PGBOUNCER_RUN_DIR="${run_dir}"

PASSWORD_FILE=${PGBOUNCER_AUTH_PASSWORD_FILE:-/run/secrets/pgbouncer_auth_password}
if [[ ! -r "${PASSWORD_FILE}" ]]; then
  if [[ -d /run/secrets ]]; then
    echo "[pgbouncer] DEBUG: available secrets:" >&2
    ls -l /run/secrets >&2 || true
  fi
  echo "[pgbouncer] ERROR: auth password file ${PASSWORD_FILE} not found" >&2
  exit 1
fi
pgbouncer_auth_secret=$(<"${PASSWORD_FILE}")
export PGBOUNCER_AUTH_PASSWORD="${pgbouncer_auth_secret}"

STATS_PASSWORD_FILE=${PGBOUNCER_STATS_PASSWORD_FILE:-/run/secrets/pgbouncer_stats_password}
if [[ -r "${STATS_PASSWORD_FILE}" ]]; then
  pgbouncer_stats_secret=$(<"${STATS_PASSWORD_FILE}")
  export PGBOUNCER_STATS_PASSWORD="${pgbouncer_stats_secret}"
else
  export PGBOUNCER_STATS_PASSWORD=""
fi

mkdir -p "${log_dir}" "${run_dir}" "$(dirname "${config_path}")" "$(dirname "${userlist_path}")"
umask 077
cat > "${config_path}" <<EOF
[databases]
* = host=${POSTGRES_HOST} port=${POSTGRES_PORT} auth_user=${PGBOUNCER_AUTH_USER}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${PGBOUNCER_PORT}
auth_type = scram-sha-256
auth_user = ${PGBOUNCER_AUTH_USER}
auth_file = ${userlist_path}
auth_query = SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=\$1
pool_mode = ${PGBOUNCER_POOL_MODE}
max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN}
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE}
reserve_pool_size = ${PGBOUNCER_RESERVE_POOL_SIZE}
reserve_pool_timeout = ${PGBOUNCER_RESERVE_POOL_TIMEOUT}
min_pool_size = ${PGBOUNCER_MIN_POOL_SIZE}
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits
admin_users = ${PGBOUNCER_ADMIN_USERS}
stats_users = ${PGBOUNCER_STATS_USERS}
logfile = ${log_dir}/pgbouncer.log
pidfile = ${run_dir}/pgbouncer.pid
EOF

cat > "${userlist_path}" <<EOF
"${PGBOUNCER_AUTH_USER}" "${PGBOUNCER_AUTH_PASSWORD}"
"${PGBOUNCER_STATS_USER}" "${PGBOUNCER_STATS_PASSWORD}"
EOF

chmod 600 "${config_path}" "${userlist_path}"
unset PGBOUNCER_AUTH_PASSWORD PGBOUNCER_STATS_PASSWORD
PGBOUNCER_BIN=${PGBOUNCER_BIN:-$(command -v pgbouncer)}
exec "${PGBOUNCER_BIN}" "${config_path}"
