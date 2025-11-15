#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Common helpers shared by manage.sh and supporting scripts.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMPOSE_BIN=${COMPOSE_BIN:-docker compose}
POSTGRES_SERVICE_NAME=${POSTGRES_SERVICE_NAME:-postgres}
PG_CONTAINER=${PG_CONTAINER:-${POSTGRES_SERVICE_NAME}}
ENV_FILE=${ENV_FILE:-${ROOT_DIR}/.env}
PGBACKREST_CONF=${PGBACKREST_CONF:-/var/lib/postgresql/data/pgbackrest.conf}
POSTGRES_HOST=${POSTGRES_HOST:-localhost}
POSTGRES_EXEC_USER=${POSTGRES_EXEC_USER:-postgres}
CORE_DATA_BOOTSTRAP_SENTINEL=${CORE_DATA_BOOTSTRAP_SENTINEL:-/var/lib/postgresql/data/.core_data_bootstrap_complete}
CORE_DATA_HEALTH_GUARD_SERVICES=${CORE_DATA_HEALTH_GUARD_SERVICES:-"postgres pgbouncer pghero"}
case "${CORE_DATA_SELECTED_COMMAND:-}" in
ci-up | ci-down | ci-verify | bootstrap-ci)
	default_require_env=0
	;;
*)
	default_require_env=1
	;;
esac
CORE_DATA_REQUIRE_ENV_FILE=${CORE_DATA_REQUIRE_ENV_FILE:-${default_require_env}}

if [[ -f "${ENV_FILE}" ]]; then
	set -a
	# shellcheck source=/dev/null
	source "${ENV_FILE}"
	set +a
else
	if [[ "${CORE_DATA_REQUIRE_ENV_FILE}" == "1" ]]; then
		echo "[core_data] WARNING: ${ENV_FILE} not found; using defaults where possible." >&2
	fi
fi

POSTGRES_SUPERUSER_PASSWORD_FILE=${POSTGRES_SUPERUSER_PASSWORD_FILE:-${ROOT_DIR}/secrets/postgres_superuser_password}
VALKEY_PASSWORD_FILE=${VALKEY_PASSWORD_FILE:-${ROOT_DIR}/secrets/valkey_password}
PGBOUNCER_AUTH_PASSWORD_FILE=${PGBOUNCER_AUTH_PASSWORD_FILE:-${ROOT_DIR}/secrets/pgbouncer_auth_password}
PGBOUNCER_STATS_PASSWORD_FILE=${PGBOUNCER_STATS_PASSWORD_FILE:-${ROOT_DIR}/secrets/pgbouncer_stats_password}
RABBITMQ_DEFAULT_PASS_FILE=${RABBITMQ_DEFAULT_PASS_FILE:-${ROOT_DIR}/secrets/rabbitmq_default_pass}
RABBITMQ_ERLANG_COOKIE_FILE=${RABBITMQ_ERLANG_COOKIE_FILE:-${ROOT_DIR}/secrets/rabbitmq_erlang_cookie}

HOST_UID=$(id -u)
HOST_GID=$(id -g)
POSTGRES_UID=${POSTGRES_UID:-${HOST_UID}}
POSTGRES_GID=${POSTGRES_GID:-${HOST_GID}}
POSTGRES_RUNTIME_USER=${POSTGRES_RUNTIME_USER:-postgres}
POSTGRES_RUNTIME_GECOS=${POSTGRES_RUNTIME_GECOS:-"Core Data PostgreSQL"}
POSTGRES_RUNTIME_HOME=${POSTGRES_RUNTIME_HOME:-/home/postgres}
export POSTGRES_UID POSTGRES_GID POSTGRES_RUNTIME_USER POSTGRES_RUNTIME_GECOS POSTGRES_RUNTIME_HOME

load_secret_from_file() {
	local var_name=$1
	local file_var_name="${var_name}_FILE"
	local current_value="${!var_name-}"
	local file_path="${!file_var_name-}"

	if [[ -n "${current_value}" ]]; then
		return
	fi

	if [[ -n "${file_path}" ]]; then
		if [[ -r "${file_path}" ]]; then
			local secret
			secret=$(tr -d '\r\n' <"${file_path}")
			export "${var_name}=${secret}"
		else
			echo "[core_data] WARNING: unable to read ${file_var_name}=${file_path}" >&2
		fi
	fi
}

