#!/usr/bin/env sh
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -eu

user="${RABBITMQ_DEFAULT_USER:-guest}"
password="${RABBITMQ_DEFAULT_PASS:-}"
if [ -z "${password}" ] && [ -r /run/secrets/rabbitmq_default_pass ]; then
	password=$(tr -d '\r\n' </run/secrets/rabbitmq_default_pass)
fi
port="${RABBITMQ_MANAGEMENT_PORT:-15672}"

if [ -z "${password}" ]; then
	echo "[rabbitmq-healthcheck] missing RABBITMQ_DEFAULT_PASS" >&2
	exit 1
fi

url="http://127.0.0.1:${port}/api/health/checks/alarms"
auth_header="$(printf '%s:%s' "${user}" "${password}" | base64)"

if ! wget --quiet --spider --header "Authorization: Basic ${auth_header}" "${url}" >/dev/null 2>&1; then
	echo "[rabbitmq-healthcheck] management API check_failed" >&2
	exit 1
fi

exit 0
