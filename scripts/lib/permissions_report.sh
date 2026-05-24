#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
set -euo pipefail

PERMISSIONS_REPORT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${PERMISSIONS_REPORT_LIB_DIR}/common.sh"

# generate_permission_report generates a CSV report of permissions by schema/role.
# Includes permission tier classification for each schema.
# Usage: generate_permission_report <db> [output_path]
generate_permission_report() {
  local db=$1
  local output=${2:-}

  # Build tier lists dynamically from the arrays to avoid duplication.
  local tier1_list tier2_list tier3_list tier4_list
  tier1_list=$(printf "'%s'," "${TIER1_FULL_ACCESS_SCHEMAS[@]}" | sed 's/,$//')
  tier2_list=$(printf "'%s'," "${TIER2_READWRITE_SCHEMAS[@]}" | sed 's/,$//')
  tier3_list=$(printf "'%s'," "${TIER3_READONLY_SCHEMAS[@]}" | sed 's/,$//')
  tier4_list=$(printf "'%s'," "${TIER4_FUNCTION_ONLY_SCHEMAS[@]}" | sed 's/,$//')

  local sql="
SELECT
    n.nspname AS schema_name,
    CASE
        WHEN n.nspname IN (${tier1_list}) THEN 'Tier 1 (Full)'
        WHEN n.nspname IN (${tier2_list}) THEN 'Tier 2 (Read-Write)'
        WHEN n.nspname IN (${tier3_list}) THEN 'Tier 3 (Read-Only)'
        WHEN n.nspname IN (${tier4_list}) THEN 'Tier 4 (Functions)'
        ELSE 'Unmanaged'
    END AS permission_tier,
    r.rolname AS role_name,
    CASE WHEN has_schema_privilege(r.oid, n.oid, 'USAGE') THEN 'Y' ELSE 'N' END AS schema_usage,
    CASE WHEN has_schema_privilege(r.oid, n.oid, 'CREATE') THEN 'Y' ELSE 'N' END AS schema_create,
    (SELECT COUNT(*) FROM pg_class c
     WHERE c.relnamespace = n.oid
     AND c.relkind = 'r'
     AND has_table_privilege(r.oid, c.oid, 'SELECT')) AS tables_select,
    (SELECT COUNT(*) FROM pg_class c
     WHERE c.relnamespace = n.oid
     AND c.relkind = 'r'
     AND has_table_privilege(r.oid, c.oid, 'INSERT')) AS tables_insert,
    (SELECT COUNT(*) FROM pg_class c
     JOIN pg_sequence s ON s.seqrelid = c.oid
     WHERE c.relnamespace = n.oid
     AND has_sequence_privilege(r.oid, c.oid, 'USAGE')) AS sequences_usage,
    (SELECT COUNT(*) FROM pg_proc p
     WHERE p.pronamespace = n.oid
     AND has_function_privilege(r.oid, p.oid, 'EXECUTE')) AS functions_execute
FROM pg_namespace n
CROSS JOIN pg_roles r
WHERE n.nspname NOT LIKE 'pg_%'
AND n.nspname <> 'information_schema'
AND r.rolname NOT LIKE 'pg_%'
AND r.rolcanlogin = true
ORDER BY n.nspname, r.rolname;
"

  if [[ -n "${output}" ]]; then
    if [[ -n "${POSTGRES_EXEC_MODE:-}" && "${POSTGRES_EXEC_MODE}" == "container" ]]; then
      psql --csv --username "${POSTGRES_USER:-postgres}" --dbname "${db}" --command "${sql}" > "${output}"
    else
      compose_exec env PGHOST="${POSTGRES_HOST:-localhost}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
        psql --csv --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" --command "${sql}" > "${output}"
    fi
    _permissions_log "Permission report written to ${output}"
  else
    if [[ -n "${POSTGRES_EXEC_MODE:-}" && "${POSTGRES_EXEC_MODE}" == "container" ]]; then
      psql --username "${POSTGRES_USER:-postgres}" --dbname "${db}" --command "${sql}"
    else
      compose_exec env PGHOST="${POSTGRES_HOST:-localhost}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
        psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" --command "${sql}"
    fi
  fi
}
