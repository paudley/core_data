#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# shellcheck source=scripts/lib/db.sh
source "${SCRIPT_DIR}/lib/db.sh"
# shellcheck source=scripts/lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"
# shellcheck source=scripts/lib/maintenance.sh
source "${SCRIPT_DIR}/lib/maintenance.sh"
# shellcheck source=scripts/lib/upgrade.sh
source "${SCRIPT_DIR}/lib/upgrade.sh"
# shellcheck source=scripts/lib/audit.sh
source "${SCRIPT_DIR}/lib/audit.sh"
# shellcheck source=scripts/lib/maintenance_actions.sh
source "${SCRIPT_DIR}/lib/maintenance_actions.sh"
# shellcheck source=scripts/lib/extensions.sh
source "${SCRIPT_DIR}/lib/extensions.sh"
# shellcheck source=scripts/lib/partman.sh
source "${SCRIPT_DIR}/lib/partman.sh"
# shellcheck source=scripts/lib/async_queue.sh
source "${SCRIPT_DIR}/lib/async_queue.sh"
# shellcheck source=scripts/lib/extensions_list.sh
source "${SCRIPT_DIR}/lib/extensions_list.sh"
# shellcheck source=scripts/lib/extensions_helpers.sh
source "${SCRIPT_DIR}/lib/extensions_helpers.sh"

CORE_DATA_EXTENSIONS=("${CORE_EXTENSION_LIST[@]}")

bootstrap_database() {
  local db="$1"

  for ext in "${CORE_DATA_EXTENSIONS[@]}"; do
    if [[ "${ext}" == "pg_cron" && "${db}" != "postgres" ]]; then
      continue
    fi
    if [[ "${ext}" == "pg_partman" ]]; then
      local pg_partman_sql
      pg_partman_sql=$(generate_pg_partman_sql)
      compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
        psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" \
             --command "${pg_partman_sql}" >/dev/null
      continue
    fi
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" --command "CREATE EXTENSION IF NOT EXISTS \"${ext}\";" >/dev/null
  done

  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" <<'SQL'
CREATE SCHEMA IF NOT EXISTS core_data_admin;
ALTER SCHEMA core_data_admin OWNER TO CURRENT_USER;

CREATE OR REPLACE FUNCTION core_data_admin.refresh_pg_squeeze_targets()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT n.nspname AS schema_name,
           c.relname AS table_name
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r','m')
       AND n.nspname NOT LIKE 'pg_%'
       AND n.nspname <> 'information_schema'
       AND n.nspname NOT IN (
         'ag_catalog',
         'cron',
         'squeeze',
         'topology',
         'tiger',
         'tiger_data',
         'partman',
         'address_standardizer',
         'address_standardizer_data_us',
         'asyncq'
       )
  LOOP
    PERFORM squeeze.squeeze_table(rec.schema_name, rec.table_name);
  END LOOP;
END;
$$;

SELECT core_data_admin.refresh_pg_squeeze_targets();
SQL
}

