#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

SEC_COMP_SERVICES=(postgres logical_backup pgbouncer valkey memcached pghero)
SEC_COMP_PROFILE_DIR=${SEC_COMP_PROFILE_DIR:-${ROOT_DIR}/seccomp}
SEC_COMP_DEFAULT_PROFILE=${SEC_COMP_DEFAULT_PROFILE:-${SEC_COMP_PROFILE_DIR}/docker-default.json}
SEC_COMP_TRACE_DIR=${SEC_COMP_TRACE_DIR:-${SEC_COMP_PROFILE_DIR}/traces}

declare -A SEC_COMP_SERVICE_DEFAULT_SPEC=(
  [postgres]='seccomp:./seccomp/postgres.json'
  [logical_backup]='seccomp:./seccomp/logical_backup.json'
  [pgbouncer]='seccomp:./seccomp/pgbouncer.json'
  [valkey]='seccomp:./seccomp/valkey.json'
  [memcached]='seccomp:./seccomp/memcached.json'
  [pghero]='seccomp:./seccomp/pghero.json'
)

MANDATORY_SYSCALLS=(
  "open"
  "openat"
  "close_range"
  "openat2"
  "pidfd_close"
  "pidfd_getfd"
  "pidfd_open"
  "pidfd_send_signal"
  "capget"
  "capset"
  "fstatat"
  "newfstatat"
  "statx"
  "setuid"
  "setgid"
  "setresuid"
  "setresgid"
  "setgroups"
  "setfsuid"
  "setfsgid"
)

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
  if [[ -n ${value} ]]; then
    printf '%s\n' "${value}"
    return
  fi
  local default_spec=${SEC_COMP_SERVICE_DEFAULT_SPEC[${service}]-}
  if [[ -n ${default_spec} ]]; then
    printf '%s\n' "${default_spec}"
    return
  fi
  printf 'seccomp:%s\n' "${SEC_COMP_DEFAULT_PROFILE}"
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
  echo "Profiles inherit from ${SEC_COMP_DEFAULT_PROFILE} (Docker's baseline) plus traced syscalls. Override with CORE_DATA_SECCOMP_<SERVICE>=seccomp:/path/to/profile.json when you need a custom override."
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

  local mandatory_csv
  mandatory_csv=$(printf '%s,' "${MANDATORY_SYSCALLS[@]}")
  MANDATORY_SYSCALLS="${mandatory_csv%,}" DEFAULT_SECCOMP_PROFILE="${SEC_COMP_DEFAULT_PROFILE}" python3 - "${trace_dir}" "${output}" <<'PY'
import json
import os
import sys
from pathlib import Path

trace_root = Path(sys.argv[1])
output_path = Path(sys.argv[2])

syscalls = set()
trace_files = list(trace_root.rglob("*.trace")) + list(trace_root.rglob("*.trace.*"))
if not trace_files:
    trace_files = list(trace_root.rglob("*.strace"))
if not trace_files:
    trace_files = list(trace_root.rglob("*.log"))

for trace_file in trace_files:
    try:
        content = trace_file.read_text()
    except Exception:
        continue
    for line in content.splitlines():
        if '(' not in line:
            continue
        prefix = line.split('(', 1)[0].strip()
        if not prefix:
            continue
        name = prefix.split()[-1]
        if name:
            syscalls.add(name)

if not syscalls:
    print("[seccomp] No syscalls detected in trace files.", file=sys.stderr)
    sys.exit(1)

for required in filter(None, (name.strip() for name in os.environ.get("MANDATORY_SYSCALLS", "").split(','))):
    syscalls.add(required)

default_profile_path = os.environ.get("DEFAULT_SECCOMP_PROFILE")
if default_profile_path:
    try:
        default_profile = json.loads(Path(default_profile_path).read_text())
        for entry in default_profile.get("syscalls", []):
            if entry.get("action") == "SCMP_ACT_ALLOW":
                syscalls.update(entry.get("names", []))
    except Exception as ex:
        print(f"[seccomp] WARNING: unable to read default profile {default_profile_path}: {ex}", file=sys.stderr)

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
  if ! compose config --format json >"${TMPDIR:-/tmp}/core_data_seccomp.json"; then
    echo "[seccomp] Unable to render compose configuration." >&2
    exit 1
  fi
  python3 - "${TMPDIR:-/tmp}/core_data_seccomp.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    config = json.load(fh)
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
