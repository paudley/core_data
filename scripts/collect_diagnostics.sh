#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

output_dir="diagnostics"
logs_tail=${CORE_DATA_DIAG_LOG_TAIL:-400}

usage() {
	cat <<'USAGE'
Usage: collect_diagnostics.sh [--output DIR]

Gather docker/container state, sanitized env vars, and service logs to help debug CI failures.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--output)
		output_dir=$2
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "[diagnostics] Unknown argument: $1" >&2
		exit 1
		;;
	esac
done

mkdir -p "${output_dir}"
timestamp=$(date -Iseconds)

run_cmd() {
	local name=$1
	shift
	if command -v "$1" >/dev/null 2>&1; then
		"$@" >"${output_dir}/${name}.txt" 2>&1 || true
	fi
}

run_cmd "docker-ps" docker ps -a
run_cmd "docker-compose-ls" docker compose ls
run_cmd "docker-network-ls" docker network ls

sanitize_env() {
	local source_env=$1
	local dest=$2
	if [[ ! -f "${source_env}" ]]; then
		return
	fi
	python3 - "$source_env" "$dest" <<'PY'
import os
import re
import sys
source, dest = sys.argv[1], sys.argv[2]
pattern = re.compile(r"(PASSWORD|SECRET|TOKEN|KEY|COOKIE)", re.IGNORECASE)
with open(source, "r", encoding="utf-8") as fh, open(dest, "w", encoding="utf-8") as out:
    for line in fh:
        if "=" in line and not line.lstrip().startswith("#"):
            key, val = line.rstrip("\n").split("=", 1)
            if pattern.search(key):
                line = f"{key}=<redacted>\n"
        out.write(line)
PY
}

sanitize_env "${ENV_FILE:-${PWD}/.env}" "${output_dir}/env.redacted"

collect_container_artifacts() {
	local container=$1
	local safe_name=${container//\//_}
	docker inspect "${container}" >"${output_dir}/${safe_name}--inspect.json" 2>/dev/null || true
	docker logs --tail "${logs_tail}" "${container}" >"${output_dir}/${safe_name}--logs.txt" 2>&1 || true
}

containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E 'core_data|postgres' || true)
for name in ${containers}; do
	collect_container_artifacts "${name}"
done

echo "[diagnostics] Wrote troubleshooting bundle to ${output_dir} (${timestamp})."
