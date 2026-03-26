#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Wrapper around the official postgres docker-entrypoint.sh.
# Launches the extension sync in the background after postgres starts,
# then exec's the real entrypoint so postgres remains PID 1.

set -euo pipefail

# Launch extension sync as a background job that waits for postgres readiness.
/opt/core_data/tools/ensure_extensions.sh &

# Hand off to the official entrypoint (postgres becomes PID 1 via exec).
exec docker-entrypoint.sh "$@"
