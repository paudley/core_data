#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Helper routines for pg_partman integration.
set -euo pipefail

LIB_PARTMAN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${LIB_PARTMAN_DIR}/common.sh"

# partman_run_maintenance <database>
partman_run_maintenance() {
  ensure_env
  local database=${1:-${POSTGRES_DB:-postgres}}

  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${database}" \
         --set=ON_ERROR_STOP=1 <<'SQL'
SELECT n.nspname AS partman_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'pg_partman'
\gset
\if :{?partman_schema}
\echo '[partman] running run_maintenance_proc() using schema' :'partman_schema'
SELECT format('CALL %I.run_maintenance_proc();', :'partman_schema');
\gexec
\else
\echo '[partman] pg_partman extension not installed in current database; skipping.'
\endif
SQL
}

# partman_show_config <database> [parent_table]
partman_show_config() {
  ensure_env
  local database=${1:-${POSTGRES_DB:-postgres}}
  local parent_filter=${2:-}

  if [[ -n ${parent_filter} && ${parent_filter} != *.* ]]; then
    echo "[partman] parent table must be schema-qualified (e.g., schema.table)." >&2
    exit 1
  fi

  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${database}" \
         --set=ON_ERROR_STOP=1 --set=parent_filter="${parent_filter}" <<'SQL'
\pset footer off
SELECT n.nspname AS partman_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'pg_partman'
\gset
\if :{?partman_schema}
SELECT format('SET search_path TO %I, public;', :'partman_schema');
\gexec
\if :'parent_filter'
SELECT format(
  'SELECT parent_table,
          partition_type,
          partition_interval,
          premake,
          automatic_maintenance,
          COALESCE(template_table, ''<none>'') AS template_table
     FROM %I.part_config
    WHERE parent_table = %L
 ORDER BY parent_table;',
  :'partman_schema', :'parent_filter');
\gexec
\else
SELECT format(
  'SELECT parent_table,
          partition_type,
          partition_interval,
          premake,
          automatic_maintenance,
          COALESCE(template_table, ''<none>'') AS template_table
     FROM %I.part_config
 ORDER BY parent_table;',
  :'partman_schema');
\gexec
\endif
RESET search_path;
\else
\echo '[partman] pg_partman extension not installed in current database.'
\endif
SQL
}

# partman_create_parent <database> <parent_table> <control_column> <interval>
#                         <type> <start_partition> <premake> <default_table>
#                         <automatic_mode> <jobmon> <time_encoder> <time_decoder>
partman_create_parent() {
  ensure_env
  if [[ $# -ne 12 ]]; then
    echo "[partman] internal error: unexpected argument count to partman_create_parent" >&2
    exit 1
  fi

  local database=$1
  local parent_table=$2
  local control_column=$3
  local interval=$4
  local type=$5
  local start_partition=$6
  local premake=$7
  local default_table=$8
  local automatic_mode=$9
  local jobmon=${10}
  local time_encoder=${11}
  local time_decoder=${12}

  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${database}" \
         --set=ON_ERROR_STOP=1 \
         --set=parent_table="${parent_table}" \
         --set=control_column="${control_column}" \
         --set=interval="${interval}" \
         --set=partman_type="${type}" \
         --set=start_partition="${start_partition}" \
         --set=premake="${premake}" \
         --set=default_table="${default_table}" \
         --set=automatic_mode="${automatic_mode}" \
         --set=jobmon="${jobmon}" \
         --set=time_encoder="${time_encoder}" \
         --set=time_decoder="${time_decoder}" <<'SQL'
DO
$$
DECLARE
  partman_schema text;
  parent_table text := :'parent_table';
  control_column text := :'control_column';
  part_interval text := :'interval';
  part_type text := :'partman_type';
  start_partition text := NULLIF(:'start_partition', '');
  premake_input text := NULLIF(:'premake', '');
  premake_value integer;
  default_table boolean := :'default_table'::boolean;
  automatic_mode text := :'automatic_mode';
  jobmon boolean := :'jobmon'::boolean;
  time_encoder text := NULLIF(:'time_encoder', '');
  time_decoder text := NULLIF(:'time_decoder', '');
  sql text;
BEGIN
  SELECT n.nspname INTO partman_schema
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'pg_partman';

  IF partman_schema IS NULL THEN
    RAISE EXCEPTION 'pg_partman extension not installed in database %', current_database();
  END IF;

  IF parent_table IS NULL OR position('.' IN parent_table) = 0 THEN
    RAISE EXCEPTION 'Parent table must be schema-qualified (received %).', parent_table;
  END IF;

  IF premake_input IS NOT NULL THEN
    premake_value := premake_input::integer;
    IF premake_value < 0 THEN
      RAISE EXCEPTION 'premake must be >= 0 (received %).', premake_value;
    END IF;
  END IF;

  sql := format(
      'SELECT %I.create_parent(p_parent_table := %L, p_control := %L, p_interval := %L, p_type := %L',
      partman_schema, parent_table, control_column, part_interval, part_type);

  IF start_partition IS NOT NULL THEN
    sql := sql || format(', p_start_partition := %L', start_partition);
  END IF;

  IF premake_value IS NOT NULL THEN
    sql := sql || format(', p_premake := %s', premake_value);
  END IF;

  IF NOT default_table THEN
    sql := sql || ', p_default_table := false';
  END IF;

  IF automatic_mode NOT IN ('on', 'off', 'none') THEN
    RAISE EXCEPTION 'automatic maintenance mode must be on, off, or none (received %).', automatic_mode;
  END IF;
  IF automatic_mode <> 'on' THEN
    sql := sql || format(', p_automatic_maintenance := %L', automatic_mode);
  END IF;

  IF NOT jobmon THEN
    sql := sql || ', p_jobmon := false';
  END IF;

  IF time_encoder IS NOT NULL THEN
    sql := sql || format(', p_time_encoder := %L', time_encoder);
  END IF;

  IF time_decoder IS NOT NULL THEN
    sql := sql || format(', p_time_decoder := %L', time_decoder);
  END IF;

  sql := sql || ');';

  RAISE NOTICE '[partman] %', sql;
  EXECUTE sql;
END;
$$;
SQL
}
