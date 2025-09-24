#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Synthetic dataset bootstrap helpers for exercising bundled extensions end-to-end.
set -euo pipefail

LIB_TEST_DATASET_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${LIB_TEST_DATASET_DIR}/common.sh"

random_testkit_password() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
}

ensure_testkit_role() {
  local role=$1
  local password=$2
  compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
DO
\$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role}') THEN
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${role}', '${password}');
  ELSE
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${role}', '${password}');
  END IF;
END
\$\$;
SQL
}

seed_test_dataset() {
  local database=$1
  local owner=$2
  local overwrite_schema=$3

  local overwrite_flag=0
  if [[ "${overwrite_schema}" == "true" ]]; then
    overwrite_flag=1
  fi

  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --set ON_ERROR_STOP=on --username "${POSTGRES_SUPERUSER:-postgres}" \
         --dbname "${database}" \
         --set="dataset_owner=${owner}" \
         --set="dataset_name=${database}" \
         --set="overwrite_schema=${overwrite_flag}" \
         --file /opt/core_data/scripts/test_data/test_dataset.psql
}

cmd_test_dataset_bootstrap() {
  ensure_env
  local database="core_data_testkit"
  local owner="testkit_owner"
  local password=""
  local show_password=false
  local overwrite_schema=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db)
        database=$2; shift 2 ;;
      --db=*)
        database=${1#*=}; shift ;;
      --owner)
        owner=$2; shift 2 ;;
      --owner=*)
        owner=${1#*=}; shift ;;
      --password)
        password=$2; shift 2 ;;
      --password=*)
        password=${1#*=}; shift ;;
      --print-password)
        show_password=true; shift ;;
      --force)
        overwrite_schema=true; shift ;;
      -h|--help)
        cat <<USAGE
Usage: ${0##*/} test-dataset bootstrap [--db NAME] [--owner ROLE] [--password SECRET] [--print-password] [--force]
  --db NAME           Target database to create/seed (default: core_data_testkit)
  --owner ROLE        Database owner/login role (default: testkit_owner)
  --password SECRET   Password for ROLE (random if omitted)
  --print-password    Echo the resolved password to stdout once provisioning finishes
  --force             Drop and recreate the testkit schema if it already exists
USAGE
        return 0 ;;
      --)
        shift; break ;;
      *)
        echo "Unknown option for test-dataset bootstrap: $1" >&2
        return 1 ;;
    esac
  done

  if [[ -z "${password}" ]]; then
    password=$(random_testkit_password)
    show_password=true
  fi

  ensure_testkit_role "${owner}" "${password}"
  cmd_create_db "${database}" "${owner}"
  seed_test_dataset "${database}" "${owner}" "${overwrite_schema}"

  if [[ "${show_password}" == true ]]; then
    echo "[test-dataset] role=${owner} password=${password}"
  fi
  echo "[test-dataset] Seeded dataset in ${database} (owner: ${owner})." >&2
}

cmd_test_dataset() {
  local subcommand=${1:-help}
  shift || true
  case "${subcommand}" in
    bootstrap)
      cmd_test_dataset_bootstrap "$@"
      ;;
    help|-h|--help)
      echo "Usage: ${0##*/} test-dataset bootstrap [--db NAME] [--owner ROLE] [--password SECRET] [--print-password] [--force]" >&2
      ;;
    *)
      echo "Unknown test-dataset subcommand: ${subcommand}" >&2
      echo "Usage: ${0##*/} test-dataset bootstrap [--db NAME] [--owner ROLE] [--password SECRET] [--print-password] [--force]" >&2
      return 1 ;;
  esac
}
