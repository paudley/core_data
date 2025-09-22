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

PASSWORD_FILE=${PGBOUNCER_AUTH_PASSWORD_FILE:-/run/secrets/pgbouncer_auth_password}
if [[ ! -r "${PASSWORD_FILE}" ]]; then
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

mkdir -p /var/log/pgbouncer /var/run/pgbouncer
umask 077
envsubst < /opt/core_data/pgbouncer.ini.tpl > /etc/pgbouncer/pgbouncer.ini
envsubst < /opt/core_data/userlist.txt.tpl > /etc/pgbouncer/userlist.txt
unset PGBOUNCER_AUTH_PASSWORD PGBOUNCER_STATS_PASSWORD
PGBOUNCER_BIN=${PGBOUNCER_BIN:-$(command -v pgbouncer)}
exec "${PGBOUNCER_BIN}" /etc/pgbouncer/pgbouncer.ini
