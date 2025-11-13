#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

NETWORK_DIR=${NETWORK_DIR:-/opt/core_data/network_access}
ALLOW_FILE=${ALLOW_FILE:-${NETWORK_DIR}/allow.list}
CHECK_INTERVAL=${CHECK_INTERVAL:-30}
SERVICES=${SERVICES:-"5432 8080 6432 6379 5672 15672 11211"}
CHAIN_V4=${CHAIN_V4:-CORE_DATA_ALLOW_V4}
CHAIN_V6=${CHAIN_V6:-CORE_DATA_ALLOW_V6}
RULE_COMMENT="core-data-allow"

ensure_command() {
	local cmd=$1
	local pkg=$2
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		if command -v apk >/dev/null 2>&1; then
			apk add --no-cache "${pkg}" >/dev/null 2>&1
		elif command -v apt-get >/dev/null 2>&1; then
			apt-get update >/dev/null 2>&1
			apt-get install -y --no-install-recommends "${pkg}" >/dev/null 2>&1
		else
			echo "[network_guard] ERROR: unable to install dependency ${pkg}" >&2
			exit 1
		fi
	fi
}

# iptables is required; ip6tables optional (best-effort, skipped if unsupported)
ensure_command iptables iptables
has_ip6tables=false
if command -v ip6tables >/dev/null 2>&1; then has_ip6tables=true; fi
ensure_command sha256sum coreutils

create_chain() {
	local tool=$1
	local chain=$2
	if ! ${tool} -L "${chain}" >/dev/null 2>&1; then
		${tool} -N "${chain}" >/dev/null 2>&1 || return 1
	else
		${tool} -F "${chain}" >/dev/null 2>&1 || return 1
	fi
	${tool} -A "${chain}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN >/dev/null 2>&1 || return 1
	return 0
}

add_network_rules() {
	local tool=$1
	local chain=$2
	shift 2
	local networks=("$@")
	for net in "${networks[@]}"; do
		${tool} -A "${chain}" -s "${net}" -j RETURN >/dev/null 2>&1 || return 1
	done
	${tool} -A "${chain}" -j DROP >/dev/null 2>&1 || return 1
	return 0
}

remove_existing_rules() {
	local tool=$1
	local chain=$2
	shift 2
	local ports=("$@")
	for port in "${ports[@]}"; do
		while ${tool} -C DOCKER-USER -p tcp --dport "${port}" -m comment --comment "${RULE_COMMENT}" -j "${chain}" >/dev/null 2>&1; do
			${tool} -D DOCKER-USER -p tcp --dport "${port}" -m comment --comment "${RULE_COMMENT}" -j "${chain}" >/dev/null 2>&1 || break
		done
	done
}

insert_rules() {
	local tool=$1
	local chain=$2
	shift 2
	local ports=("$@")
	for port in "${ports[@]}"; do
		${tool} -I DOCKER-USER 1 -p tcp --dport "${port}" -m comment --comment "${RULE_COMMENT}" -j "${chain}" >/dev/null 2>&1 || return 1
	done
	return 0
}

read_allow_file() {
	local file=$1
	if [[ ! -f "${file}" ]]; then
		echo "[network_guard] Waiting for ${file}..." >&2
		return 1
	fi
	mapfile -t raw < <(grep -v '^[[:space:]]*#' "${file}" | sed '/^[[:space:]]*$/d')
	ipv4=()
	ipv6=()
	for entry in "${raw[@]}"; do
		trimmed=$(echo "${entry}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[[ -z "${trimmed}" ]] && continue
		if [[ "${trimmed}" == *:* ]]; then
			ipv6+=("${trimmed}")
		else
			ipv4+=("${trimmed}")
		fi
	done
	return 0
}

last_hash=""
while true; do
	if [[ -f "${ALLOW_FILE}" ]]; then
		current_hash=$(sha256sum "${ALLOW_FILE}" | awk '{print $1}')
		if [[ "${current_hash}" != "${last_hash}" ]]; then
			if read_allow_file "${ALLOW_FILE}"; then
				if ! iptables -S DOCKER-USER >/dev/null 2>&1; then
					iptables -N DOCKER-USER
					iptables -A DOCKER-USER -j RETURN
				fi
				if [[ "${has_ip6tables}" == true ]] && ! ip6tables -S DOCKER-USER >/dev/null 2>&1; then
					ip6tables -N DOCKER-USER
					ip6tables -A DOCKER-USER -j RETURN
				fi
				create_chain iptables "${CHAIN_V4}"
				if [[ ${#ipv4[@]} -gt 0 ]]; then
					add_network_rules iptables "${CHAIN_V4}" "${ipv4[@]}"
				fi
				read -ra port_array <<<"${SERVICES}"
				ports=()
				for port in "${port_array[@]}"; do
					[[ -z "${port}" ]] && continue
					ports+=("${port}")
				done
				if [[ ${#ports[@]} -gt 0 ]]; then
					remove_existing_rules iptables "${CHAIN_V4}" "${ports[@]}" || true
					insert_rules iptables "${CHAIN_V4}" "${ports[@]}"
				fi
				if [[ "${has_ip6tables}" == true ]]; then
					if create_chain ip6tables "${CHAIN_V6}" 2>/dev/null; then
						if [[ ${#ipv6[@]} -gt 0 ]]; then
							add_network_rules ip6tables "${CHAIN_V6}" "${ipv6[@]}"
						fi
						if [[ ${#ports[@]} -gt 0 ]]; then
							remove_existing_rules ip6tables "${CHAIN_V6}" "${ports[@]}" || true
							insert_rules ip6tables "${CHAIN_V6}" "${ports[@]}"
						fi
					else
						echo "[network_guard] WARNING: Failed to manage IPv6 rules; disabling IPv6 enforcement." >&2
						has_ip6tables=false
					fi
				fi
				last_hash="${current_hash}"
				echo "[network_guard] Applied firewall rules for ${ALLOW_FILE}" >&2
			fi
		fi
	fi
	sleep "${CHECK_INTERVAL}"
done
