#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash

# Comprehensive PostgreSQL permission management for database owners.
# Covers all extension schemas, custom types, sequences, functions, and search_path.

# Tiered permission schema classification
# Tier 1: Full access (USAGE + CREATE + Full CRUD + Default Privileges)
# These schemas need CREATE for users to create objects (AGE graphs, partitions, etc.)
TIER1_FULL_ACCESS_SCHEMAS=(
	"public"             # Default user schema, extension types
	"ag_catalog"         # Apache AGE - stores graphs as tables here
	"partman"            # pg_partman - partition config tables
	"topology"           # PostGIS - CreateTopology creates schemas/tables
)

# Tier 2: Read-Write (USAGE + CRUD, no CREATE)
# Users can manipulate data but not create new objects
TIER2_READWRITE_SCHEMAS=(
	"cron"               # pg_cron - job scheduling writes to cron tables
)

# Tier 3: Read-Only (USAGE + SELECT only)
# Reference data schemas - users query but don't modify
TIER3_READONLY_SCHEMAS=(
	"tiger"              # PostGIS tiger geocoder reference data
	"tiger_data"         # PostGIS tiger geocoder reference data
	"address_standardizer"
	"address_standardizer_data_us"
	"squeeze"            # pg_squeeze - system-managed bloat tracking
)

# Tier 4: Function-Only (USAGE + EXECUTE)
# Admin schemas - users only call functions, no table access
TIER4_FUNCTION_ONLY_SCHEMAS=(
	"core_data_admin"    # Project admin schema
)

# Combined list for backward compatibility and iteration
ALL_EXTENSION_SCHEMAS=(
	"${TIER1_FULL_ACCESS_SCHEMAS[@]}"
	"${TIER2_READWRITE_SCHEMAS[@]}"
	"${TIER3_READONLY_SCHEMAS[@]}"
	"${TIER4_FUNCTION_ONLY_SCHEMAS[@]}"
)

# Custom types requiring USAGE grants
CUSTOM_TYPES=(
	"ag_catalog.agtype"
	"ag_catalog.graphid"
	"public.geometry"
	"public.geography"
	"public.box2d"
	"public.box3d"
	"public.vector"
	"topology.topogeometry"
)

# Default search_path for database owners
DEFAULT_SEARCH_PATH="public, ag_catalog, topology, tiger"

# _psql_quote_literal escapes a string for use as a literal in a PostgreSQL query.
# This prevents SQL injection by properly escaping single quotes.
_psql_quote_literal() {
	printf "'%s'" "${1//\'/\'\'}"
}

# _parse_db_argument parses --db arguments from command line for permission commands.
# Sets PARSED_DB variable with the database name, or empty if not provided.
# Usage: _parse_db_argument "$@"; db="${PARSED_DB}"
# Returns: Sets PARSED_DB and PARSED_SHIFT variables (exported for caller use)
# shellcheck disable=SC2034  # PARSED_DB and PARSED_SHIFT are used by callers
_parse_db_argument() {
	PARSED_DB=""
	PARSED_SHIFT=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--db)
			PARSED_DB=$2
			shift 2
			PARSED_SHIFT=$((PARSED_SHIFT + 2))
			;;
		--db=*)
			PARSED_DB=${1#*=}
			shift
			PARSED_SHIFT=$((PARSED_SHIFT + 1))
			;;
		--)
			shift
			PARSED_SHIFT=$((PARSED_SHIFT + 1))
			break
			;;
		*)
			# Unknown option - let caller handle
			break
			;;
		esac
	done
}

# _permissions_log outputs a timestamped log message to stderr.
_permissions_log() {
	echo "[core_data:permissions] $*" >&2
}

# _run_psql executes SQL against a database using the superuser credentials.
# Usage: _run_psql <db> [sql] or _run_psql <db> <<< "sql" or _run_psql <db> <<HEREDOC
_run_psql() {
	local db=$1
	local sql=${2:-}
	if [[ -n "${POSTGRES_EXEC_MODE:-}" && "${POSTGRES_EXEC_MODE}" == "container" ]]; then
		# Running inside container (init scripts)
		if [[ -n "${sql}" ]]; then
			psql --set ON_ERROR_STOP=0 --username "${POSTGRES_USER:-postgres}" --dbname "${db}" <<< "${sql}"
		else
			psql --set ON_ERROR_STOP=0 --username "${POSTGRES_USER:-postgres}" --dbname "${db}"
		fi
	else
		# Running via compose_exec (manage.sh)
		if [[ -n "${sql}" ]]; then
			compose_exec env PGHOST="${POSTGRES_HOST:-localhost}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
				psql --set ON_ERROR_STOP=0 --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" <<< "${sql}"
		else
			compose_exec env PGHOST="${POSTGRES_HOST:-localhost}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
				psql --set ON_ERROR_STOP=0 --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}"
		fi
	fi
}

