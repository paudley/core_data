#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Network guard: restricts access to core_data service ports using nftables.
# Reads an allow-list of CIDR networks and applies rules to the DOCKER-USER
# chain so only listed networks can reach the exposed service ports.

set -euo pipefail

NETWORK_DIR=${NETWORK_DIR:-/opt/core_data/network_access}
ALLOW_FILE=${ALLOW_FILE:-${NETWORK_DIR}/allow.list}
CHECK_INTERVAL=${CHECK_INTERVAL:-30}
NETWORK_GUARD_REQUIRED=${NETWORK_GUARD_REQUIRED:-false}
SERVICES=${SERVICES:-"5432 5433 5672 6379 6432 8080 11211 15672"}
CHAIN_V4=${CHAIN_V4:-CORE_DATA_ALLOW_V4}
CHAIN_V6=${CHAIN_V6:-CORE_DATA_ALLOW_V6}
RULE_COMMENT="core-data-allow"

log() {
	printf '[network_guard] %s\n' "$1" >&2
}

# Verify nft is available and the kernel supports it
verify_nft() {
	if ! command -v nft >/dev/null 2>&1; then
		if [[ "${NETWORK_GUARD_REQUIRED}" == "true" ]]; then
			log "ERROR: nft command not found"
			exit 1
		fi
		log "WARNING: nft command not found; network guard is disabled. Set NETWORK_GUARD_REQUIRED=true to fail closed."
		while true; do
			sleep "${CHECK_INTERVAL}"
		done
	fi
	if ! nft list tables >/dev/null 2>&1; then
		if [[ "${NETWORK_GUARD_REQUIRED}" == "true" ]]; then
			log "ERROR: nftables not available (check kernel support and NET_ADMIN capability)"
			exit 1
		fi
		log "WARNING: nftables not available; network guard is disabled. Set NETWORK_GUARD_REQUIRED=true to fail closed."
		while true; do
			sleep "${CHECK_INTERVAL}"
		done
	fi
}

# Ensure the DOCKER-USER chain exists in the given family's filter table.
# Docker creates this chain, but we verify before inserting rules.
ensure_docker_user_chain() {
	local family=$1
	if ! nft list chain "${family}" filter DOCKER-USER >/dev/null 2>&1; then
		log "WARNING: DOCKER-USER chain not found in ${family} filter table; creating it"
		nft add table "${family}" filter 2>/dev/null || true
		nft add chain "${family}" filter DOCKER-USER 2>/dev/null || return 1
	fi
	return 0
}

# Create or flush our custom allow chain in the given family's filter table.
create_chain() {
	local family=$1
	local chain=$2
	if nft list chain "${family}" filter "${chain}" >/dev/null 2>&1; then
		nft flush chain "${family}" filter "${chain}"
	else
		nft add chain "${family}" filter "${chain}"
	fi
	# Allow established/related connections through
	nft add rule "${family}" filter "${chain}" ct state established,related return
}

# Add allowed network CIDRs to the chain, then drop everything else.
add_network_rules() {
	local family=$1
	local chain=$2
	local addr_selector=$3
	shift 3
	local networks=("$@")
	for net in "${networks[@]}"; do
		nft add rule "${family}" filter "${chain}" "${addr_selector}" saddr "${net}" return
	done
	nft add rule "${family}" filter "${chain}" drop
}

# Remove existing jump rules from DOCKER-USER that reference our chain.
remove_existing_rules() {
	local family=$1
	local chain=$2
	shift 2
	local ports=("$@")
	for port in "${ports[@]}"; do
		# Find and delete rules that jump to our chain for this port
		local handles
		handles=$(nft -a list chain "${family}" filter DOCKER-USER 2>/dev/null \
			| grep "tcp dport ${port}.*jump ${chain}" \
			| sed -n 's/.*# handle \([0-9]*\)/\1/p') || true
		for handle in ${handles}; do
			nft delete rule "${family}" filter DOCKER-USER handle "${handle}" 2>/dev/null || true
		done
	done
}

# Insert jump rules at the top of DOCKER-USER for each service port.
insert_rules() {
	local family=$1
	local chain=$2
	shift 2
	local ports=("$@")
	for port in "${ports[@]}"; do
		nft insert rule "${family}" filter DOCKER-USER tcp dport "${port}" jump "${chain}" comment \"${RULE_COMMENT}\"
	done
}

read_allow_file() {
	local file=$1
	if [[ ! -f "${file}" ]]; then
		log "Waiting for ${file}..."
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

# Check if IPv6 filter table is usable
has_ipv6=false
check_ipv6() {
	if nft list tables ip6 >/dev/null 2>&1; then
		has_ipv6=true
	else
		log "WARNING: IPv6 nftables not available; skipping IPv6 enforcement."
	fi
}

verify_nft
check_ipv6

last_hash=""
while true; do
	if [[ -f "${ALLOW_FILE}" ]]; then
		current_hash=$(sha256sum "${ALLOW_FILE}" | awk '{print $1}')
		if [[ "${current_hash}" != "${last_hash}" ]]; then
			if read_allow_file "${ALLOW_FILE}"; then
				# Ensure DOCKER-USER exists
				if ! ensure_docker_user_chain ip; then
					log "ERROR: Cannot ensure DOCKER-USER chain in ip filter"
					sleep "${CHECK_INTERVAL}"
					continue
				fi

				# Build port list
				read -ra port_array <<<"${SERVICES}"
				ports=()
				for port in "${port_array[@]}"; do
					[[ -z "${port}" ]] && continue
					ports+=("${port}")
				done

				# IPv4 rules
				create_chain ip "${CHAIN_V4}"
				if [[ ${#ipv4[@]} -gt 0 ]]; then
					add_network_rules ip "${CHAIN_V4}" "ip" "${ipv4[@]}"
				else
					# No IPv4 networks allowed — drop all
					nft add rule ip filter "${CHAIN_V4}" drop
				fi
				if [[ ${#ports[@]} -gt 0 ]]; then
					remove_existing_rules ip "${CHAIN_V4}" "${ports[@]}"
					insert_rules ip "${CHAIN_V4}" "${ports[@]}"
				fi

				# IPv6 rules
				if [[ "${has_ipv6}" == true ]]; then
					if ensure_docker_user_chain ip6; then
						create_chain ip6 "${CHAIN_V6}"
						if [[ ${#ipv6[@]} -gt 0 ]]; then
							add_network_rules ip6 "${CHAIN_V6}" "ip6" "${ipv6[@]}"
						else
							nft add rule ip6 filter "${CHAIN_V6}" drop
						fi
						if [[ ${#ports[@]} -gt 0 ]]; then
							remove_existing_rules ip6 "${CHAIN_V6}" "${ports[@]}"
							insert_rules ip6 "${CHAIN_V6}" "${ports[@]}"
						fi
					else
						log "WARNING: Failed to manage IPv6 rules; disabling IPv6 enforcement."
						has_ipv6=false
					fi
				fi

				last_hash="${current_hash}"
				log "Applied nftables rules for ${ALLOW_FILE}"
			fi
		fi
	fi
	sleep "${CHECK_INTERVAL}"
done
