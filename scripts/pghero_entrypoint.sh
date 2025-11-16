#!/bin/sh
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -eu

POSTGRES_SUPERUSER=${POSTGRES_SUPERUSER:-postgres}
POSTGRES_DB=${POSTGRES_DB:-postgres}
POSTGRES_HOST=${POSTGRES_HOST:-postgres}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
PASSWORD_FILE=${POSTGRES_SUPERUSER_PASSWORD_FILE:-/run/secrets/postgres_superuser_password}

wait_for_password_file() {
	attempts=${PGHERO_SECRET_WAIT_ATTEMPTS:-60}
	delay=${PGHERO_SECRET_WAIT_DELAY:-1}
	attempt=1
	while [ "${attempt}" -le "${attempts}" ]; do
		if [ -r "${PASSWORD_FILE}" ]; then
			return 0
		fi
		sleep "${delay}"
		attempt=$((attempt + 1))
	done
	echo "[pghero] password file ${PASSWORD_FILE} not readable after ${attempts} attempts" >&2
	return 1
}

ensure_passwd_entry() {
	if getent passwd "$(id -u)" >/dev/null 2>&1; then
		return
	fi
	tmp_passwd=$(mktemp)
	tmp_group=$(mktemp)
	cp /etc/passwd "${tmp_passwd}"
	cp /etc/group "${tmp_group}"
	cat <<EOF >>"${tmp_passwd}"
pghero:x:$(id -u):$(id -g):PgHero Runtime:/opt/core_data:/bin/sh
EOF
	cat <<EOF >>"${tmp_group}"
pghero:x:$(id -g):
EOF
	export LD_PRELOAD=libnss_wrapper.so
	export NSS_WRAPPER_PASSWD="${tmp_passwd}"
	export NSS_WRAPPER_GROUP="${tmp_group}"
	trap 'rm -f "${NSS_WRAPPER_PASSWD:-}" "${NSS_WRAPPER_GROUP:-}"' EXIT
}

if ! wait_for_password_file; then
	exit 1
fi

PASSWORD=$(cat "${PASSWORD_FILE}")
export DATABASE_URL="postgres://${POSTGRES_SUPERUSER}:${PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=prefer"
export PGHERO_DATABASE_URL="${DATABASE_URL}"

ensure_passwd_entry

wait_for_database() {
		attempts=${PGHERO_DB_WAIT_ATTEMPTS:-90}
		delay=2
		attempt=1
		while [ "${attempt}" -le "${attempts}" ]; do
			if DATABASE_URL="${DATABASE_URL}" bundle exec ruby -e "require 'pg'; conn = PG.connect(ENV['DATABASE_URL']); conn.exec('SELECT 1'); conn.close" >/dev/null 2>&1; then
				return 0
			fi
			echo "[pghero] waiting for PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT} (attempt ${attempt})" >&2
			sleep "${delay}"
			if [ $((attempt % 10)) -eq 0 ] && [ "${delay}" -lt 10 ]; then
				delay=$((delay + 1))
			fi
			attempt=$((attempt + 1))
		done
		echo "[pghero] timed out waiting for PostgreSQL" >&2
		exit 1
	}

wait_for_database

exec bundle exec puma -C /app/config/puma.rb
