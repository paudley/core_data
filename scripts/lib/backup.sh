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
  if [[ $# -ge 1 ]]; then
    case $1 in
      --type=full) backup_type="full" ;;
      --type=diff) backup_type="diff" ;;
      --type=incr) backup_type="incr" ;;
      *) echo "Unknown backup type '$1'" >&2; exit 1 ;;
    esac
  fi
  local cmd=(pgbackrest --config="${PGBACKREST_CONF}" --stanza=main --log-level-console=info)
  if [[ ${backup_type} != "auto" ]]; then
    cmd+=("--type=${backup_type}")
  fi
  cmd+=(backup)
  compose_exec env -u PGBACKREST_REPO_DIR PGHOST="${POSTGRES_HOST}" \
    PGUSER="${POSTGRES_SUPERUSER:-postgres}" \
    PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    "${cmd[@]}"
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
