#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

NETWORK_DIR=${NETWORK_DIR:-/opt/core_data/network_access}
ALLOW_SAMPLE=${NETWORK_DIR}/networks.allow.sample
USER_ALLOW=${NETWORK_DIR}/networks.allow
AUTO_ALLOW=${NETWORK_DIR}/networks.auto
RENDERED_ALLOW=${NETWORK_DIR}/allow.list
DOCKER_NETWORK_SUBNET=${DOCKER_NETWORK_SUBNET:-}

mkdir -p "${NETWORK_DIR}"

if [[ ! -f "${ALLOW_SAMPLE}" ]]; then
	cat >"${ALLOW_SAMPLE}" <<'SAMPLE'
# Allow specific client networks (one CIDR per line).
# Lines beginning with # are treated as comments.
#
# Example entries:
# 10.0.0.0/24
# 203.0.113.55/32
# 2001:db8::/64
#
# Copy to networks.allow and adjust as needed.
SAMPLE
fi

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
			echo "[network_probe] ERROR: unable to install dependency ${pkg}" >&2
			exit 1
		fi
	fi
}

ensure_command ip iproute2
ensure_command awk gawk

declare -A networks_seen=()
add_network() {
	local cidr=$1
	if [[ -z "${cidr}" ]]; then
		return
	fi
	networks_seen["${cidr}"]=1
}

# Default loopback entries
add_network "127.0.0.1/32"
add_network "::1/128"

# Docker network subnet if defined
if [[ -n "${DOCKER_NETWORK_SUBNET}" ]]; then
	add_network "${DOCKER_NETWORK_SUBNET}"
fi

# Enumerate host IPv4 addresses (one /32 each)
while IFS= read -r line; do
	addr=${line%/*}
	if [[ -n "${addr}" ]]; then
		add_network "${addr}/32"
	fi
done < <(ip -o -4 addr show scope global | awk '{print $4}')

# Enumerate IPv6 global addresses (one /128 each)
while IFS= read -r line; do
	addr=${line%/*}
	if [[ -n "${addr}" ]]; then
		add_network "${addr}/128"
	fi
done < <(ip -o -6 addr show scope global | awk '{print $4}')

# Include Docker bridge gateway if available
if ip addr show docker0 >/dev/null 2>&1; then
	if gateway=$(ip -o -4 addr show dev docker0 scope global | awk '{print $4}'); then
		addr=${gateway%/*}
		[[ -n "${addr}" ]] && add_network "${addr}/32"
	fi
fi

mapfile -t auto_entries < <(
	for cidr in "${!networks_seen[@]}"; do
		printf '%s\n' "${cidr}"
	done | sort
)

printf "# Auto-generated on %s\n" "$(date -Iseconds)" >"${AUTO_ALLOW}"
for entry in "${auto_entries[@]}"; do
	printf "%s\n" "${entry}" >>"${AUTO_ALLOW}"
done

read_user_entries() {
	local file=$1
	if [[ ! -f "${file}" ]]; then
		return
	fi
	while IFS= read -r line; do
		trimmed=$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[[ -z "${trimmed}" ]] && continue
		[[ "${trimmed}" == \#* ]] && continue
		printf '%s\n' "${trimmed}"
	done <"${file}"
}

mapfile -t combined_entries < <(
	{
		for entry in "${auto_entries[@]}"; do
			printf '%s\n' "${entry}"
		done
		read_user_entries "${USER_ALLOW}"
	} | awk '!x[$0]++' | sort
)

printf "# Combined allow list generated on %s\n" "$(date -Iseconds)" >"${RENDERED_ALLOW}"
for entry in "${combined_entries[@]}"; do
	printf "%s\n" "${entry}" >>"${RENDERED_ALLOW}"
done

echo "[network_probe] Wrote ${RENDERED_ALLOW} with ${#combined_entries[@]} entries." >&2
