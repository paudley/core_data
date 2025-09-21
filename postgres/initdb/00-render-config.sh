#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

TEMPLATE_DIR="/opt/core_data/conf"
SENTINEL="${PGDATA}/.core_data_config_rendered"
PGBACKREST_CONF_PATH="${PGDATA}/pgbackrest.conf"

mkdir -p "${PGDATA}"

if [[ -f "${SENTINEL}" ]]; then
  echo "[core_data] Configuration already rendered; skipping." >&2
  exit 0
fi

if command -v envsubst >/dev/null 2>&1; then
  envsubst < "${TEMPLATE_DIR}/postgresql.conf.tpl" > "${PGDATA}/postgresql.conf"
  envsubst < "${TEMPLATE_DIR}/pg_hba.conf.tpl" > "${PGDATA}/pg_hba.conf"
else
  echo "envsubst not installed inside container" >&2
  exit 1
fi

cat > "${PGBACKREST_CONF_PATH}" <<CONF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=7
process-max=4
start-fast=y
log-level-console=info

[main]
pg1-path=${PGDATA}
pg1-port=5432
CONF

chmod 600 "${PGBACKREST_CONF_PATH}"

echo "[core_data] Rendered PostgreSQL configs and pgBackRest configuration." >&2

pg_ctl -D "${PGDATA}" -m fast -w restart >/dev/null 2>&1 || {
  echo "[core_data] WARNING: pg_ctl restart failed during initialization." >&2
}

touch "${SENTINEL}"
