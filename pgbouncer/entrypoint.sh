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
export POSTGRES_PORT=${POSTGRES_PORT:-5433}
export PGBOUNCER_AUTH_USER=${PGBOUNCER_AUTH_USER:-pgbouncer_auth}
export POSTGRES_DB=${POSTGRES_DB:-postgres}

# Client TLS configuration (connections from clients to PgBouncer)
export PGBOUNCER_CLIENT_TLS_SSLMODE=${PGBOUNCER_CLIENT_TLS_SSLMODE:-require}
export PGBOUNCER_CLIENT_TLS_CERT_FILE=${PGBOUNCER_CLIENT_TLS_CERT_FILE:-/tmp/pgbouncer/tls/server.crt}
export PGBOUNCER_CLIENT_TLS_KEY_FILE=${PGBOUNCER_CLIENT_TLS_KEY_FILE:-/tmp/pgbouncer/tls/server.key}
export PGBOUNCER_CLIENT_TLS_SELF_SIGNED_SUBJECT=${PGBOUNCER_CLIENT_TLS_SELF_SIGNED_SUBJECT:-/CN=core_data_pgbouncer}
export PGBOUNCER_CLIENT_TLS_SELF_SIGNED_DAYS=${PGBOUNCER_CLIENT_TLS_SELF_SIGNED_DAYS:-730}

# Transaction mode compatibility (PgBouncer 1.21+)
export PGBOUNCER_MAX_PREPARED_STATEMENTS=${PGBOUNCER_MAX_PREPARED_STATEMENTS:-1024}
export PGBOUNCER_IGNORE_STARTUP_PARAMETERS=${PGBOUNCER_IGNORE_STARTUP_PARAMETERS:-extra_float_digits,options}
export PGBOUNCER_TRACK_EXTRA_PARAMETERS=${PGBOUNCER_TRACK_EXTRA_PARAMETERS:-IntervalStyle}
export PGBOUNCER_APPLICATION_NAME_ADD_HOST=${PGBOUNCER_APPLICATION_NAME_ADD_HOST:-1}

# Connection lifecycle
export PGBOUNCER_SERVER_LIFETIME=${PGBOUNCER_SERVER_LIFETIME:-1800}
export PGBOUNCER_SERVER_IDLE_TIMEOUT=${PGBOUNCER_SERVER_IDLE_TIMEOUT:-300}
export PGBOUNCER_SERVER_CONNECT_TIMEOUT=${PGBOUNCER_SERVER_CONNECT_TIMEOUT:-10}
export PGBOUNCER_SERVER_LOGIN_RETRY=${PGBOUNCER_SERVER_LOGIN_RETRY:-5}

# Client timeout protection
export PGBOUNCER_QUERY_WAIT_TIMEOUT=${PGBOUNCER_QUERY_WAIT_TIMEOUT:-30}
export PGBOUNCER_CLIENT_IDLE_TIMEOUT=${PGBOUNCER_CLIENT_IDLE_TIMEOUT:-3600}

# DNS failover
export PGBOUNCER_DNS_MAX_TTL=${PGBOUNCER_DNS_MAX_TTL:-30}
export PGBOUNCER_DNS_NXDOMAIN_TTL=${PGBOUNCER_DNS_NXDOMAIN_TTL:-5}

wait_for_backend() {
	local attempts=${PGBOUNCER_BACKEND_WAIT_ATTEMPTS:-120}
	local delay=2
	local attempt=1
	while ((attempt <= attempts)); do
		if command -v pg_isready >/dev/null 2>&1; then
			if pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" >/dev/null 2>&1; then
				return 0
			fi
		elif command -v nc >/dev/null 2>&1; then
			if nc -z "${POSTGRES_HOST}" "${POSTGRES_PORT}" >/dev/null 2>&1; then
				return 0
			fi
		else
			if bash -c "exec 3<>/dev/tcp/${POSTGRES_HOST}/${POSTGRES_PORT}" >/dev/null 2>&1; then
				exec 3>&-
				return 0
			fi
		fi
		echo "[pgbouncer] waiting for PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT} (attempt ${attempt})" >&2
		sleep "${delay}"
		if ((attempt % 10 == 0 && delay < 10)); then
			delay=$((delay + 1))
		fi
		attempt=$((attempt + 1))
	done
	echo "[pgbouncer] timed out waiting for PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT}" >&2
	exit 1
}

