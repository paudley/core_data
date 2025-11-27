#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Permission health check - runs after extensions are enabled (02-enable-extensions.sh).
# Validates and auto-repairs permissions for database owners across all extension schemas.

set -euo pipefail

# Environment variable controls
CORE_DATA_PERMISSION_HEALTHCHECK=${CORE_DATA_PERMISSION_HEALTHCHECK:-1}
CORE_DATA_PERMISSION_REPAIR=${CORE_DATA_PERMISSION_REPAIR:-1}

if [[ "${CORE_DATA_PERMISSION_HEALTHCHECK}" == "0" ]]; then
	echo "[core_data] Permission health check disabled via CORE_DATA_PERMISSION_HEALTHCHECK=0" >&2
	exit 0
fi

# Load password from file if not already set
if [[ -z "${POSTGRES_PASSWORD:-}" && -n "${POSTGRES_PASSWORD_FILE:-}" && -r "${POSTGRES_PASSWORD_FILE}" ]]; then
	POSTGRES_PASSWORD=$(<"${POSTGRES_PASSWORD_FILE}")
fi

if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
	export PGPASSWORD="${POSTGRES_PASSWORD}"
fi

# Wait for PostgreSQL to be ready, with a timeout
MAX_RETRIES=60
RETRY_COUNT=0
until psql --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" --command "SELECT 1;" >/dev/null 2>&1; do
	RETRY_COUNT=$((RETRY_COUNT + 1))
	if [[ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]]; then
		echo "[core_data] ERROR: PostgreSQL did not become ready after ${MAX_RETRIES} attempts. Exiting." >&2
		exit 1
	fi
	sleep 1
done

# Set execution mode for permissions library
export POSTGRES_EXEC_MODE="container"

# Source the permissions library
# shellcheck disable=SC1091
source /opt/core_data/scripts/lib/permissions.sh

# Determine repair mode from environment
repair_mode="true"
if [[ "${CORE_DATA_PERMISSION_REPAIR}" == "0" ]]; then
	repair_mode="false"
fi

# Run the health check
startup_permission_healthcheck "${repair_mode}"
