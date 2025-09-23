#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

SEC_COMP_SERVICES=(postgres logical_backup pgbouncer valkey memcached)
SEC_COMP_PROFILE_DIR=${SEC_COMP_PROFILE_DIR:-${ROOT_DIR}/seccomp}
SEC_COMP_DEFAULT_PROFILE=${SEC_COMP_DEFAULT_PROFILE:-${SEC_COMP_PROFILE_DIR}/docker-default.json}
SEC_COMP_TRACE_DIR=${SEC_COMP_TRACE_DIR:-${SEC_COMP_PROFILE_DIR}/traces}

_seccomp_profile_var() {
  local service=$1
  local upper
  upper=$(printf '%s' "${service}" | tr '[:lower:]' '[:upper:]')
  echo "CORE_DATA_SECCOMP_${upper//-/_}"
}

seccomp_resolve_profile() {
  local service=$1
  local var
  var=$(_seccomp_profile_var "${service}")
  local value=${!var-}
  if [[ -z ${value} ]]; then
    printf 'seccomp:%s\n' "${SEC_COMP_DEFAULT_PROFILE}"
    return
  fi
  printf '%s\n' "${value}"
}

seccomp_extract_path() {
  local spec=$1
  case "${spec}" in
    seccomp:*)
      printf '%s\n' "${spec#seccomp:}"
      ;;
    seccomp=*)
      printf '%s\n' "${spec#seccomp=}"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