# _run_psql_query executes a query and returns the result.
# Usage: _run_psql_query <db> <sql>
_run_psql_query() {
	local db=$1
	local sql=$2
	if [[ -n "${POSTGRES_EXEC_MODE:-}" && "${POSTGRES_EXEC_MODE}" == "container" ]]; then
		psql --tuples-only --no-align --username "${POSTGRES_USER:-postgres}" --dbname "${db}" --command "${sql}" 2>/dev/null
	else
		compose_exec env PGHOST="${POSTGRES_HOST:-localhost}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
			psql --tuples-only --no-align --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" --command "${sql}" 2>/dev/null
	fi
}

# grant_schema_permissions grants tiered permissions on a schema to a role.
# Tier 1: USAGE + CREATE + Full CRUD + MAINTAIN + Default Privileges (for owner too)
# Tier 2: USAGE + CRUD (no CREATE, no defaults)
# Tier 3: USAGE + SELECT only (read-only reference data)
# Tier 4: USAGE + EXECUTE only (function access, no table access)
# Usage: grant_schema_permissions <db> <schema> <role> [tier]
grant_schema_permissions() {
	local db=$1
	local schema=$2
	local role=$3
	local tier=${4:-1}
	local grantor=${POSTGRES_SUPERUSER:-postgres}

	_run_psql "${db}" <<SQL
DO \$perm\$
DECLARE
  pg_version integer;
BEGIN
  pg_version := current_setting('server_version_num')::int;

  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = '${schema}') THEN
    RETURN;
  END IF;

  -- Schema access (CREATE only for tier 1)
  IF ${tier} = 1 THEN
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', '${schema}', '${role}');
  ELSE
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', '${schema}', '${role}');
  END IF;

  -- Tables (tier-dependent)
  IF ${tier} IN (1, 2) THEN
    -- Full CRUD for tiers 1-2
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA %I TO %I', '${schema}', '${role}');
  ELSIF ${tier} = 3 THEN
    -- Read-only for tier 3
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', '${schema}', '${role}');
  END IF;
  -- Tier 4: no table access

  -- MAINTAIN privilege (PostgreSQL 15+, tiers 1-2 only)
  IF pg_version >= 150000 AND ${tier} IN (1, 2) THEN
    EXECUTE format('GRANT MAINTAIN ON ALL TABLES IN SCHEMA %I TO %I', '${schema}', '${role}');
  END IF;

  -- Sequences (tier-dependent)
  IF ${tier} = 1 THEN
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I TO %I', '${schema}', '${role}');
  ELSIF ${tier} IN (2, 3) THEN
    EXECUTE format('GRANT SELECT, USAGE ON ALL SEQUENCES IN SCHEMA %I TO %I', '${schema}', '${role}');
  END IF;
  -- Tier 4: no sequence access

  -- Functions and Routines (all tiers)
  EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', '${schema}', '${role}');
  -- Routines includes procedures (PostgreSQL 11+)
  IF pg_version >= 110000 THEN
    BEGIN
      EXECUTE format('GRANT EXECUTE ON ALL ROUTINES IN SCHEMA %I TO %I', '${schema}', '${role}');
    EXCEPTION WHEN undefined_object THEN
      NULL; -- Ignore if no routines exist
    END;
  END IF;

  -- Default privileges (tier 1 only - for both superuser and owner)
  IF ${tier} = 1 THEN
    -- For objects created by superuser
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I',
        '${grantor}', '${schema}', '${role}');
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT ALL PRIVILEGES ON SEQUENCES TO %I',
        '${grantor}', '${schema}', '${role}');
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO %I',
        '${grantor}', '${schema}', '${role}');

    -- MAINTAIN default privileges (PostgreSQL 15+)
    IF pg_version >= 150000 THEN
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT MAINTAIN ON TABLES TO %I',
          '${grantor}', '${schema}', '${role}');
    END IF;

    -- For objects created by owner (so they can access their own future objects)
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I',
        '${role}', '${schema}', '${role}');
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT ALL PRIVILEGES ON SEQUENCES TO %I',
        '${role}', '${schema}', '${role}');
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT EXECUTE ON FUNCTIONS TO %I',
        '${role}', '${schema}', '${role}');
  END IF;

  RAISE NOTICE 'Granted tier % permissions on schema % to %', ${tier}, quote_ident('${schema}'), quote_ident('${role}');