schedule_pg_squeeze_job() {
  local db="$1"
  local job_name="core_data_pgsqueeze_${db}"

  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres <<SQL >/dev/null
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = '${job_name}';
SELECT cron.schedule_in_database('${job_name}', '15 3 * * *', \$\$SELECT core_data_admin.refresh_pg_squeeze_targets();\$\$, '${db}');
SQL
}

  usage() {
  cat <<USAGE
core_data management CLI

Usage: ${0##*/} <command> [options]

Commands:
  create-env                  Interactive helper to generate a tailored .env file.
  build-image                 Build the custom PostgreSQL image.
  up                          Start the stack in detached mode.
  down                        Stop the stack (preserving volumes).
  psql [args]                 Open psql inside the postgres container.
  create-user <user> <pass>   Create a role with LOGIN privilege.
  drop-user <user>            Drop a role.
  create-db <db> <owner>      Create a database owned by the specified user.
  drop-db <db>                Drop a database.
  dump <db> [file]            Logical backup using pg_dump (custom format).
  dump-sql <db> [file]        Plain-text SQL dump for review/editing.
  pgtune-config [options]     Generate tuned config include via pgtune (see options below).
  pgbadger-report [options]   Generate a pgbadger log report (HTML by default).
  daily-maintenance [options] Run the daily maintenance workflow (dump, logs, pgBadger, retention).
  restore-dump <file> <db>    Restore a logical backup (drops the db first).
  backup [--type=full|diff|incr]
                              Invoke pgBackRest backup.
                              Add --verify to restore and validate the latest backup.
  stanza-create               Initialize pgBackRest stanza.
  restore-snapshot [args]     Run pgBackRest restore (pass-through args).
  provision-qa <db>           Provision QA database from latest backup.
  config-check                Compare live configs to rendered templates.
  audit-roles [--output PATH] Report on role posture (CSV if output path supplied).
  audit-extensions [--output PATH]
                              Report extension versions across databases.
  audit-autovacuum [options]  List tables with high dead tuples.
     --output PATH            Write CSV to container path.
     --dead-threshold N       Dead tuple count threshold (default 100000).
     --ratio FLOAT            Dead tuple ratio threshold (default 0.2).
  audit-replication [--output PATH] [--lag-seconds N]
                              Summarise follower lag (CSV if output path supplied).
  audit-security [--output PATH]
                              Run HBA/password/RLS checks (text report if output set).
  audit-index-bloat [options] Report index density using pgstattuple.
     --output PATH            Write CSV to container path.
     --min-size-mb N          Minimum index size in MB (default 10).
  audit-buffercache [--output PATH] [--limit N]
                             Snapshot shared buffer usage by relation.
  audit-schema [--output PATH]
                              Snapshot information_schema columns.
  snapshot-pgstat [--output PATH] [--limit N]
                              Capture pg_stat_statements baseline (CSV with output).
  audit-cron [--output PATH]   List pg_cron jobs and next run.
  audit-squeeze [--output PATH]
                              Dump pg_squeeze activity table.
  exercise-extensions [--db DB]
                              Run smoke queries across the core extension bundle.
  pgtap-smoke [--db DB]       Execute a pgTap plan validating the bundled extensions.
  async-queue bootstrap [--db DB] [--schema NAME]
                             Install the lightweight async queue schema/functions.
  partman-maintenance [--db DB]
                             Run partman.run_maintenance_proc() in the target database.
  partman-show-config [--db DB] [--parent schema.table]
                             Display entries from partman.part_config.
  partman-create-parent [--db DB] [--type TYPE]
                             [--start PARTITION] [--premake N]
                             [--no-default-table] [--automatic on|off|none]
                             [--no-jobmon] [--time-encoder FUNC]
                             [--time-decoder FUNC]
                             Create a new managed parent (args:
                             schema.table control_column interval).
  version-status [--only-outdated] [--output PATH]
                             Compare installed versions against upstream releases.
  diff-pgstat --base PATH --compare PATH [--limit N]
                              Compare two pg_stat_statements snapshots.
  compact --level N [...options]
                              Level 1: autovacuum audit
                              Level 2: refresh pg_squeeze
                              Level 3: pg_repack (requires --tables)
                              Level 4: VACUUM FULL (requires --yes, optional --scope)
  upgrade --new-version <ver> Automate pg_upgrade using helper container.
  logs                        Tail postgres logs.
  status                      Show container status & health.
  pgtune options:
    --db-type <type>          web|oltp|dw|mixed|desktop (default: ${PGTUNE_DB_TYPE:-oltp})
    --connections <num>       Override max connections (optional)
    --memory <value>          Override total memory (e.g. 16GB) (optional)
    --output <path>           Override output path (default: /var/lib/postgresql/data/postgresql.pgtune.conf)
  pgbadger options:
     --since <ISO/time>       Only include entries since timestamp (passed to --begin)
     --output <path>          Override output path (default: /backups/pgbadger-YYYYMMDDHHMM.html)
     --jobs <n>               Parallel workers for pgbadger (default 2)
  daily-maintenance options:
     --root <path>            Override host backup root (default ./backups/daily)
     --retention <days>       Retention in days (default 30)
     --since <time>           Pass through to pgBadger (optional)
     --remove-source-logs     Remove original log files after copying/report (default: keep)
     --container-root <path>  Container path mapped to root (default /backups/daily)
  help                        Show this help.
USAGE
}

ensure_compose

COMMAND=${1:-help}
shift || true

  case "${COMMAND}" in
  create-env)
    shift
    bash "${SCRIPT_DIR}/create_env.sh" "$@"
    ;;
  build-image)
    ensure_env
    compose build postgres
    ;;
  up)
    ensure_env
    compose up -d
    ;;
  down)
    compose down
    ;;
  psql)
    ensure_env
    user_flag_provided=false
    host_flag_provided=false
    for arg in "$@"; do
      case "${arg}" in
        -U|--username|-U*|--username=*)
          user_flag_provided=true
          break
          ;;
      esac
    done
    for arg in "$@"; do
      case "${arg}" in
        -h|--host|-h*|--host=*)
          host_flag_provided=true
          break
          ;;
      esac
    done
    declare -a psql_env=()
    declare -a psql_cmd=(psql)
    host_env="${PGHOST:-${POSTGRES_HOST}}"
    if [[ "${user_flag_provided}" == "true" ]]; then
      if [[ -n "${PGUSER:-}" ]]; then
        psql_env+=("PGUSER=${PGUSER}")
      fi
      if [[ -n "${PGPASSWORD:-}" ]]; then
        psql_env+=("PGPASSWORD=${PGPASSWORD}")
      fi
    else
      psql_env+=("PGPASSWORD=${POSTGRES_SUPERUSER_PASSWORD:-}")
      psql_cmd+=(--username "${POSTGRES_SUPERUSER:-postgres}")
    fi
    if [[ "${host_flag_provided}" != "true" && -n "${host_env}" ]]; then
      psql_env+=("PGHOST=${host_env}")
    fi
    psql_cmd+=("$@")
    if [[ ${#psql_env[@]} -gt 0 ]]; then
      compose_exec env "${psql_env[@]}" "${psql_cmd[@]}"
    else
      compose_exec "${psql_cmd[@]}"
    fi
    ;;
  create-user)
    cmd_create_user "$@"
    ;;
  drop-user)
    cmd_drop_user "$@"
    ;;
  create-db)
    cmd_create_db "$@"
    ;;
  drop-db)
    cmd_drop_db "$@"
    ;;
  dump)
    cmd_dump "$@"
    ;;
  dump-sql)
    cmd_dump_sql "$@"
    ;;
  pgtune-config)
    ensure_env
    db_type=${PGTUNE_DB_TYPE:-oltp}
    connections=""
    total_memory=""
    output_path="/var/lib/postgresql/data/postgresql.pgtune.conf"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --db-type)
          db_type=$2; shift 2 ;;
        --db-type=*)
          db_type=${1#*=}; shift ;;
        --connections)
          connections=$2; shift 2 ;;
        --connections=*)
          connections=${1#*=}; shift ;;
        --memory)
          total_memory=$2; shift 2 ;;
        --memory=*)
          total_memory=${1#*=}; shift ;;
        --output)
          output_path=$2; shift 2 ;;
        --output=*)
          output_path=${1#*=}; shift ;;
        --)
          shift; break ;;
        -h|--help)
          echo "Usage: ${0##*/} pgtune-config [--db-type TYPE] [--connections N] [--memory VALUE] [--output PATH]" >&2
          exit 0 ;;
        *)
          echo "Unknown option for pgtune-config: $1" >&2
          exit 1 ;;
      esac
    done
    args=(--type "$db_type" --input-config /var/lib/postgresql/data/postgresql.conf --output-config "$output_path" --version "${PG_VERSION%%.*}")
    [[ -n $connections ]] && args+=(--connections "$connections")
    [[ -n $total_memory ]] && args+=(--memory "$total_memory")
    compose_exec python3 /opt/core_data/tools/pgtune.py "${args[@]}"
    compose_exec bash -lc "chmod 600 '$output_path'"
    compose_exec bash -lc "pg_ctl -D /var/lib/postgresql/data reload"
    echo "Generated tuned settings at ${output_path}. PostgreSQL reloaded to pick up include_if_exists." >&2
    ;;
  pgbadger-report)
    cmd_pgbadger_report "$@"
    ;;
  daily-maintenance)
    cmd_daily_maintenance "$@"
    ;;
  restore-dump)
    cmd_restore_dump "$@"
    ;;
  backup)
    cmd_backup "$@"
    ;;
  stanza-create)
    cmd_stanza_create "$@"
    ;;
  restore-snapshot)
    cmd_restore_snapshot "$@"
    ;;
  provision-qa)
    cmd_provision_qa "$@"
    ;;
  config-check)
    if config_drift_report; then
      echo "Configuration matches expected templates." >&2
    else
      exit 1
    fi
    ;;
  audit-roles)
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --)
          shift; break ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-roles [--output PATH]" >&2
          exit 0 ;;
        *)
          echo "Unknown option for audit-roles: $1" >&2
          exit 1 ;;
      esac
    done
    audit_roles "${output}"
    ;;
  audit-extensions)
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --)
          shift; break ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-extensions [--output PATH]" >&2
          exit 0 ;;
        *)
          echo "Unknown option for audit-extensions: $1" >&2
          exit 1 ;;
      esac
    done
    audit_extensions "${output}"
    ;;
  audit-autovacuum)
    output=""
    dead_threshold=${DAILY_DEAD_TUPLE_THRESHOLD:-100000}
    ratio_threshold=${DAILY_DEAD_TUPLE_RATIO:-0.2}
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --dead-threshold)
          dead_threshold=$2; shift 2 ;;
        --dead-threshold=*)
          dead_threshold=${1#*=}; shift ;;
        --ratio)
          ratio_threshold=$2; shift 2 ;;
        --ratio=*)
          ratio_threshold=${1#*=}; shift ;;
        --)
          shift; break ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-autovacuum [--output PATH] [--dead-threshold N] [--ratio FLOAT]" >&2
          exit 0 ;;
        *)
          echo "Unknown option for audit-autovacuum: $1" >&2
          exit 1 ;;
      esac
    done
    audit_autovacuum "${output}" "${dead_threshold}" "${ratio_threshold}"
    ;;
  audit-replication)
    output=""
    lag_seconds=${DAILY_REPLICATION_LAG_THRESHOLD:-300}
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --lag-seconds)
          lag_seconds=$2; shift 2 ;;
        --lag-seconds=*)
          lag_seconds=${1#*=}; shift ;;
        --)
          shift; break ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-replication [--output PATH] [--lag-seconds N]" >&2
          exit 0 ;;
        *)
          echo "Unknown option for audit-replication: $1" >&2
          exit 1 ;;
      esac
    done
    audit_replication_lag "${output}" "${lag_seconds}"
    ;;
  audit-security)
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --)
          shift; break ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-security [--output PATH]" >&2
          exit 0 ;;
        *)
          echo "Unknown option for audit-security: $1" >&2
          exit 1 ;;
      esac
    done
    audit_security "${output}"
    ;;
  audit-index-bloat)
    output=""
    min_size=${DAILY_INDEX_MIN_SIZE_MB:-10}
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --min-size-mb)
          min_size=$2; shift 2 ;;
        --min-size-mb=*)
          min_size=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-index-bloat [--output PATH] [--min-size-mb N]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for audit-index-bloat: $1" >&2
          exit 1 ;;
      esac
    done
    audit_index_bloat "${output}" "${min_size}"
    ;;
  audit-buffercache)
    output=""
    limit=${PG_BUFFERCACHE_LIMIT:-50}
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --limit)
          limit=$2; shift 2 ;;
        --limit=*)
          limit=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-buffercache [--output PATH] [--limit N]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for audit-buffercache: $1" >&2
          exit 1 ;;
      esac
    done
    audit_pg_buffercache "${output}" "${limit}"
    ;;
  audit-schema)
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-schema [--output PATH]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for audit-schema: $1" >&2
          exit 1 ;;
      esac
    done
    audit_schema_snapshot "${output}"
    ;;
  audit-cron)
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-cron [--output PATH]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for audit-cron: $1" >&2
          exit 1 ;;
      esac
    done
    audit_pg_cron "${output}"
    ;;
  audit-squeeze)
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} audit-squeeze [--output PATH]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for audit-squeeze: $1" >&2
          exit 1 ;;
      esac
    done
    audit_pg_squeeze "${output}"
    ;;
  snapshot-pgstat)
    output=""
    limit=${PG_STAT_STATEMENTS_LIMIT:-100}
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --limit)
          limit=$2; shift 2 ;;
        --limit=*)
          limit=${1#*=}; shift ;;
        --)
          shift; break ;;
        -h|--help)
          echo "Usage: ${0##*/} snapshot-pgstat [--output PATH] [--limit N]" >&2
          exit 0 ;;
        *)
          echo "Unknown option for snapshot-pgstat: $1" >&2
          exit 1 ;;
      esac
    done
    snapshot_pg_stat_statements "${output}" "${limit}"
    ;;
  diff-pgstat)
    base=""
    compare=""
    limit=${PG_STAT_STATEMENTS_LIMIT:-100}
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --base)
          base=$2; shift 2 ;;
        --base=*)
          base=${1#*=}; shift ;;
        --compare)
          compare=$2; shift 2 ;;
        --compare=*)
          compare=${1#*=}; shift ;;
        --limit)
          limit=$2; shift 2 ;;
        --limit=*)
          limit=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} diff-pgstat --base PATH --compare PATH [--limit N]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for diff-pgstat: $1" >&2
          exit 1 ;;
      esac
    done
    if [[ -z ${base} || -z ${compare} ]]; then
      echo "--base and --compare are required" >&2
      exit 1
    fi
    python3 '${SCRIPT_DIR}/perf_diff.py' --base "${base}" --compare "${compare}" --limit "${limit}"
    ;;
  compact)
    ensure_env
    level=""
    tables=""
    scope="all"
    confirm=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --level)
          level=$2; shift 2 ;;
        --level=*)
          level=${1#*=}; shift ;;
        --tables)
          tables=$2; shift 2 ;;
        --tables=*)
          tables=${1#*=}; shift ;;
        --scope)
          scope=$2; shift 2 ;;
        --scope=*)
          scope=${1#*=}; shift ;;
        --yes|-y)
          confirm=true; shift ;;
        -h|--help)
          cat <<USAGE >&2
