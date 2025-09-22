#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
TEMPLATE="${ROOT_DIR}/.env.example"
OUTPUT="${ROOT_DIR}/.env"
FORCE=false
NON_INTERACTIVE=false

usage() {
  cat <<USAGE
Usage: ${0##*/} [--output PATH] [--force] [--non-interactive]

Copies .env.example into a new .env and walks through key configuration
choices (password secrets, resource sizing, UID/GID) to make onboarding safer.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT=$2; shift 2 ;;
    --output=*)
      OUTPUT=${1#*=}; shift ;;
    --force)
      FORCE=true; shift ;;
    --non-interactive)
      NON_INTERACTIVE=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ ! -t 0 ]]; then
  NON_INTERACTIVE=true
fi

if [[ ! -f "${TEMPLATE}" ]]; then
  echo "[create-env] ${TEMPLATE} not found; cannot generate .env." >&2
  exit 1
fi

if [[ -f "${OUTPUT}" && ${FORCE} != true ]]; then
  if [[ ${NON_INTERACTIVE} == true ]]; then
    echo "[create-env] ${OUTPUT} already exists (use --force to overwrite)." >&2
    exit 1
  fi
  read -rp "${OUTPUT} already exists. Overwrite? [y/N] " answer
  answer=${answer:-N}
  if [[ ! ${answer} =~ ^[Yy]$ ]]; then
    echo "[create-env] Aborting at user request." >&2
    exit 1
  fi
fi

cp "${TEMPLATE}" "${OUTPUT}"
chmod 0600 "${OUTPUT}"

detect_total_memory_gb() {
  local mem_kb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [[ -z ${mem_kb} || ${mem_kb} -eq 0 ]]; then
    echo 4
    return
  fi
  local mem_gb=$(( (mem_kb + 1048575) / 1048576 ))
  if (( mem_gb < 1 )); then
    mem_gb=1
  fi
  echo "${mem_gb}"
}

set_env_value() {
  local key=$1
  local value=$2
  python3 - "$OUTPUT" "$key" "$value" <<'PY'
import sys
from pathlib import Path
file_path, key, value = sys.argv[1:4]
path = Path(file_path)
lines = []
found = False
for line in path.read_text().splitlines():
    if line.startswith(f"{key}="):
        lines.append(f"{key}={value}")
        found = True
    else:
        lines.append(line)
if not found:
    lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + "\n")
PY
}

prompt_default() {
  local prompt=$1
  local default=$2
  if [[ ${NON_INTERACTIVE} == true ]]; then
    echo "${default}"
    return
  fi
  read -rp "${prompt} [${default}]: " reply
  reply=${reply:-${default}}
  echo "${reply}"
}

prompt_secret() {
  local prompt=$1
  local default_value=${2:-}
  if [[ ${NON_INTERACTIVE} == true ]]; then
    echo "${default_value}"
    return
  fi
  local secret
  while true; do
    read -rsp "${prompt}: " secret || secret=""
    echo
    if [[ -n ${secret} ]]; then
      break
    fi
    if [[ -n ${default_value} ]]; then
      secret=${default_value}
      break
    fi
    echo "Value cannot be empty." >&2
  done
  echo "${secret}"
}

# PostgreSQL superuser password is stored in secrets/postgres_superuser_password by default.
secret_dir="${ROOT_DIR}/secrets"
secret_file="${secret_dir}/postgres_superuser_password"
mkdir -p "${secret_dir}"
chmod 0700 "${secret_dir}" || true

default_password="$(openssl rand -base64 24 2>/dev/null || echo change_me)"
password="$(prompt_secret "PostgreSQL superuser password (written to secrets/postgres_superuser_password)" "${default_password}")"
printf '%s\n' "${password}" > "${secret_file}"

chmod 0600 "${secret_file}" || true
set_env_value POSTGRES_SUPERUSER_PASSWORD ""
set_env_value POSTGRES_SUPERUSER_PASSWORD_FILE "./secrets/postgres_superuser_password"

# UID/GID alignment
user_uid=$(id -u)
user_gid=$(id -g)
use_host_ids=$(prompt_default "Use current host UID/GID (${user_uid}:${user_gid}) inside the container?" "yes")
if [[ ${use_host_ids,,} == yes || ${use_host_ids,,} == y ]]; then
  set_env_value POSTGRES_UID "${user_uid}"
  set_env_value POSTGRES_GID "${user_gid}"
else
  set_env_value POSTGRES_UID "999"
  set_env_value POSTGRES_GID "999"
fi

# Resource sizing suggestions
mem_total_gb=$(detect_total_memory_gb)
if (( mem_total_gb > 12 )); then
  mem_limit_default=$((mem_total_gb - 4))
else
  mem_limit_default=$((mem_total_gb * 3 / 4))
fi
if (( mem_limit_default < 2 )); then
  mem_limit_default=2
fi
mem_limit="$(prompt_default "Memory limit for Postgres container (GB)" "${mem_limit_default}")"
if [[ ! ${mem_limit} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "[create-env] Invalid memory value '${mem_limit}', falling back to ${mem_limit_default}." >&2
  mem_limit=${mem_limit_default}
fi
set_env_value POSTGRES_MEMORY_LIMIT "${mem_limit}g"

shm_default=$(awk -v mem_limit="${mem_limit}" 'BEGIN {print mem_limit/4}')
if [[ ${shm_default} == "0" ]]; then
  shm_default=1
fi
shm_size="$(prompt_default "shared memory size (GB)" "${shm_default}")"
if [[ ! ${shm_size} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  shm_size=${shm_default}
fi
set_env_value POSTGRES_SHM_SIZE "${shm_size}g"

cpu_default=$(nproc 2>/dev/null || echo 2)
cpu_limit="$(prompt_default "CPU cores to allocate" "${cpu_default}")"
if [[ ! ${cpu_limit} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  cpu_limit=${cpu_default}
fi
set_env_value POSTGRES_CPU_LIMIT "${cpu_limit}"

# Network subnet prompt for clarity (optional change)
current_subnet=$(grep '^DOCKER_NETWORK_SUBNET=' "${OUTPUT}" | cut -d '=' -f2-)
new_subnet="$(prompt_default "Docker network subnet" "${current_subnet}")"
set_env_value DOCKER_NETWORK_SUBNET "${new_subnet}"

# Database list prompt
current_dbs=$(grep '^DATABASES_TO_CREATE=' "${OUTPUT}" | cut -d '=' -f2-)
new_dbs="$(prompt_default "Databases to create (format db:user:password,comma separated)" "${current_dbs}")"
set_env_value DATABASES_TO_CREATE "${new_dbs}"

# PgHero port prompt
current_pghero=$(grep '^PGHERO_PORT=' "${OUTPUT}" | cut -d '=' -f2-)
new_pghero="$(prompt_default "PgHero host port" "${current_pghero}")"
set_env_value PGHERO_PORT "${new_pghero}"

echo "[create-env] Wrote ${OUTPUT}. Secrets stored at ${secret_file}."
if [[ ${NON_INTERACTIVE} != true ]]; then
  echo "Review the file before starting the stack: ${OUTPUT}"
fi
