#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash
set -euo pipefail

APPARMOR_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
# shellcheck disable=SC1091
source "${APPARMOR_LIB_DIR}/common.sh"

cmd_apparmor_load() {
  local parser=${APPARMOR_PARSER:-apparmor_parser}
  if ! command -v "${parser}" >/dev/null 2>&1; then
    echo "[apparmor] ${parser} not found. Install apparmor-utils (Debian/Ubuntu) or ensure apparmor_parser is on PATH." >&2
    exit 1
  fi
  if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo "[apparmor] sudo required to load profiles or rerun as root." >&2
    exit 1
  fi
  local loaded=false
  for profile in "${ROOT_DIR}/apparmor"/*.profile; do
    [[ -e "${profile}" ]] || continue
    if [[ $EUID -ne 0 ]]; then
      sudo "${parser}" -r -W "${profile}" || exit 1
    else
      "${parser}" -r -W "${profile}" || exit 1
    fi
    loaded=true
    echo "[apparmor] loaded ${profile##*/}" >&2
  done
  if [[ ${loaded} == false ]]; then
    echo "[apparmor] no profiles found under ${ROOT_DIR}/apparmor" >&2
    exit 1
  fi
  echo "[apparmor] profiles loaded. Set CORE_DATA_APPARMOR_<SERVICE>=apparmor:core_data_minimal (or your custom profile) before composing." >&2
}