seccomp_status_line() {
  local service=$1
  local spec
  spec=$(seccomp_resolve_profile "${service}")
  local profile_path
  profile_path=$(seccomp_extract_path "${spec}")
  if [[ -z ${profile_path} ]]; then
    printf '%-16s %s\n' "${service}" "${spec}"
    return
  fi
  local resolved
  if [[ ${profile_path} == /* ]]; then
    resolved=${profile_path}
  else
    resolved=${ROOT_DIR}/${profile_path#./}
  fi
  if [[ -f ${resolved} ]]; then
    printf '%-16s %s (present)\n' "${service}" "${spec}"
  else
    printf '%-16s %s (missing)\n' "${service}" "${spec}"
  fi
}

cmd_seccomp_status() {
  ensure_env
  echo "Service         Profile"
  echo "---------------- -------"
  for service in "${SEC_COMP_SERVICES[@]}"; do
    seccomp_status_line "${service}"
  done
  echo
  echo "Profiles default to ${SEC_COMP_DEFAULT_PROFILE}. Override with CORE_DATA_SECCOMP_<SERVICE>=seccomp:/path/to/profile.json."
}

cmd_seccomp_trace() {
  ensure_env
  if [[ $# -lt 1 ]]; then
    echo "Usage: ${0##*/} seccomp-trace <service>" >&2
    exit 1
  fi
  local service=$1
  local found=false
  for candidate in "${SEC_COMP_SERVICES[@]}"; do
    if [[ ${candidate} == "${service}" ]]; then
      found=true
      break
    fi
  done
  if [[ ${found} == false ]]; then
    echo "Unknown service '${service}'. Valid options: ${SEC_COMP_SERVICES[*]}" >&2
    exit 1
  fi
  mkdir -p "${SEC_COMP_TRACE_DIR}" >&2
  cat <<MSG
[seccomp] Trace helper prepared directory ${SEC_COMP_TRACE_DIR}/${service}.

Recommended workflow:
  1. Stop any running stack (\`./scripts/manage.sh down\`).
  2. Launch the target container under strace using the bundled wrapper. Example for Postgres:
       TRACE_DIR=${SEC_COMP_TRACE_DIR} SERVICE=postgres \\
         docker compose run --rm \\
           --entrypoint /opt/core_data/scripts/trace_entrypoint.sh \\
           postgres docker-entrypoint.sh postgres
     (Replace the final command with the appropriate entrypoint/args for other services, e.g.
      \`docker-entrypoint.sh /opt/core_data/scripts/logical_backup_runner.sh\`.)
     Keep the container running while you exercise workloads (pytest, manage.sh commands, etc.).
  3. When finished, stop the strace session. Trace output (.trace files) will live under
       ${SEC_COMP_TRACE_DIR}/${service}/<timestamp>/
  4. Run '${0##*/} seccomp-generate ${service} --trace-dir ${SEC_COMP_TRACE_DIR}/${service}' to emit a tailored profile.

See docs/security_philosophy.md for additional guidance.
MSG
}

cmd_seccomp_generate() {
  ensure_env
  if [[ $# -lt 1 ]]; then
    echo "Usage: ${0##*/} seccomp-generate <service> [--trace-dir DIR] [--output PATH]" >&2
    exit 1
  fi
  local service=$1
  shift
  local trace_dir=${SEC_COMP_TRACE_DIR}
  local output=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --trace-dir)
        trace_dir=$2
        shift 2
        ;;
      --trace-dir=*)
        trace_dir=${1#*=}
        shift
        ;;
      --output)
        output=$2
        shift 2
        ;;
      --output=*)
        output=${1#*=}
        shift
        ;;
      --help|-h)
        echo "Usage: ${0##*/} seccomp-generate <service> [--trace-dir DIR] [--output PATH]" >&2
        exit 0
        ;;
      *)
        echo "Unknown option '${1}'" >&2
        exit 1
        ;;
    esac
  done

  if [[ ! -d ${trace_dir} ]]; then
    echo "[seccomp] Trace directory '${trace_dir}' not found. Run seccomp-trace first." >&2
    exit 1
  fi

  local spec
  spec=$(seccomp_resolve_profile "${service}")
  local profile_path
  profile_path=$(seccomp_extract_path "${spec}")
  if [[ -z ${profile_path} ]]; then
    profile_path=${SEC_COMP_DEFAULT_PROFILE}
  fi
  if [[ -z ${output} ]]; then
    output=${profile_path}
  fi
  mkdir -p "$(dirname "${output}")"

  cat <<'PY' | python3 - "${trace_dir}" "${output}"
import json
import sys
from pathlib import Path

trace_root = Path(sys.argv[1])
output_path = Path(sys.argv[2])

syscalls = set()
for trace_file in trace_root.rglob("*.trace"):
    try:
        content = trace_file.read_text()
    except Exception:
        continue
    for line in content.splitlines():
        if '(' not in line:
            continue
        name = line.split('(', 1)[0].strip()
        if name:
            syscalls.add(name)

if not syscalls:
    print("[seccomp] No syscalls detected in trace files (.trace).", file=sys.stderr)
    sys.exit(1)

profile = {
    "defaultAction": "SCMP_ACT_ERRNO",
    "archMap": [
        {
            "architecture": "SCMP_ARCH_X86_64",
            "subArchitectures": ["SCMP_ARCH_X86", "SCMP_ARCH_X32"],
        },
        {
            "architecture": "SCMP_ARCH_AARCH64",
            "subArchitectures": ["SCMP_ARCH_ARM", "SCMP_ARCH_AARCH64"],
        },
    ],
    "syscalls": [
        {
            "names": sorted(syscalls),
            "action": "SCMP_ACT_ALLOW",
        }
    ],
}

output_path.write_text(json.dumps(profile, indent=2) + "\n")
print(f"[seccomp] Wrote profile with {len(syscalls)} syscalls to {output_path}")
PY
}

cmd_seccomp_verify() {
  ensure_env
  local json
  if ! json=$(compose config --format json); then
    echo "[seccomp] Unable to render compose configuration." >&2
    exit 1
  fi
  echo "${json}" | python3 - <<'PY'
import json
import sys

config = json.load(sys.stdin)
services = {
    "postgres": "CORE_DATA_SECCOMP_POSTGRES",
    "logical_backup": "CORE_DATA_SECCOMP_LOGICAL_BACKUP",
    "pgbouncer": "CORE_DATA_SECCOMP_PGBOUNCER",
    "valkey": "CORE_DATA_SECCOMP_VALKEY",
    "memcached": "CORE_DATA_SECCOMP_MEMCACHED",
    "pghero": "CORE_DATA_SECCOMP_PGHERO",
}
missing = []
for service, var in services.items():
    svc = config.get("services", {}).get(service)
    if not svc:
        continue
    opts = svc.get("security_opt") or []
    if not any(opt.startswith("seccomp:") or opt.startswith("seccomp=") for opt in opts):
        missing.append((service, var))

if missing:
    print("[seccomp] Missing seccomp security_opt for:")
    for service, var in missing:
        print(f"  - {service} (override env: {var})")
    sys.exit(1)
print("[seccomp] All services define seccomp security options.")
PY
}
