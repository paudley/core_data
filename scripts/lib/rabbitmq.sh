#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

RABBITMQ_SERVICE_NAME=${RABBITMQ_SERVICE_NAME:-rabbitmq}
RABBITMQ_HOST=${RABBITMQ_HOST:-rabbitmq}
RABBITMQ_PORT=${RABBITMQ_PORT:-5672}
RABBITMQ_MANAGEMENT_PORT=${RABBITMQ_MANAGEMENT_PORT:-15672}
RABBITMQ_STREAM_PORT=${RABBITMQ_STREAM_PORT:-5552}

ensure_rabbitmq_service() {
	if ! compose_has_service "${RABBITMQ_SERVICE_NAME}"; then
		echo "[rabbitmq] ERROR: RabbitMQ service not enabled (ensure compose profile 'rabbitmq' is active)." >&2
		exit 1
	fi
}

rabbitmq_exec() {
	compose_exec_service "${RABBITMQ_SERVICE_NAME}" "$@"
}

cmd_rabbitmq_ctl() {
	ensure_env
	ensure_rabbitmq_service
	if [[ $# -lt 1 ]]; then
		echo "Usage: ${0##*/} rabbitmq-ctl <args>" >&2
		exit 1
	fi
	rabbitmq_exec rabbitmqctl "$@"
}

cmd_rabbitmq_diagnostics() {
	ensure_env
	ensure_rabbitmq_service
	if [[ $# -lt 1 ]]; then
		echo "Usage: ${0##*/} rabbitmq-diagnostics <command> [args]" >&2
		exit 1
	fi
	rabbitmq_exec rabbitmq-diagnostics "$@"
}

cmd_rabbitmq_export() {
	ensure_env
	ensure_rabbitmq_service

	local output_path="./backups/rabbitmq-definitions.json"
	while [[ $# -gt 0 ]]; do
		case $1 in
		--output)
			output_path=$2
			shift 2
			;;
		--output=*)
			output_path=${1#*=}
			shift
			;;
		--help | -h)
			cat <<USAGE
Usage: ${0##*/} rabbitmq-export [--output PATH]

Exports RabbitMQ definitions (users, vhosts, queues, exchanges, bindings) using
rabbitmqctl export_definitions. Defaults to ./backups/rabbitmq-definitions.json.
USAGE
			return 0
			;;
		*)
			echo "[rabbitmq] Unknown option: ${1}" >&2
			return 1
			;;
		esac
	done

	mkdir -p "$(dirname "${output_path}")"
	local container_tmp="/tmp/core_data_rabbitmq_definitions.json"
	if ! rabbitmq_exec rabbitmqctl export_definitions "${container_tmp}" >&2; then
		echo "[rabbitmq] ERROR: rabbitmqctl export_definitions failed." >&2
		return 1
	fi
	if ! rabbitmq_exec cat "${container_tmp}" >"${output_path}"; then
		echo "[rabbitmq] ERROR: unable to copy definitions to host path ${output_path}." >&2
		return 1
	fi
	rabbitmq_exec rm -f "${container_tmp}" >/dev/null 2>&1 || true
	chmod 0600 "${output_path}" 2>/dev/null || true
	echo "[rabbitmq] Definitions written to ${output_path}" >&2
}

cmd_rabbitmq_plugins() {
	ensure_env
	ensure_rabbitmq_service
	rabbitmq_exec rabbitmq-plugins list "$@"
}

cmd_rabbitmq_overview() {
	ensure_env
	ensure_rabbitmq_service
	rabbitmq_exec rabbitmq-diagnostics status
}
