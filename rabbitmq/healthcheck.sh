#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

if ! rabbitmq-diagnostics -q ping > /dev/null 2>&1; then
  echo "[rabbitmq-healthcheck] broker ping failed" >&2
  exit 1
fi

exit 0
