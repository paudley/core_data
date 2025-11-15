# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# shellcheck shell=bash

ci_log() {
	printf '[ci] %s\n' "$*" >&2
}

ci_load_env_file() {
	local file=$1
	if [[ ! -f "${file}" ]]; then
		echo "[ci] env file ${file} not found." >&2
		exit 1
	fi
	set -a
	# shellcheck disable=SC1090
	source "${file}"
	set +a
	ci_log "sourced ${file}"
}

ci_profile_enabled() {
	local profile=$1
	local profiles=${COMPOSE_PROFILES:-}
	if [[ -z "${profiles}" ]]; then
		return 1
	fi
	IFS=',' read -r -a profile_arr <<<"${profiles}"
	for item in "${profile_arr[@]}"; do
		if [[ "${item}" == "${profile}" ]]; then
			return 0
		fi
	done
	return 1
}

ci_service_images() {
	local -a entries=()
	local registry=${CORE_DATA_STACK_REGISTRY:-}
	if [[ -z "${registry}" && -n "${POSTGRES_IMAGE_NAME:-}" ]]; then
		registry=${POSTGRES_IMAGE_NAME%/*}
	fi
	if [[ -z "${registry}" && -n "${CORE_DATA_IMAGE:-}" ]]; then
		registry=${CORE_DATA_IMAGE%/*}
	fi
	local release_tag=${CORE_DATA_STACK_TAG:-${POSTGRES_IMAGE_TAG:-${CORE_DATA_TAG:-latest}}}
	local registry_default=${registry:-ghcr.io/paudley/core_data}
	local postgres_image="${POSTGRES_IMAGE_NAME:-${registry_default}/postgres}:${POSTGRES_IMAGE_TAG:-${release_tag}}"
	local valkey_default="${registry_default}/valkey:${release_tag}"
	local rabbitmq_default="${registry_default}/rabbitmq:${release_tag}"
	local pgbouncer_default="${registry_default}/pgbouncer:${release_tag}"
	local memcached_default="${registry_default}/memcached:${release_tag}"
	local pghero_default="${registry_default}/pghero:${release_tag}"
	entries+=("postgres=${postgres_image}")
	entries+=("logical_backup=${postgres_image}")
	entries+=("volume_prep=${postgres_image}")
	entries+=("network_probe=${NETWORK_PROBE_IMAGE:-debian:bookworm-slim}")
	entries+=("network_guard=${NETWORK_GUARD_IMAGE:-debian:bookworm-slim}")
	entries+=("valkey=${VALKEY_IMAGE:-${valkey_default}}")
	entries+=("rabbitmq=${RABBITMQ_IMAGE:-${rabbitmq_default}}")
	entries+=("pgbouncer=${PGBOUNCER_IMAGE:-${pgbouncer_default}}")
	entries+=("memcached=${MEMCACHED_IMAGE:-${memcached_default}}")
	entries+=("pghero=${PGHERO_IMAGE:-${pghero_default}}")
	printf '%s\n' "${entries[@]}"
}

ci_verify_attestation_for_image() {
	local image_ref=$1
	local enforce=$2
	local repo=${CORE_DATA_ATTESTATION_REPO:-paudley/core_data}
	local subject="${image_ref}"
	if [[ "${subject}" != oci://* ]]; then
		subject="oci://${subject}"
	fi
	local normalized=${subject#oci://}
	if [[ "${normalized}" != ghcr.io/* ]]; then
		ci_log "skipping attestation for ${image_ref}; only ghcr.io images are supported."
		return 0
	fi
	local repo_prefix=""
	if [[ -n "${repo}" ]]; then
		repo_prefix="ghcr.io/${repo}"
	fi
	if [[ -n "${repo_prefix}" && "${normalized}" != "${repo_prefix}"* ]]; then
		ci_log "skipping attestation for ${image_ref}; expected prefix ${repo_prefix}."
		return 0
	fi
	local expected_subject=${normalized%%@*}
	expected_subject=${expected_subject%%:*}
	if ! command -v gh >/dev/null 2>&1; then
		if [[ "${enforce}" == "1" ]]; then
			echo "[ci] gh CLI missing; cannot verify attestation for ${image_ref}" >&2
			return 1
		fi
		ci_log "gh CLI missing; skipping attestation check for ${image_ref}"
		return 0
	fi
	local tmp_json
	local tmp_err
	local parse_err="/dev/null"
	tmp_json=$(mktemp)
	tmp_err=$(mktemp)
	parse_err=$(mktemp)
	local err_msg=""
	local attempt=1
	while :; do
		if [[ "${attempt}" -eq 2 ]]; then
			GH_TOKEN= GITHUB_TOKEN= gh attestation verify "${subject}" --repo "${repo}" --format json >"${tmp_json}" 2>"${tmp_err}"
		else
			gh attestation verify "${subject}" --repo "${repo}" --format json >"${tmp_json}" 2>"${tmp_err}"
		fi
		if [[ $? -eq 0 ]]; then
			break
		fi
		err_msg=$(<"${tmp_err}")
		if [[ "${attempt}" -eq 1 && -n "${err_msg}" && "${err_msg}" == *"token was denied access"* && ( -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ) ]]; then
			ci_log "gh token denied access for ${image_ref}; retrying without GH_TOKEN/GITHUB_TOKEN."
			attempt=$((attempt + 1))
			: >"${tmp_err}"
			continue
		fi
		# If we've already retried once, break to error handling.
		if [[ "${attempt}" -ge 2 ]]; then
			break
		fi
		rm -f "${tmp_json}" "${tmp_err}" "${parse_err}"
		if [[ "${enforce}" == "1" ]]; then
			echo "[ci] attestation verification failed for ${image_ref}" >&2
			if [[ -n "${err_msg}" ]]; then
				echo "${err_msg}" >&2
			fi
			return 1
		fi
		ci_log "warning: attestation verification failed for ${image_ref}${err_msg:+: ${err_msg}}; continuing because enforcement disabled."
		return 0
	done
	rm -f "${tmp_err}"
	if [[ ! -s "${tmp_json}" ]]; then
		local empty_msg="gh attestation verify returned no payload for ${image_ref}"
		rm -f "${tmp_json}" "${parse_err}"
		if [[ "${enforce}" == "1" ]]; then
			echo "[ci] attestation verification failed for ${image_ref}" >&2
			echo "${empty_msg}" >&2
			return 1
		fi
		ci_log "warning: ${empty_msg}; continuing because enforcement disabled."
		return 0
	fi
	local parsed
	if ! parsed=$(
		python3 - "${expected_subject}" "${tmp_json}" <<'PY'
import json
import sys

if len(sys.argv) != 3:
    print("internal usage error: expected subject and json path", file=sys.stderr)
    sys.exit(1)

expected = sys.argv[1]
json_path = sys.argv[2]

try:
    with open(json_path, "r", encoding="utf-8") as fh:
        raw = fh.read()
except OSError as exc:
    print(f"unable to read attestation payload: {exc}", file=sys.stderr)
    sys.exit(1)

raw = raw.strip()
if not raw:
    print("attestation payload empty", file=sys.stderr)
    sys.exit(1)

try:
    payload = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"failed to parse attestation payload: {exc}", file=sys.stderr)
    sys.exit(1)

match_entry = None
match_subject = None
for entry in payload:
    result = entry.get("verificationResult", {})
    statement = result.get("statement", {})
    for subject in statement.get("subject") or []:
        if subject.get("name") == expected:
            match_entry = entry
            match_subject = subject
            break
    if match_entry is not None:
        break

if match_entry is None or match_subject is None:
    print(f"Subject {expected} not present in attestation payload.", file=sys.stderr)
    sys.exit(1)

statement = match_entry["verificationResult"]["statement"]
predicate_type = statement.get("predicateType")
if predicate_type != "https://slsa.dev/provenance/v1":
    print(f"Unexpected predicate type: {predicate_type}", file=sys.stderr)
    sys.exit(1)

subject_digest = match_subject.get("digest", {}).get("sha256")
if not subject_digest:
    print("Attestation missing subject digest.", file=sys.stderr)
    sys.exit(1)

predicate = statement.get("predicate", {})
build_def = predicate.get("buildDefinition", {})
external = build_def.get("externalParameters", {}) if build_def else {}
workflow = external.get("workflow", {}) if isinstance(external, dict) else {}
run_details = predicate.get("runDetails", {})
builder_id = (run_details.get("builder", {}) or {}).get("id", "")
invocation = (run_details.get("metadata", {}) or {}).get("invocationId", "")

workflow_repo = workflow.get("repository", "")
workflow_path = workflow.get("path", "")
workflow_ref = workflow.get("ref", "")

print(f"subject_name={match_subject.get('name', '')}")
print(f"subject_digest=sha256:{subject_digest}")
print(f"predicate_type={predicate_type}")
if builder_id:
    print(f"builder_id={builder_id}")
if invocation:
    print(f"invocation={invocation}")
if workflow_repo:
    print(f"workflow_repo={workflow_repo}")
if workflow_path:
    print(f"workflow_path={workflow_path}")
if workflow_ref:
    print(f"workflow_ref={workflow_ref}")
PY
	) 2>"${parse_err}"; then
		local py_err_msg
		py_err_msg=$(<"${parse_err}")
		rm -f "${tmp_json}" "${parse_err}"
		if [[ "${enforce}" == "1" ]]; then
			echo "[ci] attestation verification failed for ${image_ref}" >&2
			if [[ -n "${py_err_msg}" ]]; then
				echo "${py_err_msg}" >&2
			fi
			return 1
		fi
		ci_log "warning: attestation verification failed for ${image_ref}${py_err_msg:+: ${py_err_msg}}; continuing because enforcement disabled."
		return 0
	fi
	rm -f "${parse_err}"
	rm -f "${tmp_json}"
	local subject_name=""
	local subject_digest=""
	local predicate_type=""
	local builder_id=""
	local invocation=""
	local workflow_repo=""
	local workflow_path=""
	local workflow_ref=""
	while IFS= read -r line; do
		local key=${line%%=*}
		local value=${line#"${key}="}
		case "${key}" in
		subject_name)
			subject_name=${value}
			;;
		subject_digest)
			subject_digest=${value}
			;;
		predicate_type)
			predicate_type=${value}
			;;
		builder_id)
			builder_id=${value}
			;;
		invocation)
			invocation=${value}
			;;
		workflow_repo)
			workflow_repo=${value}
			;;
		workflow_path)
			workflow_path=${value}
			;;
		workflow_ref)
			workflow_ref=${value}
			;;
		esac
	done <<<"${parsed}"
	ci_log "attestation verified for ${image_ref}"
	if [[ -n "${subject_name}" && -n "${subject_digest}" ]]; then
		ci_log "  subject    : ${subject_name}@${subject_digest}"
	fi
	if [[ -n "${predicate_type}" ]]; then
		ci_log "  predicate  : ${predicate_type}"
	fi
	if [[ -n "${builder_id}" ]]; then
		ci_log "  builder    : ${builder_id}"
	fi
	if [[ -n "${workflow_repo}" || -n "${workflow_path}" || -n "${workflow_ref}" ]]; then
		local workflow_summary="${workflow_repo}"
		if [[ -n "${workflow_path}" ]]; then
			if [[ -n "${workflow_summary}" ]]; then
				workflow_summary+=" "
			fi
			workflow_summary+="${workflow_path}"
		fi
		if [[ -n "${workflow_ref}" ]]; then
			workflow_summary+=" (${workflow_ref})"
		fi
		ci_log "  workflow   : ${workflow_summary}"
	fi
	if [[ -n "${invocation}" ]]; then
		ci_log "  run        : ${invocation}"
	fi
	return 0
}

ci_verify_attestations() {
	local skip=$1
	local enforce_flag=$2
	if [[ "${skip}" == "true" ]]; then
		if [[ "${enforce_flag:-0}" == "1" ]]; then
			ci_log "attestation skip requested; ignoring --require-attestation to avoid conflicting flags"
		fi
		return 0
	fi
	local enforce_raw=${enforce_flag:-${CORE_DATA_REQUIRE_ATTESTATION:-0}}
	local enforce=0
	case "${enforce_raw}" in
	1 | true | yes)
		enforce=1
		;;
	*)
		enforce=0
		;;
	esac
	local -A seen=()
	while IFS='=' read -r service image_ref; do
		if [[ -z "${service}" || -z "${image_ref}" ]]; then
			continue
		fi
		if [[ "${service}" == "valkey" ]] && ! ci_profile_enabled "valkey"; then
			continue
		fi
		if [[ "${service}" == "rabbitmq" ]] && ! ci_profile_enabled "rabbitmq"; then
			continue
		fi
		if [[ "${service}" == "pgbouncer" ]] && ! ci_profile_enabled "pgbouncer"; then
			continue
		fi
		if [[ "${service}" == "memcached" ]] && ! ci_profile_enabled "memcached"; then
			continue
		fi
		if [[ -n "${seen[${image_ref}]:-}" ]]; then
			continue
		fi
		seen["${image_ref}"]=1
		if ! ci_verify_attestation_for_image "${image_ref}" "${enforce}"; then
			return 1
		fi
	done < <(ci_service_images)
	return 0
}

ci_check_disk_space() {
	local min_mb=${1:-4096}
	local available
	available=$(df -Pm "${ROOT_DIR}" | awk 'NR==2 {print $4}')
	if [[ -z "${available}" ]]; then
		ci_log "unable to determine disk space; skipping check"
		return 0
	fi
	if ((available < min_mb)); then
		echo "[ci] insufficient disk space in ${ROOT_DIR}: ${available}MB available, ${min_mb}MB required." >&2
		return 1
	fi
	ci_log "disk space check OK (${available}MB available)."
}

ci_port_available() {
	local port=$1
	python3 - "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

port = int(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        sys.exit(1)
sys.exit(0)
PY
}

ci_check_ports() {
	local skip=$1
	shift
	if [[ "${skip}" == "true" ]]; then
		return 0
	fi
	local failures=0
	for mapping in "$@"; do
		local name=${mapping%%:*}
		local port=${mapping##*:}
		if [[ -z "${port}" ]]; then
			continue
		fi
		if ! ci_port_available "${port}"; then
			echo "[ci] port ${port} for ${name} appears to be in use." >&2
			failures=$((failures + 1))
		else
			ci_log "port ${port} for ${name} available."
		fi
	done
	if ((failures > 0)); then
		return 1
	fi
	return 0
}

ci_emit_outputs() {
	local output_path=$1
	python3 - "$output_path" <<'PY'
import json
import os
import sys

output = sys.argv[1]
root_dir = os.environ.get("ROOT_DIR", os.getcwd())
data = {
    "composeProfiles": os.environ.get("COMPOSE_PROFILES", ""),
    "services": {
        "postgres": {
            "host": os.environ.get("POSTGRES_HOST", "127.0.0.1"),
            "port": int(os.environ.get("POSTGRES_PORT", "5432")),
            "superuser": os.environ.get("POSTGRES_SUPERUSER", "postgres"),
            "passwordFile": os.path.relpath(os.environ.get("POSTGRES_SUPERUSER_PASSWORD_FILE", "secrets/postgres_superuser_password"), start=root_dir),
        },
        "pgbouncer": {
            "host": os.environ.get("PGBOUNCER_HOST", "127.0.0.1"),
            "port": int(os.environ.get("PGBOUNCER_HOST_PORT", os.environ.get("PGBOUNCER_PORT", "6432"))),
        },
        "valkey": {
            "host": os.environ.get("VALKEY_HOST", "127.0.0.1"),
            "port": int(os.environ.get("VALKEY_HOST_PORT", os.environ.get("VALKEY_PORT", "6379"))),
            "passwordFile": os.path.relpath(os.environ.get("VALKEY_PASSWORD_FILE", "secrets/valkey_password"), start=root_dir),
        },
    },
}
data["services"]["pghero"] = {
    "enabled": os.environ.get("PGHERO_DISABLED", "0") != "1",
    "port": int(os.environ.get("PGHERO_PORT", "8080")),
}
out_dir = os.path.dirname(output) or "."
os.makedirs(out_dir, exist_ok=True)
with open(output, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
print(output)
PY
}

ci_run_bootstrap() {
	if [[ "${1:-}" == "true" ]]; then
		ci_log "bootstrap skipped (per flag)."
		return 0
	fi
	cmd_bootstrap_ci
}

cmd_ci_verify() {
	local min_disk_mb=${CORE_DATA_CI_MIN_DISK_MB:-4096}
	local skip_attestation=false
	local skip_docker=false
	local skip_ports=false
	local require_attestation=false
	local env_files=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--min-disk-mb)
			min_disk_mb=$2
			shift 2
			;;
		--min-disk-mb=*)
			min_disk_mb=${1#*=}
			shift
			;;
		--skip-attestation)
			skip_attestation=true
			shift
			;;
		--require-attestation)
			require_attestation=true
			shift
			;;
		--skip-docker)
			skip_docker=true
			shift
			;;
		--skip-ports)
			skip_ports=true
			shift
			;;
		--env-file)
			env_files+=("$2")
			shift 2
			;;
		--env-file=*)
			env_files+=("${1#*=}")
			shift
			;;
		-h | --help)
			cat <<'USAGE'
Usage: manage.sh ci-verify [options]
  --env-file PATH        Source environment variables before checks.
  --min-disk-mb N        Minimum free space required (default 4096).
  --skip-docker          Skip docker availability check.
  --skip-attestation     Skip image attestation verification.
  --require-attestation  Fail if attestations cannot be verified.
  --skip-ports           Do not check host port availability.
USAGE
			return 0
			;;
		*)
			echo "[ci] Unknown option: $1" >&2
			return 1
			;;
		esac
	done
	for file in "${env_files[@]}"; do
		ci_load_env_file "${file}"
	done
	if [[ "${skip_docker}" != "true" ]]; then
		ensure_compose
	fi
	if ! ci_check_disk_space "${min_disk_mb}"; then
		return 1
	fi
	if ! ci_check_ports "${skip_ports}" \
		"postgres:${POSTGRES_PORT:-5432}" \
		"pgbouncer:${PGBOUNCER_HOST_PORT:-${PGBOUNCER_PORT:-6432}}" \
		"valkey:${VALKEY_HOST_PORT:-${VALKEY_PORT:-6379}}" \
		"rabbitmq:${RABBITMQ_HOST_PORT:-${RABBITMQ_PORT:-5672}}" \
		"pghero:${PGHERO_PORT:-8080}"; then
		return 1
	fi
	if ! ci_verify_attestations "${skip_attestation}" "${require_attestation}"; then
		return 1
	fi
	ci_log "ci-verify checks passed."
}

cmd_attestation_verify() {
	local env_files=()
	local compose_profiles=${CI_COMPOSE_PROFILES:-}
	local warn_only=false
	local extra_images=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--env-file)
			env_files+=("$2")
			shift 2
			;;
		--env-file=*)
			env_files+=("${1#*=}")
			shift
			;;
		--profiles)
			compose_profiles=$2
			shift 2
			;;
		--profiles=*)
			compose_profiles=${1#*=}
			shift
			;;
		--image)
			extra_images+=("$2")
			shift 2
			;;
		--image=*)
			extra_images+=("${1#*=}")
			shift
			;;
		--warn-only)
			warn_only=true
			shift
			;;
		-h | --help)
			cat <<'USAGE'
Usage: manage.sh attestation-verify [options]
  --env-file PATH        Source environment variables before checking images.
  --profiles list        Override COMPOSE_PROFILES for this invocation.
  --image REF            Verify an additional image (can be repeated).
  --warn-only            Print warnings instead of failing on errors.
USAGE
			return 0
			;;
		*)
			echo "[ci] Unknown option: $1" >&2
			return 1
			;;
		esac
	done
	for file in "${env_files[@]}"; do
		ci_load_env_file "${file}"
	done
	if [[ -n "${compose_profiles}" ]]; then
		export COMPOSE_PROFILES="${compose_profiles}"
	fi
	local enforce=1
	if [[ "${warn_only}" == "true" ]]; then
		enforce=0
	fi
	if ! ci_verify_attestations "false" "${enforce}"; then
		return 1
	fi
	for image in "${extra_images[@]}"; do
		if ! ci_verify_attestation_for_image "${image}" "${enforce}"; then
			return 1
		fi
	done
	ci_log "attestation verification completed."
}

cmd_ci_up() {
	local dry_run=false
	local skip_bootstrap=false
	local skip_attestation=false
	local require_attestation=false
	local output_path=${CORE_DATA_CI_OUTPUT_PATH:-${ROOT_DIR}/backups/ci-output.json}
	local env_files=()
	local compose_profiles=${CI_COMPOSE_PROFILES:-}

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--skip-bootstrap)
			skip_bootstrap=true
			shift
			;;
		--skip-attestation)
			skip_attestation=true
			shift
			;;
		--require-attestation)
			require_attestation=true
			shift
			;;
		--output)
			output_path=$2
			shift 2
			;;
		--output=*)
			output_path=${1#*=}
			shift
			;;
		--profiles)
			compose_profiles=$2
			shift 2
			;;
		--profiles=*)
			compose_profiles=${1#*=}
			shift
			;;
		--env-file)
			env_files+=("$2")
			shift 2
			;;
		--env-file=*)
			env_files+=("${1#*=}")
			shift
			;;
		-h | --help)
			cat <<'USAGE'
Usage: manage.sh ci-up [options]
  --env-file PATH        Source environment variables before running.
  --profiles list        Override COMPOSE_PROFILES for this invocation.
  --dry-run              Print actions without touching Docker.
  --skip-bootstrap       Skip secret/directory generation.
  --skip-attestation     Do not verify image attestations.
  --require-attestation  Fail if attestation verification fails.
  --output PATH          Write JSON summary to PATH (default backups/ci-output.json).
USAGE
			return 0
			;;
		*)
			echo "[ci] Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	for file in "${env_files[@]}"; do
		ci_load_env_file "${file}"
	done

	if [[ -n "${compose_profiles}" ]]; then
		export COMPOSE_PROFILES="${compose_profiles}"
	fi

	if ! ci_verify_attestations "${skip_attestation}" "${require_attestation}"; then
		return 1
	fi

	if [[ "${dry_run}" == "true" ]]; then
		ci_log "dry-run: bootstrap, compose up, and health checks skipped."
		ci_emit_outputs "${output_path}" >/dev/null
		return 0
	fi

	ensure_compose
	if ! ci_run_bootstrap "${skip_bootstrap}"; then
		return 1
	fi

	if [[ "${CORE_DATA_BUILD_IMAGE:-0}" == "1" ]]; then
		build_postgres_image
	fi

	ci_log "bringing stack online via docker compose up -d"
	if ! compose up -d; then
		return 1
	fi
	if ! wait_for_service_healthy "${POSTGRES_SERVICE_NAME:-postgres}" "${POSTGRES_HEALTH_TIMEOUT:-180}" 2; then
		echo "[ci] postgres failed to pass health check." >&2
		return 1
	fi
	if ! ensure_bootstrap_complete; then
		return 1
	fi
	if ! stabilize_postgres; then
		return 1
	fi

	ci_emit_outputs "${output_path}" >/dev/null
	ci_log "ci-up complete. Connection metadata written to ${output_path}"
}

cmd_ci_down() {
	local prune_data=false
	local prune_secrets=false
	local remove_volumes=false
	local env_files=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--prune-data)
			prune_data=true
			shift
			;;
		--prune-secrets)
			prune_secrets=true
			shift
			;;
		--volumes | -v)
			remove_volumes=true
			shift
			;;
		--env-file)
			env_files+=("$2")
			shift 2
			;;
		--env-file=*)
			env_files+=("${1#*=}")
			shift
			;;
		-h | --help)
			cat <<'USAGE'
Usage: manage.sh ci-down [options]
  --volumes              Pass -v to docker compose down.
  --prune-data           Remove data/* directories (dangerous; CI use only).
  --prune-secrets        Remove secrets/* files.
  --env-file PATH        Source env file before running.
USAGE
			return 0
			;;
		*)
			echo "[ci] Unknown option: $1" >&2
			return 1
			;;
		esac
	done

	for file in "${env_files[@]}"; do
		ci_load_env_file "${file}"
	done

	if ! command -v docker >/dev/null 2>&1; then
		ci_log "docker CLI not available; skipping compose down."
	else
		local args=(down)
		if [[ "${remove_volumes}" == "true" ]]; then
			args+=("-v")
		fi
		compose "${args[@]}" || true
	fi

	if [[ "${prune_data}" == "true" ]]; then
		rm -rf "${ROOT_DIR}/data/"*
		ci_log "pruned data directory."
	fi
	if [[ "${prune_secrets}" == "true" ]]; then
		rm -f "${ROOT_DIR}/secrets/"*
		ci_log "pruned secrets directory."
	fi
	ci_log "ci-down complete."
}
