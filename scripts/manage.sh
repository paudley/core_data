#!/usr/bin/env bash
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

CORE_DATA_EXTENSIONS=(
  postgis
  postgis_raster
  postgis_topology
  vector
  age
  pgaudit
  pg_stat_statements
  pg_cron
  pgtap
  pg_repack
  pg_squeeze
)

bootstrap_database() {
  local db="$1"

  for ext in "${CORE_DATA_EXTENSIONS[@]}"; do
    if [[ "${ext}" == "pg_cron" && "${db}" != "postgres" ]]; then
      continue
    fi
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${db}" --command "CREATE EXTENSION IF NOT EXISTS ${ext};" >/dev/null
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
       AND n.nspname NOT IN ('ag_catalog','cron','squeeze','topology')
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
  stanza-create               Initialize pgBackRest stanza.
  restore-snapshot [args]     Run pgBackRest restore (pass-through args).
  provision-qa <db>           Provision QA database from latest backup.
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
