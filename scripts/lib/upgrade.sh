# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash

_update_env_var() {
  local key=$1
  local value=$2
  local file=${ENV_FILE}
  if [[ ! -f ${file} ]]; then
    echo "[core_data] Cannot update ${key}; ${file} not found." >&2
    exit 1
  fi
  python3 - "$file" "$key" "$value" <<'PY'
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

_ensure_base_image() {
  local version=$1
  local image="postgres:${version}-bookworm"
  if docker image inspect "${image}" >/dev/null 2>&1; then
    echo "${image}"
    return 0
  fi
  if docker pull "${image}" >/dev/null 2>&1; then
    echo "${image}"
    return 0
  fi
  echo "[upgrade] ERROR: postgres base image ${image} unavailable; aborting upgrade." >&2
  exit 1
}

_select_helper_image() {
  local version=$1
  local candidates=(
    "pgautoupgrade/pgautoupgrade:${version}-trixie"
    "pgautoupgrade/pgautoupgrade:${version}-alpine"
    "pgautoupgrade/pgautoupgrade:${version}"
    "pgautoupgrade/pgautoupgrade:latest"
  )
  local image=""
  for candidate in "${candidates[@]}"; do
    echo "[upgrade] probing helper image ${candidate}" >&2
    if docker image inspect "${candidate}" >/dev/null 2>&1; then
      image=${candidate}
      break
    fi
    if docker pull "${candidate}" >/dev/null 2>&1; then
      image=${candidate}
      break
    fi
  done
  if [[ -z ${image} ]]; then
    echo "[upgrade] ERROR: unable to find pgautoupgrade helper image for version ${version}" >&2
    exit 1
  fi
  echo "${image}"
}

_wait_for_postgres() {
  local retries=${1:-30}
  local delay=${2:-5}
  local attempt
  for ((attempt=1; attempt<=retries; attempt++)); do
    if compose_exec pg_isready -U "${POSTGRES_SUPERUSER:-postgres}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

cmd_upgrade() {
  ensure_env
  local new_version=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --new-version)
        new_version=$2; shift 2 ;;
      --new-version=*)
        new_version=${1#*=}; shift ;;
      -h|--help)
        cat <<USAGE >&2
Usage: ${0##*/} upgrade --new-version <version>

Performs a pg_upgrade using the pgautoupgrade helper container, updates .env,
rebuilds the custom image, and restarts the stack on the new version.
USAGE
        exit 0 ;;
      --)
        shift; break ;;
      *)
        echo "Unknown option for upgrade: $1" >&2
        exit 1 ;;
    esac
  done

  if [[ -z ${new_version} ]]; then
    echo "--new-version is required" >&2
    exit 1
  fi
  if [[ -z ${PG_VERSION:-} ]]; then
    echo "PG_VERSION not defined in environment; ensure .env is loaded." >&2
    exit 1
  fi
  if [[ ${new_version} == "${PG_VERSION}" ]]; then
    echo "Target version ${new_version} matches current PG_VERSION; nothing to do." >&2
    exit 0
  fi

  local old_version=${PG_VERSION}
  local data_dir
  data_dir=$(realpath -m "${PG_DATA_DIR}")

  echo "[upgrade] ensuring latest full backup before upgrade" >&2
  cmd_backup --type=full

  echo "[upgrade] stopping running services" >&2
  compose down

  echo "[upgrade] selecting helper image for ${new_version}" >&2
  local base_image
  base_image=$(_ensure_base_image "${new_version}")
  echo "[upgrade] confirmed base image ${base_image}" >&2

  local helper_image
  helper_image=$(_select_helper_image "${new_version}")
  echo "[upgrade] running pgautoupgrade one-shot container (${helper_image})" >&2
  docker run --rm --user 0 \
    --env POSTGRES_DB="${POSTGRES_DB:-postgres}" \
    --env PGAUTO_ONESHOT=yes \
    --env PGDATA=/var/lib/postgresql/data \
    --mount type=bind,src="${data_dir}",dst=/var/lib/postgresql/data \
    "${helper_image}" >&2

  echo "[upgrade] updating PG_VERSION in ${ENV_FILE}" >&2
  _update_env_var PG_VERSION "${new_version}"
  export PG_VERSION="${new_version}"

  echo "[upgrade] rebuilding PostgreSQL image" >&2
  compose build postgres

  echo "[upgrade] starting services on new version" >&2
  compose up -d

  echo "[upgrade] waiting for postgres healthcheck" >&2
  if ! _wait_for_postgres 40 5; then
    echo "[upgrade] ERROR: postgres did not become ready after upgrade." >&2
    exit 1
  fi

  echo "[upgrade] verifying server version" >&2
  local reported
  reported=$(compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --tuples-only --no-align --command 'SHOW server_version;')
  echo "[upgrade] server now reporting version ${reported}" >&2

  echo "[upgrade] complete" >&2
}