NETWORK_ACCESS_DIR=${NETWORK_ACCESS_DIR:-/opt/core_data/network_access}
NETWORK_ALLOW_FILE=${NETWORK_ALLOW_FILE:-${NETWORK_ACCESS_DIR}/allow.list}

log_dir=${PGBOUNCER_LOG_DIR:-/tmp/pgbouncer/log}
run_dir=${PGBOUNCER_RUN_DIR:-/tmp/pgbouncer/run}
tmp_dir=${PGBOUNCER_TMP_DIR:-/tmp}
config_path=${PGBOUNCER_CONF_FILE:-${tmp_dir}/pgbouncer.ini}
userlist_path=${PGBOUNCER_AUTH_FILE:-${tmp_dir}/userlist.txt}
hba_path=${PGBOUNCER_HBA_FILE:-${tmp_dir}/pgbouncer_hba.conf}
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
export PGUSER="${PGBOUNCER_AUTH_USER}"
export PGDATABASE="${POSTGRES_DB}"
export PGPASSWORD="${pgbouncer_auth_secret}"

STATS_PASSWORD_FILE=${PGBOUNCER_STATS_PASSWORD_FILE:-/run/secrets/pgbouncer_stats_password}
if [[ -r "${STATS_PASSWORD_FILE}" ]]; then
	pgbouncer_stats_secret=$(<"${STATS_PASSWORD_FILE}")
	export PGBOUNCER_STATS_PASSWORD="${pgbouncer_stats_secret}"
else
	export PGBOUNCER_STATS_PASSWORD=""
fi

mkdir -p "${log_dir}" "${run_dir}" "$(dirname "${config_path}")" "$(dirname "${userlist_path}")" "$(dirname "${hba_path}")"
umask 077

# Generate self-signed TLS certificate for client connections if not provided
if [[ "${PGBOUNCER_CLIENT_TLS_SSLMODE}" != "disable" ]]; then
	tls_cert_dir=$(dirname "${PGBOUNCER_CLIENT_TLS_CERT_FILE}")
	tls_key_dir=$(dirname "${PGBOUNCER_CLIENT_TLS_KEY_FILE}")
	mkdir -p "${tls_cert_dir}" "${tls_key_dir}"
	if [[ ! -f "${PGBOUNCER_CLIENT_TLS_CERT_FILE}" || ! -f "${PGBOUNCER_CLIENT_TLS_KEY_FILE}" ]]; then
		echo "[pgbouncer] Generating self-signed TLS certificate for client connections." >&2
		if ! command -v openssl >/dev/null 2>&1; then
			echo "[pgbouncer] ERROR: openssl not available; cannot create TLS assets." >&2
			exit 1
		fi
if ! openssl_output=$(openssl req -x509 -nodes -newkey rsa:4096 \
			-keyout "${PGBOUNCER_CLIENT_TLS_KEY_FILE}" \
			-out "${PGBOUNCER_CLIENT_TLS_CERT_FILE}" \
			-days "${PGBOUNCER_CLIENT_TLS_SELF_SIGNED_DAYS}" \
			-subj "${PGBOUNCER_CLIENT_TLS_SELF_SIGNED_SUBJECT}" 2>&1); then
			echo "[pgbouncer] ERROR: Failed to generate self-signed TLS certificate:" >&2
			echo "${openssl_output}" >&2
			exit 1
		fi
		chmod 600 "${PGBOUNCER_CLIENT_TLS_KEY_FILE}"
		chmod 644 "${PGBOUNCER_CLIENT_TLS_CERT_FILE}"
		echo "[pgbouncer] TLS certificate generated successfully." >&2
	fi
fi

wait_for_backend
unset PGUSER PGDATABASE PGPASSWORD

