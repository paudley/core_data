# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash

bootstrap_ci_usage() {
	cat <<USAGE
Usage: ${0##*/} bootstrap-ci [--force] [--skip-secrets] [--skip-network] [--skip-data] [--allow CIDR] [--secrets-dir PATH] [--network-dir PATH] [--data-dir PATH] [--backups-dir PATH]

Prepares CI-friendly scaffolding (secrets, network allow lists, persistent directories).
Repeated --allow flags (or CORE_DATA_NETWORK_ALLOW) seed additional CIDRs.
Passwords can be provided via environment variables (POSTGRES_SUPERUSER_PASSWORD, VALKEY_PASSWORD, etc.).
USAGE
}

bootstrap_ci_random_base64() {
	local bytes=${1:-32}
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -base64 "${bytes}" | tr -d '\r\n'
		return
	fi
	if [[ -r /dev/urandom ]]; then
		head -c "${bytes}" /dev/urandom | base64 | tr -d '\r\n'
		return
	fi
	echo "[bootstrap-ci] ERROR: unable to generate random data (install openssl or expose /dev/urandom)." >&2
	return 1
}

bootstrap_ci_random_alnum() {
	local length=${1:-32}
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$length" <<'PY'
import secrets
import string
import sys

length = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(length)))
PY
		return
	fi
	if [[ -r /dev/urandom ]]; then
		tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${length}"
		return
	fi
	echo "[bootstrap-ci] ERROR: unable to generate alphanumeric secret material." >&2
	return 1
}

bootstrap_ci_write_secret() {
	local env_var=$1
	local path=$2
	local force=$3
	local mode=${4:-base64}
	local existing_value="${!env_var-}"
	local source="generated"
	if [[ -f "${path}" && "${force}" != "true" && -z "${existing_value}" ]]; then
		echo "[bootstrap-ci] ${path} exists; keeping current value." >&2
		return
	fi
	local value
	if [[ -n "${existing_value}" ]]; then
		value=${existing_value}
		source="env:${env_var}"
	else
		if [[ "${mode}" == "alnum" ]]; then
			value=$(bootstrap_ci_random_alnum 32) || exit 1
		else
			value=$(bootstrap_ci_random_base64 32) || exit 1
		fi
	fi
	mkdir -p "$(dirname "${path}")"
	printf '%s\n' "${value}" >"${path}"
	chmod 0600 "${path}" || true
	echo "[bootstrap-ci] wrote ${path} (source: ${source})." >&2
}

bootstrap_ci_prepare_directories() {
	local data_dir=$1
	local backups_dir=$2
	mkdir -p "${data_dir}/postgres_data" "${data_dir}/postgres_wal" "${data_dir}/pgbackrest" "${data_dir}/rabbitmq_data" "${data_dir}/valkey_data"
	mkdir -p "${backups_dir}" "${backups_dir}/logical"
	echo "[bootstrap-ci] ensured persistent directories under ${data_dir} and backups in ${backups_dir}." >&2
}