load_secret_from_file POSTGRES_SUPERUSER_PASSWORD
load_secret_from_file VALKEY_PASSWORD
load_secret_from_file PGBOUNCER_AUTH_PASSWORD
load_secret_from_file PGBOUNCER_STATS_PASSWORD
load_secret_from_file RABBITMQ_DEFAULT_PASS
load_secret_from_file RABBITMQ_ERLANG_COOKIE

compose_exec_service() {
	local service=$1
	shift
	compose exec -T "$service" "$@"
}

compose_has_service() {
	local service=$1
	compose config --services 2>/dev/null | grep -Fxq "${service}"
}

wait_for_service_healthy() {
	local service=$1
	local timeout=${2:-180}
	local poll_interval=${3:-2}
	local stable_window=${4:-5}
	if ! compose_has_service "${service}"; then
		echo "[core_data] Service '${service}' not defined; skipping health wait." >&2
		return 0
	fi
	local elapsed=0
	local announced=false
	local healthy_started=-1
	while ((elapsed <= timeout)); do
		local container_id
		container_id=$(compose ps -q "${service}" 2>/dev/null | head -n 1 || true)
		if [[ -z "${container_id}" ]]; then
			if [[ "${announced}" == false ]]; then
				echo "[core_data] Waiting for container '${service}' to start..." >&2
				announced=true
			fi
		else
			local status
			status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "${container_id}" 2>/dev/null || echo "missing")
			case "${status}" in
			healthy)
				if ((healthy_started < 0)); then
					healthy_started=${elapsed}
				elif (((elapsed - healthy_started) >= stable_window)); then
					if [[ "${announced}" == true ]]; then
						echo "[core_data] Service '${service}' is healthy." >&2
					fi
					return 0
				fi
				;;
			missing)
				echo "[core_data] Service '${service}' has no healthcheck; skipping health wait." >&2
				return 0
				;;
			unhealthy)
				echo "[core_data] Service '${service}' reported unhealthy status; continuing to wait (${elapsed}s elapsed)." >&2
				announced=true
				healthy_started=-1
				;;
			starting)
				if [[ "${announced}" == false ]]; then
					echo "[core_data] Waiting for service '${service}' healthcheck..." >&2
					announced=true
				fi
				healthy_started=-1
				;;
			*)
				echo "[core_data] Service '${service}' health status '${status}'; continuing to wait (${elapsed}s elapsed)." >&2
				announced=true
				healthy_started=-1
				;;
			esac
		fi
		sleep "${poll_interval}"
		elapsed=$((elapsed + poll_interval))
	done
	echo "[core_data] Service '${service}' did not become healthy within ${timeout}s." >&2
	return 1
}

ensure_bootstrap_complete() {
	local sentinel=${CORE_DATA_BOOTSTRAP_SENTINEL}
	if compose_exec bash -lc "[[ -f '${sentinel}' ]]" >/dev/null 2>&1; then
		return 0
	fi
	echo "[core_data] WARNING: bootstrap sentinel '${sentinel}' missing inside container; verifying cluster state." >&2
	if compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
		psql --host localhost --username "${POSTGRES_SUPERUSER:-postgres}" \
		--dbname "${POSTGRES_DB:-postgres}" --tuples-only --command "SELECT 1;" >/dev/null 2>&1; then
		if compose_exec bash -lc "touch '${sentinel}'" >/dev/null 2>&1; then
			echo "[core_data] Re-created bootstrap sentinel for existing data directory." >&2
			return 0
		fi
	fi
	echo "[core_data] PostgreSQL initialization appears incomplete; check container logs and rerun './scripts/manage.sh up'." >&2
	return 1
}

stabilize_postgres() {
	local required_stable=${POSTGRES_STABLE_WINDOW_SECONDS:-15}
	local max_window=${POSTGRES_STABILIZATION_TIMEOUT:-120}
	local db=${POSTGRES_DB:-postgres}
	local superuser=${POSTGRES_SUPERUSER:-postgres}
	local elapsed=0
	local consecutive=0
	while ((elapsed < max_window)); do
		if ! compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" pg_isready -h localhost -U "${superuser}" >/dev/null 2>&1; then
			echo "[core_data] PostgreSQL failed readiness check during stabilization window." >&2
			consecutive=0
		elif ! compose_exec env PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
			psql --host localhost --username "${superuser}" --dbname "${db}" --command "SELECT 1;" >/dev/null 2>&1; then
			echo "[core_data] PostgreSQL query probe failed while waiting for stability." >&2
			consecutive=0
		else
			consecutive=$((consecutive + 1))
			if ((consecutive >= required_stable)); then
				return 0
			fi
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	echo "[core_data] PostgreSQL did not remain stable for ${required_stable}s within ${max_window}s." >&2
	return 1
}