auth_hba_config=""
if [[ -r "${NETWORK_ALLOW_FILE}" ]]; then
	{
		echo "# Generated by core_data on $(date -Iseconds)"
		echo "# Format mirrors PostgreSQL pg_hba.conf"
	} >"${hba_path}"
	while IFS= read -r cidr; do
		trimmed=$(echo "${cidr}" | sed 's/^\s*//;s/\s*$//')
		[[ -z "${trimmed}" ]] && continue
		[[ "${trimmed}" == \#* ]] && continue
		echo "host all all ${trimmed} scram-sha-256" >>"${hba_path}"
	done <"${NETWORK_ALLOW_FILE}"
	auth_hba_config="auth_hba_file = ${hba_path}"
else
	echo "[pgbouncer] WARNING: ${NETWORK_ALLOW_FILE} not found; defaulting to internal allow rules only." >&2
fi
# Build client TLS configuration block
client_tls_config=""
if [[ "${PGBOUNCER_CLIENT_TLS_SSLMODE}" != "disable" ]]; then
	client_tls_config="client_tls_sslmode = ${PGBOUNCER_CLIENT_TLS_SSLMODE}
client_tls_cert_file = ${PGBOUNCER_CLIENT_TLS_CERT_FILE}
client_tls_key_file = ${PGBOUNCER_CLIENT_TLS_KEY_FILE}"
	echo "[pgbouncer] Client TLS enabled with sslmode=${PGBOUNCER_CLIENT_TLS_SSLMODE}" >&2
fi

cat >"${config_path}" <<EOF
[databases]
* = host=${POSTGRES_HOST} port=${POSTGRES_PORT} auth_user=${PGBOUNCER_AUTH_USER}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${PGBOUNCER_PORT}
auth_type = scram-sha-256
auth_user = ${PGBOUNCER_AUTH_USER}
auth_file = ${userlist_path}
auth_query = SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=\$1
${auth_hba_config}

; === Connection Pool Settings ===
pool_mode = ${PGBOUNCER_POOL_MODE}
max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN}
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE}
reserve_pool_size = ${PGBOUNCER_RESERVE_POOL_SIZE}
reserve_pool_timeout = ${PGBOUNCER_RESERVE_POOL_TIMEOUT}
min_pool_size = ${PGBOUNCER_MIN_POOL_SIZE}

; === Transaction Mode Compatibility (PgBouncer 1.21+) ===
max_prepared_statements = ${PGBOUNCER_MAX_PREPARED_STATEMENTS}
ignore_startup_parameters = ${PGBOUNCER_IGNORE_STARTUP_PARAMETERS}
track_extra_parameters = ${PGBOUNCER_TRACK_EXTRA_PARAMETERS}
application_name_add_host = ${PGBOUNCER_APPLICATION_NAME_ADD_HOST}

; === Session Reset Configuration ===
server_reset_query = DISCARD ALL

; === Connection Lifecycle ===
server_lifetime = ${PGBOUNCER_SERVER_LIFETIME}
server_idle_timeout = ${PGBOUNCER_SERVER_IDLE_TIMEOUT}
server_connect_timeout = ${PGBOUNCER_SERVER_CONNECT_TIMEOUT}
server_login_retry = ${PGBOUNCER_SERVER_LOGIN_RETRY}

; === Client Timeout Protection ===
query_wait_timeout = ${PGBOUNCER_QUERY_WAIT_TIMEOUT}
client_idle_timeout = ${PGBOUNCER_CLIENT_IDLE_TIMEOUT}

; === DNS Failover ===
dns_max_ttl = ${PGBOUNCER_DNS_MAX_TTL}
dns_nxdomain_ttl = ${PGBOUNCER_DNS_NXDOMAIN_TTL}

; === Administration ===
admin_users = ${PGBOUNCER_ADMIN_USERS}
stats_users = ${PGBOUNCER_STATS_USERS}

; === Logging ===
logfile = ${log_dir}/pgbouncer.log
pidfile = ${run_dir}/pgbouncer.pid

; === TLS Configuration ===
server_tls_sslmode = ${PGBOUNCER_SERVER_TLS_MODE:-require}
${client_tls_config}
EOF

cat >"${userlist_path}" <<EOF
"${PGBOUNCER_AUTH_USER}" "${PGBOUNCER_AUTH_PASSWORD}"
"${PGBOUNCER_STATS_USER}" "${PGBOUNCER_STATS_PASSWORD}"
EOF

if [[ -n "${auth_hba_config}" ]]; then
	chmod 600 "${hba_path}"
fi
chmod 600 "${config_path}" "${userlist_path}"
unset PGBOUNCER_AUTH_PASSWORD PGBOUNCER_STATS_PASSWORD
PGBOUNCER_BIN=${PGBOUNCER_BIN:-$(command -v pgbouncer)}
exec "${PGBOUNCER_BIN}" "${config_path}"