Usage: ${0##*/} compact --level <1|2|3|4> [--tables schema.table[,..]] [--scope schema.table[,..]|all] [--yes]

Level 1: Run autovacuum audit report.
Level 2: Refresh pg_squeeze targets and report status.
Level 3: Execute pg_repack on provided tables (requires --tables).
Level 4: Run VACUUM FULL (default all tables, or provide --scope) and requires --yes confirmation.
USAGE
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for compact: $1" >&2
          exit 1 ;;
      esac
    done
    if [[ -z ${level} ]]; then
      echo "[compact] --level is required" >&2
      exit 1
    fi
    case "${level}" in
      1)
        audit_autovacuum
        ;;
      2)
        refresh_pg_squeeze
        ;;
      3)
        if [[ -z ${tables} ]]; then
          echo "[compact] Level 3 requires --tables schema.table[,schema.table...]" >&2
          exit 1
        fi
        run_pg_repack "${tables}"
        ;;
      4)
        if [[ ${confirm} != true ]]; then
          echo "[compact] Level 4 (VACUUM FULL) requires --yes confirmation" >&2
          exit 1
        fi
        run_vacuum_full "${scope}"
        ;;
      *)
        echo "[compact] Unknown level '${level}'" >&2
        exit 1
        ;;
    esac
    ;;
  exercise-extensions)
    db=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --db)
          db=$2; shift 2 ;;
        --db=*)
          db=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} exercise-extensions [--db NAME]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for exercise-extensions: $1" >&2
          exit 1 ;;
      esac
    done
    exercise_extensions "${db}"
    ;;
  pgtap-smoke)
    db=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --db)
          db=$2; shift 2 ;;
        --db=*)
          db=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} pgtap-smoke [--db NAME]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for pgtap-smoke: $1" >&2
          exit 1 ;;
      esac
    done
    run_pgtap_smoke "${db}"
    ;;
  async-queue)
    subcommand=${1:-help}
    shift || true
    case "${subcommand}" in
      bootstrap)
        db=""
        schema=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --db)
              db=$2; shift 2 ;;
            --db=*)
              db=${1#*=}; shift ;;
            --schema)
              schema=$2; shift 2 ;;
            --schema=*)
              schema=${1#*=}; shift ;;
            -h|--help)
              echo "Usage: ${0##*/} async-queue bootstrap [--db NAME] [--schema NAME]" >&2
              exit 0 ;;
            --)
              shift; break ;;
            *)
              echo "Unknown option for async-queue bootstrap: $1" >&2
              exit 1 ;;
          esac
        done
        async_queue_bootstrap "${db:-${POSTGRES_DB:-postgres}}" "${schema:-${ASYNCQ_DEFAULT_SCHEMA:-asyncq}}"
        ;;
      help|-h|--help)
        echo "Usage: ${0##*/} async-queue bootstrap [--db NAME] [--schema NAME]" >&2
        ;;
      *)
        echo "Unknown async-queue subcommand: ${subcommand}" >&2
        echo "Usage: ${0##*/} async-queue bootstrap [--db NAME] [--schema NAME]" >&2
        exit 1 ;;
    esac
    ;;
  partman-maintenance)
    db=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --db)
          db=$2; shift 2 ;;
        --db=*)
          db=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} partman-maintenance [--db NAME]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for partman-maintenance: $1" >&2
          exit 1 ;;
      esac
    done
    partman_run_maintenance "${db:-${POSTGRES_DB:-postgres}}"
    ;;
  partman-show-config)
    db=""
    parent=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --db)
          db=$2; shift 2 ;;
        --db=*)
          db=${1#*=}; shift ;;
        --parent)
          parent=$2; shift 2 ;;
        --parent=*)
          parent=${1#*=}; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} partman-show-config [--db NAME] [--parent schema.table]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for partman-show-config: $1" >&2
          exit 1 ;;
      esac
    done
    partman_show_config "${db:-${POSTGRES_DB:-postgres}}" "${parent}"
    ;;
  partman-create-parent)
    db=""
    part_type="range"
    start_partition=""
    premake=""
    default_table=true
    automatic_mode="on"
    jobmon=true
    time_encoder=""
    time_decoder=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --db)
          db=$2; shift 2 ;;
        --db=*)
          db=${1#*=}; shift ;;
        --type)
          part_type=$2; shift 2 ;;
        --type=*)
          part_type=${1#*=}; shift ;;
        --start)
          start_partition=$2; shift 2 ;;
        --start=*)
          start_partition=${1#*=}; shift ;;
        --premake)
          premake=$2; shift 2 ;;
        --premake=*)
          premake=${1#*=}; shift ;;
        --no-default-table)
          default_table=false; shift ;;
        --automatic)
          automatic_mode=$2; shift 2 ;;
        --automatic=*)
          automatic_mode=${1#*=}; shift ;;
        --no-jobmon)
          jobmon=false; shift ;;
        --time-encoder)
          time_encoder=$2; shift 2 ;;
        --time-encoder=*)
          time_encoder=${1#*=}; shift ;;
        --time-decoder)
          time_decoder=$2; shift 2 ;;
        --time-decoder=*)
          time_decoder=${1#*=}; shift ;;
        -h|--help)
          cat <<'USAGE' >&2