END;
\$perm\$;
SQL
}

# grant_type_permissions grants USAGE on custom types to a role.
# Usage: grant_type_permissions <db> <role>
grant_type_permissions() {
	local db=$1
	local role=$2

	for type_fqn in "${CUSTOM_TYPES[@]}"; do
		local schema=${type_fqn%%.*}
		local type_name=${type_fqn##*.}

		_run_psql "${db}" <<SQL
DO \$type_perm\$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON t.typnamespace = n.oid
    WHERE n.nspname = '${schema}' AND t.typname = '${type_name}'
  ) THEN
    EXECUTE format('GRANT USAGE ON TYPE %I.%I TO %I', '${schema}', '${type_name}', '${role}');
    RAISE NOTICE 'Granted USAGE on type %.% to %', quote_ident('${schema}'), quote_ident('${type_name}'), quote_ident('${role}');
  END IF;
END;
\$type_perm\$;
SQL
	done
}

# grant_large_object_permissions grants SELECT/UPDATE on large objects to a role.
# Also sets default privileges for future large objects created by the grantor.
# Usage: grant_large_object_permissions <db> <role>
grant_large_object_permissions() {
	local db=$1
	local role=$2
	local grantor=${POSTGRES_SUPERUSER:-postgres}

	_run_psql "${db}" <<SQL
DO \$lo\$
DECLARE
  loid oid;
  lo_count integer := 0;
BEGIN
  -- Grant on existing large objects
  FOR loid IN SELECT oid FROM pg_largeobject_metadata LOOP
    EXECUTE format('GRANT SELECT, UPDATE ON LARGE OBJECT %s TO %I', loid, '${role}');
    lo_count := lo_count + 1;
  END LOOP;

  -- Default privileges for future large objects created by superuser
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I GRANT SELECT, UPDATE ON LARGE OBJECTS TO %I',
      '${grantor}', '${role}');

  IF lo_count > 0 THEN
    RAISE NOTICE 'Granted permissions on % large objects to %', lo_count, quote_ident('${role}');
  END IF;
  RAISE NOTICE 'Set default large object privileges for % on objects created by %', quote_ident('${role}'), quote_ident('${grantor}');
END;
\$lo\$;
SQL
}

# set_role_search_path configures the search_path for a role in a database.
# Uses DEFAULT_SEARCH_PATH to ensure consistent, safe configuration.
# Usage: set_role_search_path <db> <role>
set_role_search_path() {
	local db=$1
	local role=$2
	local search_path=${DEFAULT_SEARCH_PATH}

	_run_psql "${db}" <<SQL
ALTER ROLE "${role}" IN DATABASE "${db}" SET search_path TO ${search_path};
SQL
	_permissions_log "Set search_path for '${role}' in '${db}' to: ${search_path}"
}

# apply_complete_permissions applies comprehensive tiered permissions for a database owner.
# This is the main entry point for granting all permissions to a db owner.
# Grants: Database privileges, tiered schema permissions, types, large objects, search_path.
# Usage: apply_complete_permissions <db> <owner>
apply_complete_permissions() {
	local db=$1
	local owner=$2

	_permissions_log "Applying complete permissions for '${owner}' in database '${db}'."

	# 1. Database-level privileges (includes TEMPORARY)
	_run_psql "${db}" <<SQL
GRANT ALL PRIVILEGES ON DATABASE "${db}" TO "${owner}";
SQL

	# 2. Tier 1: Full access schemas (USAGE + CREATE + Full CRUD + Defaults)
	for schema in "${TIER1_FULL_ACCESS_SCHEMAS[@]}"; do
		grant_schema_permissions "${db}" "${schema}" "${owner}" 1
	done

	# 3. Tier 2: Read-write schemas (USAGE + CRUD, no CREATE)
	for schema in "${TIER2_READWRITE_SCHEMAS[@]}"; do
		grant_schema_permissions "${db}" "${schema}" "${owner}" 2
	done

	# 4. Tier 3: Read-only schemas (USAGE + SELECT only)
	for schema in "${TIER3_READONLY_SCHEMAS[@]}"; do
		grant_schema_permissions "${db}" "${schema}" "${owner}" 3
	done

	# 5. Tier 4: Function-only schemas (USAGE + EXECUTE)
	for schema in "${TIER4_FUNCTION_ONLY_SCHEMAS[@]}"; do
		grant_schema_permissions "${db}" "${schema}" "${owner}" 4
	done

	# 6. Custom type permissions
	grant_type_permissions "${db}" "${owner}"

	# 7. Large object permissions
	grant_large_object_permissions "${db}" "${owner}"

	# 8. Set search_path
	set_role_search_path "${db}" "${owner}"

	_permissions_log "Complete permissions applied for '${owner}' in database '${db}'."
}

