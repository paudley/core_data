#!/usr/bin/env bash
set -euo pipefail

: "${TRACE_DIR:?TRACE_DIR not set}"
: "${SERVICE:?SERVICE not set}"

TRACE_BASE=$(date +%Y%m%d-%H%M%S)
TRACE_PATH="${TRACE_DIR}/${SERVICE}/${TRACE_BASE}"
mkdir -p "${TRACE_PATH}"

if [[ -r /run/secrets/postgres_superuser_password ]]; then
  export POSTGRES_SUPERUSER_PASSWORD=$(tr -d '\r\n' </run/secrets/postgres_superuser_password)
fi

exec strace -ff -tt -o "${TRACE_PATH}/${SERVICE}.trace" "$@"