Usage: manage.sh partman-create-parent [options] schema.table control_column interval

Options:
  --db NAME                 Target database (default: POSTGRES_DB)
  --type TYPE               Partitioning type (default: range)
  --start PARTITION         Starting partition boundary
  --premake N               Number of future partitions to premake
  --no-default-table        Do not keep a default partition
  --automatic on|off|none   Override automatic maintenance behaviour
  --no-jobmon               Disable pg_jobmon integration
  --time-encoder FUNC       Override time encoder function
  --time-decoder FUNC       Override time decoder function
USAGE
          exit 0 ;;
        --)
          shift; break ;;
        *)
          break ;;
      esac
    done

    if [[ $# -lt 3 ]]; then
      echo "Usage: ${0##*/} partman-create-parent [options] schema.table control_column interval" >&2
      exit 1
    fi

    parent_table=$1
    control_column=$2
    interval=$3
    shift 3

    if [[ $# -gt 0 ]]; then
      echo "Unknown positional arguments: $*" >&2
      exit 1
    fi

    partman_create_parent \
      "${db:-${POSTGRES_DB:-postgres}}" \
      "${parent_table}" \
      "${control_column}" \
      "${interval}" \
      "${part_type}" \
      "${start_partition}" \
      "${premake}" \
      "${default_table}" \
      "${automatic_mode}" \
      "${jobmon}" \
      "${time_encoder}" \
      "${time_decoder}"
    ;;
  version-status)
    output=""
    only_outdated=false
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          output=$2; shift 2 ;;
        --output=*)
          output=${1#*=}; shift ;;
        --only-outdated)
          only_outdated=true; shift ;;
        -h|--help)
          echo "Usage: ${0##*/} version-status [--only-outdated] [--output PATH]" >&2
          exit 0 ;;
        --)
          shift; break ;;
        *)
          echo "Unknown option for version-status: $1" >&2
          exit 1 ;;
      esac
    done
    cmd=(python3 "${SCRIPT_DIR}/version_status.py")
    if [[ ${only_outdated} == true ]]; then
      cmd+=("--only-outdated")
    fi
    if [[ -n ${output} ]]; then
      cmd+=("--output" "${output}")
    fi
    "${cmd[@]}"
    ;;
  upgrade)
    cmd_upgrade "$@"
    ;;

  logs)
    compose logs -f postgres
    ;;
  status)
    compose ps
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    usage
    exit 1
    ;;
esac
