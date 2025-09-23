#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

POSTGRES_SUPERUSER=${POSTGRES_SUPERUSER:-postgres}
POSTGRES_DB=${POSTGRES_DB:-postgres}
POSTGRES_HOST=${POSTGRES_HOST:-postgres}
POSTGRES_PORT=${POSTGRES_PORT:-5432}
PASSWORD_FILE=${POSTGRES_SUPERUSER_PASSWORD_FILE:-/run/secrets/postgres_superuser_password}

if [[ ! -r "${PASSWORD_FILE}" ]]; then
  echo "[pghero] password file ${PASSWORD_FILE} not readable" >&2
  exit 1
fi

PASSWORD=$(cat "${PASSWORD_FILE}")
export DATABASE_URL="postgres://${POSTGRES_SUPERUSER}:${PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=prefer"
export PGHERO_DATABASE_URL="${DATABASE_URL}"

exec bundle exec puma -C /app/config/puma.rb
