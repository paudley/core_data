# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash

# Database role and schema helpers used by manage.sh.
# cmd_create_user creates a role with LOGIN privilege if it does not yet exist.
cmd_create_user() {
  ensure_env
  if [[ $# -ne 2 ]]; then
    echo "Usage: ${0##*/} create-user <user> <password>" >&2
    exit 1
  fi
  local user=$1
  local pass=$2
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${user}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${user}', '${pass}');
  END IF;
END
\$\$;
SQL
}

# cmd_drop_user removes a role when present, ignoring missing roles.
cmd_drop_user() {
  ensure_env
  if [[ $# -ne 1 ]]; then
    echo "Usage: ${0##*/} drop-user <user>" >&2
    exit 1
  fi
  local user=$1
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
DO
\$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${user}') THEN
    EXECUTE format('DROP ROLE %I', '${user}');
  END IF;
END
\$\$;
SQL
}

# cmd_create_db ensures the owner exists, creates the database, and bootstraps extensions.
cmd_create_db() {
  ensure_env
  if [[ $# -ne 2 ]]; then
    echo "Usage: ${0##*/} create-db <db> <owner>" >&2
    exit 1
  fi
  local db=$1
  local owner=$2
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${owner}') THEN
    RAISE EXCEPTION 'Role % already absent. Create it first.', '${owner}';
  END IF;
END
\$\$;
SQL
  if ! compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
        --tuples-only --no-align --command "SELECT 1 FROM pg_database WHERE datname = '${db}';" | grep -q 1; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
      --command "CREATE DATABASE \"${db}\" OWNER \"${owner}\";"
  fi
  bootstrap_database "${db}"
  schedule_pg_squeeze_job "${db}"
}

# cmd_drop_db unschedules cron jobs and drops the database after terminating sessions.
cmd_drop_db() {
  ensure_env
  if [[ $# -ne 1 ]]; then
    echo "Usage: ${0##*/} drop-db <db>" >&2
    exit 1
  fi
  local db=$1
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres \
    --command "SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'core_data_pgsqueeze_${db}';" >/dev/null
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${db}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${db}";
SQL
}