# _get_schema_tier returns the permission tier (1-4) for a schema.
# Returns 0 if schema is not in any tier array.
# Usage: _get_schema_tier <schema>
_get_schema_tier() {
	local schema=$1
	local s
	for s in "${TIER1_FULL_ACCESS_SCHEMAS[@]}"; do
		[[ "${s}" == "${schema}" ]] && echo 1 && return
	done
	for s in "${TIER2_READWRITE_SCHEMAS[@]}"; do
		[[ "${s}" == "${schema}" ]] && echo 2 && return
	done
	for s in "${TIER3_READONLY_SCHEMAS[@]}"; do
		[[ "${s}" == "${schema}" ]] && echo 3 && return
	done
	for s in "${TIER4_FUNCTION_ONLY_SCHEMAS[@]}"; do
		[[ "${s}" == "${schema}" ]] && echo 4 && return
	done
	echo 0
}

# validate_schema_permissions checks if a role has USAGE on a schema.
# Sets shell exit code to 0 if permissions are correct, 1 if missing.
# Usage: validate_schema_permissions <db> <schema> <role>
validate_schema_permissions() {
	local db=$1
	local schema=$2
	local role=$3

	local has_usage
	has_usage=$(_run_psql_query "${db}" "
		SELECT CASE WHEN EXISTS (
			SELECT 1 FROM pg_namespace n
			WHERE n.nspname = $(_psql_quote_literal "${schema}")
			AND has_schema_privilege($(_psql_quote_literal "${role}"), n.oid, 'USAGE')
		) THEN 'yes' ELSE 'no' END;
	")

	if [[ "${has_usage}" != "yes" ]]; then
		return 1
	fi
	return 0
}

# validate_function_permissions checks if a role has EXECUTE on functions in a schema.
# Outputs the count of functions without EXECUTE permission to stdout.
# Usage: validate_function_permissions <db> <schema> <role>
validate_function_permissions() {
	local db=$1
	local schema=$2
	local role=$3

	local missing_count
	missing_count=$(_run_psql_query "${db}" "
		SELECT COUNT(*) FROM pg_proc p
		JOIN pg_namespace n ON p.pronamespace = n.oid
		WHERE n.nspname = $(_psql_quote_literal "${schema}")
		AND NOT has_function_privilege($(_psql_quote_literal "${role}"), p.oid, 'EXECUTE');
	")

	echo "${missing_count:-0}"
}

# validate_sequence_permissions checks if a role has USAGE on sequences in a schema.
# Outputs the count of sequences without USAGE permission to stdout.
# Usage: validate_sequence_permissions <db> <schema> <role>
validate_sequence_permissions() {
	local db=$1
	local schema=$2
	local role=$3

	local missing_count
	missing_count=$(_run_psql_query "${db}" "
		SELECT COUNT(*) FROM pg_class c
		JOIN pg_namespace n ON c.relnamespace = n.oid
		WHERE n.nspname = $(_psql_quote_literal "${schema}") AND c.relkind = 'S'
		AND NOT has_sequence_privilege($(_psql_quote_literal "${role}"), c.oid, 'USAGE');
	")

	echo "${missing_count:-0}"
}

# validate_all_permissions performs comprehensive tier-aware permission validation for a role.
# Returns 0 if all permissions are correct, 1 if issues found.
# Outputs detailed issues to stderr.
# Usage: validate_all_permissions <db> <role>
validate_all_permissions() {
	local db=$1
	local role=$2
	local total_issues=0

	_permissions_log "Validating permissions for '${role}' in database '${db}'."

	for schema in "${ALL_EXTENSION_SCHEMAS[@]}"; do
		# Check if schema exists first
		local schema_exists
		schema_exists=$(_run_psql_query "${db}" "SELECT 1 FROM pg_namespace WHERE nspname = $(_psql_quote_literal "${schema}");")

		if [[ -n "${schema_exists}" ]]; then
			local tier
			tier=$(_get_schema_tier "${schema}")

			# Check schema USAGE (all tiers)
			if ! validate_schema_permissions "${db}" "${schema}" "${role}"; then
				_permissions_log "  [MISSING] Schema '${schema}' (tier ${tier}) USAGE"
				((total_issues++)) || true
			else
				_permissions_log "  [OK] Schema '${schema}' (tier ${tier}) USAGE"
			fi

			# Check CREATE permission (tier 1 only)
			if [[ "${tier}" == "1" ]]; then
				local has_create
				has_create=$(_run_psql_query "${db}" "
					SELECT CASE WHEN EXISTS (
						SELECT 1 FROM pg_namespace n
						WHERE n.nspname = $(_psql_quote_literal "${schema}")
						AND has_schema_privilege($(_psql_quote_literal "${role}"), n.oid, 'CREATE')
					) THEN 'yes' ELSE 'no' END;
				")
				if [[ "${has_create}" != "yes" ]]; then
					_permissions_log "  [MISSING] Schema '${schema}' CREATE (required for tier 1)"
					((total_issues++)) || true
				else
					_permissions_log "  [OK] Schema '${schema}' CREATE"
				fi
			fi

			# Check function EXECUTE (all tiers)
			local missing_funcs
			missing_funcs=$(validate_function_permissions "${db}" "${schema}" "${role}")
			if [[ "${missing_funcs}" -gt 0 ]]; then
				_permissions_log "  [MISSING] ${missing_funcs} functions in '${schema}' without EXECUTE"
				((total_issues++)) || true
			fi

			# Check sequence USAGE (tiers 1-3 only, not tier 4)
			if [[ "${tier}" != "4" ]]; then
				local missing_seqs
				missing_seqs=$(validate_sequence_permissions "${db}" "${schema}" "${role}")
				if [[ "${missing_seqs}" -gt 0 ]]; then
					_permissions_log "  [MISSING] ${missing_seqs} sequences in '${schema}' without USAGE"
					((total_issues++)) || true
				fi
			fi
		fi
	done

	if [[ ${total_issues} -eq 0 ]]; then
		_permissions_log "All permissions validated successfully for '${role}' in '${db}'."
		return 0
	else
		_permissions_log "Found ${total_issues} permission issue(s) for '${role}' in '${db}'."
		return 1
	fi
}

# repair_permissions validates and repairs tiered permissions for a database owner.
# Usage: repair_permissions <db> <role>
repair_permissions() {
	local db=$1
	local role=$2

	_permissions_log "Repairing permissions for '${role}' in database '${db}'."

	# Tier 1: Full access schemas
	for schema in "${TIER1_FULL_ACCESS_SCHEMAS[@]}"; do
		local schema_exists
		schema_exists=$(_run_psql_query "${db}" "SELECT 1 FROM pg_namespace WHERE nspname = $(_psql_quote_literal "${schema}");")
		if [[ -n "${schema_exists}" ]]; then
			_permissions_log "  [REPAIR] Granting tier 1 permissions on schema '${schema}'"
			grant_schema_permissions "${db}" "${schema}" "${role}" 1
		fi
	done

	# Tier 2: Read-write schemas
	for schema in "${TIER2_READWRITE_SCHEMAS[@]}"; do
		local schema_exists
		schema_exists=$(_run_psql_query "${db}" "SELECT 1 FROM pg_namespace WHERE nspname = $(_psql_quote_literal "${schema}");")
		if [[ -n "${schema_exists}" ]]; then
			_permissions_log "  [REPAIR] Granting tier 2 permissions on schema '${schema}'"
			grant_schema_permissions "${db}" "${schema}" "${role}" 2
		fi
	done

	# Tier 3: Read-only schemas
	for schema in "${TIER3_READONLY_SCHEMAS[@]}"; do
		local schema_exists
		schema_exists=$(_run_psql_query "${db}" "SELECT 1 FROM pg_namespace WHERE nspname = $(_psql_quote_literal "${schema}");")
		if [[ -n "${schema_exists}" ]]; then
			_permissions_log "  [REPAIR] Granting tier 3 permissions on schema '${schema}'"
			grant_schema_permissions "${db}" "${schema}" "${role}" 3
		fi
	done

	# Tier 4: Function-only schemas
	for schema in "${TIER4_FUNCTION_ONLY_SCHEMAS[@]}"; do
		local schema_exists
		schema_exists=$(_run_psql_query "${db}" "SELECT 1 FROM pg_namespace WHERE nspname = $(_psql_quote_literal "${schema}");")
		if [[ -n "${schema_exists}" ]]; then
			_permissions_log "  [REPAIR] Granting tier 4 permissions on schema '${schema}'"
			grant_schema_permissions "${db}" "${schema}" "${role}" 4
		fi
	done

	# Ensure type permissions
	grant_type_permissions "${db}" "${role}"

	# Ensure large object permissions
	grant_large_object_permissions "${db}" "${role}"

	# Ensure search_path is set
	set_role_search_path "${db}" "${role}"

	_permissions_log "Permission repair complete for '${role}' in '${db}'."
}

# generate_permission_report generates a CSV report of permissions by schema/role.
# Includes permission tier classification for each schema.
# Usage: generate_permission_report <db> [output_path]
generate_permission_report() {
	local db=$1
	local output=${2:-}

	local sql="
SELECT
    n.nspname AS schema_name,
    CASE
        WHEN n.nspname IN ('public','ag_catalog','partman','topology') THEN 'Tier 1 (Full)'
        WHEN n.nspname IN ('cron') THEN 'Tier 2 (Read-Write)'
        WHEN n.nspname IN ('tiger','tiger_data','address_standardizer','address_standardizer_data_us','squeeze') THEN 'Tier 3 (Read-Only)'
        WHEN n.nspname IN ('core_data_admin') THEN 'Tier 4 (Functions)'
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
     WHERE c.relnamespace = n.oid
     AND c.relkind = 'S'
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

# startup_permission_healthcheck runs permission validation/repair for all databases.
# This is the main entry point for the startup health check.
# Usage: startup_permission_healthcheck [repair_mode]
# repair_mode: "true" to auto-repair, "false" to report only (default: true)
startup_permission_healthcheck() {
	local repair_mode=${1:-true}
	local issues_found=0
	local repairs_applied=0

	_permissions_log "Permission health check starting..."

	# Get all non-template databases
	local databases
	if [[ -n "${POSTGRES_EXEC_MODE:-}" && "${POSTGRES_EXEC_MODE}" == "container" ]]; then
		mapfile -t databases < <(psql --tuples-only --no-align --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
			--command "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")
	else
		mapfile -t databases < <(compose_exec env PGHOST="${POSTGRES_HOST:-localhost}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
			psql --tuples-only --no-align --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
			--command "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');")
	fi

	for db in "${databases[@]}"; do
		[[ -z "${db}" ]] && continue

		# Get database owner
		local owner
		if [[ -n "${POSTGRES_EXEC_MODE:-}" && "${POSTGRES_EXEC_MODE}" == "container" ]]; then
			owner=$(psql --tuples-only --no-align --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
				--command "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = $(_psql_quote_literal "${db}");")
		else
			owner=$(compose_exec env PGHOST="${POSTGRES_HOST:-localhost}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
				psql --tuples-only --no-align --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
				--command "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname = $(_psql_quote_literal "${db}");")
		fi

		# Skip if owner is superuser
		if [[ -z "${owner}" || "${owner}" == "${POSTGRES_USER:-postgres}" || "${owner}" == "${POSTGRES_SUPERUSER:-postgres}" ]]; then
			_permissions_log "Skipping database '${db}' (owned by superuser)"
			continue
		fi

		_permissions_log "Checking database: ${db} (owner: ${owner})"

		if ! validate_all_permissions "${db}" "${owner}"; then
			((issues_found++)) || true
			if [[ "${repair_mode}" == "true" ]]; then
				repair_permissions "${db}" "${owner}"
				((repairs_applied++)) || true
			fi
		fi
	done

	if [[ ${issues_found} -gt 0 ]]; then
		if [[ "${repair_mode}" == "true" ]]; then
			_permissions_log "Permission health check complete: ${repairs_applied} database(s) repaired."
		else
			_permissions_log "Permission health check complete: ${issues_found} database(s) with issues. Run with repair mode to fix."
			return 1
		fi
	else
		_permissions_log "Permission health check complete: all databases OK."
	fi

	return 0
}
