# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash

# pgBackRest and logical backup helpers used by manage.sh.
# cmd_dump writes a custom-format pg_dump archive compressed with gzip.
cmd_dump() {
  ensure_env
  if [[ $# -lt 1 ]]; then
    echo "Usage: ${0##*/} dump <db> [output_file]" >&2
    exit 1
  fi
  local db=$1
  local outfile=${2:-"/backups/${db}-$(date +%Y%m%d%H%M%S).sql.gz"}
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    bash -lc "pg_dump --format=custom --no-owner --no-acl --dbname='${db}' --username='${POSTGRES_SUPERUSER:-postgres}' | gzip > '${outfile}'"
  echo "Dump written to ${outfile}" >&2
}

# cmd_dump_sql produces a plain-text pg_dump suitable for review or editing.
cmd_dump_sql() {
  ensure_env
  if [[ $# -lt 1 ]]; then
    echo "Usage: ${0##*/} dump-sql <db> [output_file]" >&2
    exit 1
  fi
  local db=$1
  local outfile=${2:-"/backups/${db}-$(date +%Y%m%d%H%M%S).sql"}
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    bash -lc "pg_dump --format=plain --create --clean --if-exists --no-owner --no-acl --dbname='${db}' --username='${POSTGRES_SUPERUSER:-postgres}' > '${outfile}'"
  echo "Plain SQL dump written to ${outfile}" >&2
}

# cmd_restore_dump recreates the database and restores a gzip-compressed custom dump.
cmd_restore_dump() {
  ensure_env
  if [[ $# -ne 2 ]]; then
    echo "Usage: ${0##*/} restore-dump <input_file> <db>" >&2
    exit 1
  fi
  local infile=$1
  local db=$2
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${db}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${db}";
CREATE DATABASE "${db}" OWNER "${POSTGRES_SUPERUSER:-postgres}";
SQL
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    bash -lc "gunzip -c '${infile}' | pg_restore --dbname='${db}' --username='${POSTGRES_SUPERUSER:-postgres}'"
}

# cmd_backup wraps pgBackRest backup with optional type selection (full/diff/incr).
cmd_backup() {
  ensure_env
  local backup_type="auto"
  local verify=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)
        backup_type=$2; shift 2 ;;
      --type=*)
        backup_type=${1#*=}; shift ;;
      --verify)
        verify=true; shift ;;
      --help|-h)
        cat <<USAGE >&2
Usage: ${0##*/} backup [--type=full|diff|incr] [--verify]
USAGE
        exit 0 ;;
      --)
        shift; break ;;
      *)
        echo "Unknown option for backup: $1" >&2
        exit 1 ;;
    esac
  done
  case "${backup_type}" in
    auto|full|diff|incr) ;;
    *)
      echo "Unknown backup type '${backup_type}'" >&2
      exit 1
      ;;
  esac
  local cmd=(pgbackrest --config="${PGBACKREST_CONF}" --stanza=main --log-level-console=info)
  if [[ ${backup_type} != "auto" ]]; then
    cmd+=("--type=${backup_type}")
  fi
  cmd+=(backup)
  compose_exec env -u PGBACKREST_REPO_DIR PGHOST="${POSTGRES_HOST}" \
    PGUSER="${POSTGRES_SUPERUSER:-postgres}" \
    PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    "${cmd[@]}"
  if [[ ${verify} == true ]]; then
    verify_latest_backup
  fi
}

verify_latest_backup() {
  ensure_env
  local project_name
  project_name=${COMPOSE_PROJECT_NAME:-$(basename "${ROOT_DIR}")}

  local repo_mount
  if [[ -n ${CORE_DATA_PGBACKREST_REPO_DIR:-} ]]; then
    local repo_dir
    repo_dir=$(realpath -m "${CORE_DATA_PGBACKREST_REPO_DIR}")
    if [[ ! -d ${repo_dir} ]]; then
      echo "[backup] pgBackRest repository ${repo_dir} not found; skipping verification." >&2
      return 1
    fi
    repo_mount=(--mount "type=bind,src=${repo_dir},dst=/var/lib/pgbackrest:ro")
  else
    repo_mount=(--mount "type=volume,src=${project_name}_pgbackrest,dst=/var/lib/pgbackrest:ro")
  fi
  local restore_dir
  restore_dir=$(mktemp -d)
  local config_dir
  config_dir=$(mktemp -d)
  chmod 0777 "${restore_dir}" "${config_dir}"
  local config_file="${config_dir}/pgbackrest.conf"
  if ! compose_exec cat "${PGBACKREST_CONF}" >"${config_file}"; then
    echo "[backup] Unable to fetch pgBackRest configuration from container." >&2
    rm -rf "${restore_dir}" "${config_dir}"
    return 1
  fi
  local image="${POSTGRES_IMAGE_NAME:-core_data/postgres}:${POSTGRES_IMAGE_TAG:-latest}"
  echo "[backup] Verifying latest backup via restore and checksum validation." >&2
  if ! docker run --rm --user postgres \
      "${repo_mount[@]}" \
      -v "${restore_dir}:/var/lib/postgresql/data" \
      -v "${config_dir}:/etc/pgbackrest:ro" \
      "${image}" \
      bash -lc "set -euo pipefail; pgbackrest --config=/etc/pgbackrest/pgbackrest.conf --stanza=main --delta --target=name=latest restore; pg_verify_checksums -D /var/lib/postgresql/data >/dev/null"; then
    echo "[backup] Backup verification failed." >&2
    rm -rf "${restore_dir}" "${config_dir}"
    return 1
  fi
  echo "[backup] Latest backup restored and checksums verified." >&2
  rm -rf "${restore_dir}" "${config_dir}"
  return 0
}

# cmd_stanza_create initializes the pgBackRest stanza inside the container.
cmd_stanza_create() {
  ensure_env
  compose_exec env -u PGBACKREST_REPO_DIR PGHOST="${POSTGRES_HOST}" \
    PGUSER="${POSTGRES_SUPERUSER:-postgres}" \
    PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    pgbackrest --config="${PGBACKREST_CONF}" --stanza=main stanza-create
}

# cmd_restore_snapshot proxies pgBackRest restore with arbitrary arguments.
cmd_restore_snapshot() {
  ensure_env
  compose_exec env -u PGBACKREST_REPO_DIR PGHOST="${POSTGRES_HOST}" \
    PGUSER="${POSTGRES_SUPERUSER:-postgres}" \
    PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    pgbackrest --config="${PGBACKREST_CONF}" --stanza=main --log-level-console=info restore "$@"
}

# cmd_provision_qa captures a diff backup and restores a specific database for QA.
cmd_provision_qa() {
  ensure_env
  if [[ $# -ne 1 ]]; then
    echo "Usage: ${0##*/} provision-qa <dbname>" >&2
    exit 1
  fi
  local target=$1
  compose_exec env -u PGBACKREST_REPO_DIR PGHOST="${POSTGRES_HOST}" \
    PGUSER="${POSTGRES_SUPERUSER:-postgres}" \
    PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    bash -lc "pgbackrest --config='${PGBACKREST_CONF}' --stanza=main --type=diff backup"
  compose_exec env -u PGBACKREST_REPO_DIR PGHOST="${POSTGRES_HOST}" \
    PGUSER="${POSTGRES_SUPERUSER:-postgres}" \
    PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    bash -lc "pgbackrest --config='${PGBACKREST_CONF}' --stanza=main --delta --target=name=latest --db-include='${target}' restore"
}
