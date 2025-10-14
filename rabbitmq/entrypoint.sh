#!/bin/sh
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -eu

normalize_secret() {
  if [ -n "$1" ]; then
    printf '%s' "$1" | tr -d '\r\n'
  fi
}

password="$(normalize_secret "${RABBITMQ_DEFAULT_PASS:-}")"
if [ -z "${password}" ]; then
  if [ -n "${RABBITMQ_DEFAULT_PASS_FILE:-}" ] && [ -r "${RABBITMQ_DEFAULT_PASS_FILE}" ]; then
    password="$(normalize_secret "$(cat "${RABBITMQ_DEFAULT_PASS_FILE}")")"
  elif [ -r /run/secrets/rabbitmq_default_pass ]; then
    password="$(normalize_secret "$(cat /run/secrets/rabbitmq_default_pass)")"
  fi
fi

if [ -z "${password}" ]; then
  echo "[rabbitmq] ERROR: Default user password not provided (set RABBITMQ_DEFAULT_PASS_FILE or RABBITMQ_DEFAULT_PASS)." >&2
  exit 1
fi

cookie="$(normalize_secret "${RABBITMQ_ERLANG_COOKIE:-}")"
if [ -z "${cookie}" ]; then
  if [ -n "${RABBITMQ_ERLANG_COOKIE_FILE:-}" ] && [ -r "${RABBITMQ_ERLANG_COOKIE_FILE}" ]; then
    cookie="$(normalize_secret "$(cat "${RABBITMQ_ERLANG_COOKIE_FILE}")")"
  elif [ -r /run/secrets/rabbitmq_erlang_cookie ]; then
    cookie="$(normalize_secret "$(cat /run/secrets/rabbitmq_erlang_cookie)")"
  fi
fi

if [ -z "${cookie}" ]; then
  echo "[rabbitmq] WARNING: Erlang cookie not provided; generating ephemeral value." >&2
  cookie="$(hexdump -vn16 -e '/1 "%02x"' /dev/urandom 2>/dev/null || echo "coredata$(date +%s)")"
fi

export RABBITMQ_DEFAULT_USER="${RABBITMQ_DEFAULT_USER:-coredata}"
export RABBITMQ_DEFAULT_PASS="${password}"
export RABBITMQ_ERLANG_COOKIE="${cookie}"
export RABBITMQ_PORT="${RABBITMQ_PORT:-5672}"
export RABBITMQ_MANAGEMENT_PORT="${RABBITMQ_MANAGEMENT_PORT:-15672}"

unset RABBITMQ_DEFAULT_PASS_FILE
unset RABBITMQ_ERLANG_COOKIE_FILE

entrypoint="/opt/rabbitmq/sbin/docker-entrypoint.sh"
if [ ! -x "${entrypoint}" ]; then
  entrypoint="$(command -v docker-entrypoint.sh || true)"
fi
if [ -z "${entrypoint}" ] || [ ! -x "${entrypoint}" ]; then
  echo "[rabbitmq] ERROR: Unable to locate docker-entrypoint.sh inside the image." >&2
  exit 1
fi

exec "${entrypoint}" "$@"
