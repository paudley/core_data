#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

if [[ -z "${DATABASES_TO_CREATE:-}" ]]; then
  echo "[core_data] DATABASES_TO_CREATE not defined; skipping additional database provisioning." >&2
  exit 0
fi

IFS=',' read -r -a entries <<< "${DATABASES_TO_CREATE}"
for entry in "${entries[@]}"; do
  IFS=':' read -r db_name db_user db_password <<< "${entry}"
  if [[ -z "${db_name}" || -z "${db_user}" || -z "${db_password}" ]]; then
    echo "[core_data] Skipping malformed entry '${entry}'. Expected format db:user:password" >&2
    continue
  fi

  echo "[core_data] Creating role '${db_user}' and database '${db_name}'." >&2
  psql --set ON_ERROR_STOP=on \
       --username "${POSTGRES_USER}" \
       --dbname "${POSTGRES_DB}" <<SQL
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', '${db_user}', '${db_password}')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${db_user}');
\gexec

SELECT format('CREATE DATABASE %I OWNER %I', '${db_name}', '${db_user}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${db_name}');
\gexec
SQL

done

if [[ -n "${PGBOUNCER_AUTH_USER:-}" ]]; then
  if [[ -r /run/secrets/pgbouncer_auth_password ]]; then
    pgbouncer_auth_password=$(</run/secrets/pgbouncer_auth_password)
    echo "[core_data] Ensuring PgBouncer auth user '${PGBOUNCER_AUTH_USER}' exists." >&2
    psql --set ON_ERROR_STOP=on \
         --username "${POSTGRES_USER}" \
         --dbname "${POSTGRES_DB}" <<SQL
SELECT format('CREATE ROLE %I WITH SUPERUSER LOGIN PASSWORD %L', '${PGBOUNCER_AUTH_USER}', '${pgbouncer_auth_password}')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PGBOUNCER_AUTH_USER}');
\gexec
SQL
  else
    echo "[core_data] WARNING: /run/secrets/pgbouncer_auth_password not readable; skipping PgBouncer auth user." >&2
  fi
fi

if [[ -n "${PGBOUNCER_STATS_USER:-}" ]]; then
  if [[ -r /run/secrets/pgbouncer_stats_password ]]; then
    pgbouncer_stats_password=$(</run/secrets/pgbouncer_stats_password)
    echo "[core_data] Ensuring PgBouncer stats user '${PGBOUNCER_STATS_USER}' exists." >&2
    psql --set ON_ERROR_STOP=on \
         --username "${POSTGRES_USER}" \
         --dbname "${POSTGRES_DB}" <<SQL
SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', '${PGBOUNCER_STATS_USER}', '${pgbouncer_stats_password}')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PGBOUNCER_STATS_USER}');
\gexec
SQL
  else
    echo "[core_data] WARNING: /run/secrets/pgbouncer_stats_password not readable; skipping PgBouncer stats user." >&2
  fi
fi