bootstrap_ci_render_networks() {
	local network_dir=$1
	shift
	local -a entries=("$@")
	mkdir -p "${network_dir}"
	local allow_path="${network_dir}/networks.allow"
	if [[ ${#entries[@]} -gt 0 ]]; then
		{
			echo "# Managed by bootstrap-ci on $(date -Iseconds)"
			for cidr in "${entries[@]}"; do
				echo "${cidr}"
			done
		} >"${allow_path}"
		echo "[bootstrap-ci] wrote ${allow_path} with ${#entries[@]} entries." >&2
	else
		touch "${allow_path}"
	fi
	local combined_path="${network_dir}/allow.list"
	{
		echo "# Bootstrap allow list generated on $(date -Iseconds)"
		echo "127.0.0.1/32"
		echo "::1/128"
		for cidr in "${entries[@]}"; do
			echo "${cidr}"
		done
	} >"${combined_path}"
	echo "[bootstrap-ci] seeded ${combined_path}; network_probe will refresh during 'up'." >&2
}

bootstrap_ci_parse_allow_values() {
	local raw=$1
	local -n out_ref=$2
	if [[ -z "${raw}" ]]; then
		return
	fi
	while IFS= read -r line; do
		local trimmed
		trimmed=$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[[ -z "${trimmed}" ]] && continue
		out_ref+=("${trimmed}")
	done < <(printf '%s' "${raw}" | tr ',;' '\n')
}

cmd_bootstrap_ci() {
	local secrets_dir="${ROOT_DIR}/secrets"
	local network_dir="${ROOT_DIR}/network_access"
	local data_dir="${ROOT_DIR}/data"
	local backups_dir="${ROOT_DIR}/backups"
	local allow_values=()
	local force=false
	local skip_secrets=false
	local skip_network=false
	local skip_data=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--secrets-dir)
			secrets_dir=$2
			shift 2
			;;
		--secrets-dir=*)
			secrets_dir=${1#*=}
			shift
			;;
		--network-dir)
			network_dir=$2
			shift 2
			;;
		--network-dir=*)
			network_dir=${1#*=}
			shift
			;;
		--data-dir)
			data_dir=$2
			shift 2
			;;
		--data-dir=*)
			data_dir=${1#*=}
			shift
			;;
		--backups-dir)
			backups_dir=$2
			shift 2
			;;
		--backups-dir=*)
			backups_dir=${1#*=}
			shift
			;;
		--allow)
			allow_values+=("$2")
			shift 2
			;;
		--allow=*)
			allow_values+=("${1#*=}")
			shift
			;;
		--force)
			force=true
			shift
			;;
		--skip-secrets)
			skip_secrets=true
			shift
			;;
		--skip-network)
			skip_network=true
			shift
			;;
		--skip-data)
			skip_data=true
			shift
			;;
		-h | --help)
			bootstrap_ci_usage
			return 0
			;;
		*)
			echo "[bootstrap-ci] Unknown option: $1" >&2
			bootstrap_ci_usage >&2
			return 1
			;;
		esac
	done

	if [[ -n "${CORE_DATA_NETWORK_ALLOW:-}" ]]; then
		bootstrap_ci_parse_allow_values "${CORE_DATA_NETWORK_ALLOW}" allow_values
	fi

	if [[ "${skip_data}" != "true" ]]; then
		bootstrap_ci_prepare_directories "${data_dir}" "${backups_dir}"
	fi

	if [[ "${skip_secrets}" != "true" ]]; then
		mkdir -p "${secrets_dir}"
		chmod 0700 "${secrets_dir}" || true
		bootstrap_ci_write_secret POSTGRES_SUPERUSER_PASSWORD "${secrets_dir}/postgres_superuser_password" "${force}" base64
		bootstrap_ci_write_secret VALKEY_PASSWORD "${secrets_dir}/valkey_password" "${force}" base64
		bootstrap_ci_write_secret PGBOUNCER_AUTH_PASSWORD "${secrets_dir}/pgbouncer_auth_password" "${force}" base64
		bootstrap_ci_write_secret PGBOUNCER_STATS_PASSWORD "${secrets_dir}/pgbouncer_stats_password" "${force}" base64
		bootstrap_ci_write_secret RABBITMQ_DEFAULT_PASS "${secrets_dir}/rabbitmq_default_pass" "${force}" base64
		bootstrap_ci_write_secret RABBITMQ_ERLANG_COOKIE "${secrets_dir}/rabbitmq_erlang_cookie" "${force}" alnum
	fi

	if [[ "${skip_network}" != "true" ]]; then
		bootstrap_ci_render_networks "${network_dir}" "${allow_values[@]}"
	fi

	echo "[bootstrap-ci] bootstrap complete (secrets=${skip_secrets:-false}, network=${skip_network:-false}, data=${skip_data:-false})." >&2
}