build_postgres_image() {
	local uid=${POSTGRES_UID:-${HOST_UID}}
	local gid=${POSTGRES_GID:-${HOST_GID}}
	local runtime_user=${POSTGRES_RUNTIME_USER:-postgres}
	local runtime_gecos=${POSTGRES_RUNTIME_GECOS:-"Core Data PostgreSQL"}
	local runtime_home=${POSTGRES_RUNTIME_HOME:-/home/${runtime_user}}
	local image_name=${POSTGRES_IMAGE_NAME:-core_data/postgres}
	local image_tag=${POSTGRES_IMAGE_TAG:-latest}
	local pg_version=${PG_VERSION:-17}
	local age_version=${AGE_VERSION:-master}

	echo "[core_data] Building PostgreSQL image ${image_name}:${image_tag} (PG ${pg_version}, AGE ${age_version})." >&2
	docker build \
		--build-arg CORE_UID="${uid}" \
		--build-arg CORE_GID="${gid}" \
		--build-arg CORE_USERNAME="${runtime_user}" \
		--build-arg CORE_GECOS="${runtime_gecos}" \
		--build-arg CORE_HOME="${runtime_home}" \
		--build-arg PG_VERSION="${pg_version}" \
		--build-arg AGE_VERSION="${age_version}" \
		-t "${image_name}:${image_tag}" \
		-f "${ROOT_DIR}/postgres/Dockerfile" \
		"${ROOT_DIR}"
}

# compose runs docker compose with the arguments provided.
compose() {
	${COMPOSE_BIN} "$@"
}

# compose_exec runs docker compose exec with the postgres user (no TTY).
compose_exec() {
	compose exec -T --user "${POSTGRES_EXEC_USER}" "${PG_CONTAINER}" "$@"
}

# compose_exec_interactive attaches a TTY for interactive sessions (e.g. psql shell).
compose_exec_interactive() {
	compose exec --user "${POSTGRES_EXEC_USER}" "${PG_CONTAINER}" "$@"
}

# compose_run runs docker compose run for ephemeral helper containers.
compose_run() {
	compose run --rm "$@"
}

# ensure_compose exits early if the docker CLI is not available.
ensure_compose() {
	if ! command -v docker >/dev/null 2>&1; then
		echo "[core_data] docker CLI not available." >&2
		exit 1
	fi
}

# ensure_env makes sure a populated .env file exists before continuing.
ensure_env() {
	if [[ ! -f "${ENV_FILE}" ]]; then
		if [[ "${CORE_DATA_REQUIRE_ENV_FILE}" == "1" ]]; then
			echo "[core_data] Missing .env file. Copy .env.example and customize before running commands." >&2
			exit 1
		fi
		return 0
	fi
}

ensure_postgres_running() {
	if ! compose_has_service "${POSTGRES_SERVICE_NAME}"; then
		echo "[core_data] Service '${POSTGRES_SERVICE_NAME}' not defined in docker-compose.yml." >&2
		exit 1
	fi
	local container_id
	container_id=$(compose ps -q "${POSTGRES_SERVICE_NAME}" 2>/dev/null || true)
	if [[ -z "${container_id}" ]]; then
		echo "[core_data] Postgres container is not running. Start it with './scripts/manage.sh up' first." >&2
		exit 1
	fi
	# Wait for PostgreSQL to be ready to accept connections
	local max_attempts=30
	local attempt=1
	while ! compose exec -T "${POSTGRES_SERVICE_NAME}" pg_isready -U "${POSTGRES_EXEC_USER}" >/dev/null 2>&1; do
		if ((attempt >= max_attempts)); then
			echo "[core_data] Postgres is running but not ready to accept connections after $((attempt)) attempts." >&2
			exit 1
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
}
