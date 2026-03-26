#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Ensures every non-template database has all extensions from CORE_EXTENSION_LIST.
# Designed to run in the background after postgres starts, so that new extensions
# added to the image are automatically provisioned on existing clusters.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck disable=SC1091
source /opt/core_data/scripts/lib/extensions_list.sh
# shellcheck disable=SC1091
source /opt/core_data/scripts/lib/extensions_helpers.sh

# Resolve password for psql
if [[ -z "${PGPASSWORD:-}" ]]; then
	if [[ -n "${POSTGRES_PASSWORD_FILE:-}" && -r "${POSTGRES_PASSWORD_FILE}" ]]; then
		PGPASSWORD=$(<"${POSTGRES_PASSWORD_FILE}")
		export PGPASSWORD
	elif [[ -n "${POSTGRES_SUPERUSER_PASSWORD_FILE:-}" && -r "${POSTGRES_SUPERUSER_PASSWORD_FILE}" ]]; then
		PGPASSWORD=$(<"${POSTGRES_SUPERUSER_PASSWORD_FILE}")
		export PGPASSWORD
	fi
fi

PG_USER="${POSTGRES_USER:-postgres}"
PG_PORT="${PGPORT:-5433}"

# Wait for postgres to accept connections
echo "[ensure_extensions] Waiting for PostgreSQL to become ready..." >&2
until psql -U "${PG_USER}" -h 127.0.0.1 -p "${PG_PORT}" -d postgres -c "SELECT 1;" >/dev/null 2>&1; do
	sleep 2
done
echo "[ensure_extensions] PostgreSQL is ready." >&2

# Also enforce shared_preload_libraries in case the config drifted
source /opt/core_data/scripts/lib/extensions_list.sh
conf_file="${PGDATA}/postgresql.conf"
if [[ -f "${conf_file}" ]]; then
	current=$(grep -E "^shared_preload_libraries" "${conf_file}" | sed "s/shared_preload_libraries *= *'\\(.*\\)'/\\1/")
	missing=()
	for lib in "${REQUIRED_PRELOAD_LIBRARIES[@]}"; do
		if ! echo ",${current}," | grep -q ",${lib},"; then
			missing+=("${lib}")
		fi
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		new_value="${current}"
		for lib in "${missing[@]}"; do
			new_value="${new_value},${lib}"
		done
		sed -i "s|^shared_preload_libraries *= *'.*'|shared_preload_libraries = '${new_value}'|" "${conf_file}"
		echo "[ensure_extensions] Corrected shared_preload_libraries to: ${new_value}" >&2
		echo "[ensure_extensions] WARNING: PostgreSQL must be restarted for shared_preload_libraries changes to take effect." >&2
	fi
fi

# Get all non-template databases
mapfile -t target_dbs < <(psql -t -A -U "${PG_USER}" -h 127.0.0.1 -p "${PG_PORT}" -d postgres -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

DOLLAR='$'

for db in "${target_dbs[@]}"; do
	echo "[ensure_extensions] Syncing extensions in database '${db}'..." >&2
	for ext in "${CORE_EXTENSION_LIST[@]}"; do
		# pg_cron can only be created in the cron.database_name database
		if [[ "${ext}" == "pg_cron" && "${db}" != "postgres" ]]; then
			continue
		fi
		if [[ "${ext}" == "pg_partman" ]]; then
			pg_partman_sql=$(generate_pg_partman_sql)
			psql --set ON_ERROR_STOP=on -U "${PG_USER}" -h 127.0.0.1 -p "${PG_PORT}" -d "${db}" -c "${pg_partman_sql}" >/dev/null 2>&1 || \
				echo "[ensure_extensions] WARNING: failed to sync pg_partman in '${db}'." >&2
			continue
		fi
		psql --set ON_ERROR_STOP=on -U "${PG_USER}" -h 127.0.0.1 -p "${PG_PORT}" -d "${db}" \
			-c "CREATE EXTENSION IF NOT EXISTS \"${ext}\";" >/dev/null 2>&1 || \
			echo "[ensure_extensions] WARNING: failed to create extension '${ext}' in '${db}'." >&2
	done
done

# Also sync template1 so new databases inherit extensions
echo "[ensure_extensions] Syncing extensions in template1..." >&2
for ext in "${CORE_EXTENSION_LIST[@]}"; do
	if [[ "${ext}" == "pg_cron" ]]; then
		continue
	fi
	if [[ "${ext}" == "pg_partman" ]]; then
		pg_partman_sql=$(generate_pg_partman_sql)
		psql --set ON_ERROR_STOP=on -U "${PG_USER}" -h 127.0.0.1 -p "${PG_PORT}" -d template1 -c "${pg_partman_sql}" >/dev/null 2>&1 || true
		continue
	fi
	psql --set ON_ERROR_STOP=on -U "${PG_USER}" -h 127.0.0.1 -p "${PG_PORT}" -d template1 \
		-c "CREATE EXTENSION IF NOT EXISTS \"${ext}\";" >/dev/null 2>&1 || true
done

echo "[ensure_extensions] Extension sync complete." >&2
