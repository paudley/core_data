#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# pgsodium server key retrieval script.
# Called by pgsodium to obtain the root encryption key for Transparent Column Encryption.
# The key must be exactly 32 bytes (256 bits) of raw key material.

set -euo pipefail

PGSODIUM_KEY_FILE="${PGSODIUM_KEY_FILE:-/opt/core_data/secrets/pgsodium.key}"

if [[ ! -r "${PGSODIUM_KEY_FILE}" ]]; then
	echo "[core_data] ERROR: pgsodium key file not found or not readable: ${PGSODIUM_KEY_FILE}" >&2
	echo "[core_data] Generate a key with: head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \\n' > ${PGSODIUM_KEY_FILE}" >&2
	exit 1
fi

cat "${PGSODIUM_KEY_FILE}"
