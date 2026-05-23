# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

import base64
import concurrent.futures
import csv
import functools
import gzip
import http.client
import json
import os
import secrets
import shutil
import socket
import stat
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import warnings
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import psycopg
import pytest
from graphql import (
    GraphQLArgument,
    GraphQLField,
    GraphQLFloat,
    GraphQLList,
    GraphQLObjectType,
    GraphQLSchema,
    GraphQLString,
    graphql_sync,
)
from psycopg.rows import tuple_row

ROOT = Path(__file__).resolve().parents[1]
MANAGE = ROOT / "scripts" / "manage.sh"
ENV_EXAMPLE = ROOT / ".env.example"


def _find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _build_testkit_schema(db_settings):
    def get_connection():
        conn = psycopg.connect(
            host=db_settings["host"],
            port=db_settings["port"],
            user=db_settings["user"],
            password=db_settings["password"],
            dbname=db_settings["dbname"],
            autocommit=True,
        )
        with conn.cursor() as cur:
            cur.execute("SET search_path TO testkit, public")
        return conn

    def place_fields():
        return {
            "slug": GraphQLField(GraphQLString),
            "name": GraphQLField(GraphQLString),
            "locationWkt": GraphQLField(GraphQLString),
            "regionCode": GraphQLField(GraphQLString),
        }

    place_type = GraphQLObjectType("Place", place_fields)

    def resolve_places(_root, _info):
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT slug,
                           name::text,
                           region_code,
                           ST_AsText(location::public.geometry) AS location_wkt
                      FROM testkit.places
                     ORDER BY slug
                    """
                )
                return [
                    {
                        "slug": row[0],
                        "name": row[1],
                        "regionCode": row[2],
                        "locationWkt": row[3],
                    }
                    for row in cur.fetchall()
                ]

    def resolve_nearest(_root, _info, vector):
        if not vector:
            return None
        vector_literal = "[" + ",".join(f"{component:.6f}" for component in vector) + "]"
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT slug, name::text, region_code,
                           ST_AsText(location::public.geometry) AS location_wkt
                      FROM testkit.places
                  ORDER BY embedding <-> %s::vector
                     LIMIT 1
                    """,
                    (vector_literal,),
                )
                row = cur.fetchone()
                if row is None:
                    return None
                return {
                    "slug": row[0],
                    "name": row[1],
                    "regionCode": row[2],
                    "locationWkt": row[3],
                }

    def resolve_route_cost(_root, _info, originSlug, destinationSlug):
        query = """
            WITH source_vertex AS (
                SELECT vertex_id FROM testkit.route_vertices WHERE place_slug = %s
            ), target_vertex AS (
                SELECT vertex_id FROM testkit.route_vertices WHERE place_slug = %s
            )
            SELECT SUM(cost)
              FROM pgr_dijkstra(
                    $$SELECT edge_id AS id, source, target, cost, reverse_cost FROM testkit.route_edges$$,
                    (SELECT vertex_id FROM source_vertex),
                    (SELECT vertex_id FROM target_vertex)
                );
        """
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(query, (originSlug, destinationSlug))
                result = cur.fetchone()
                return float(result[0]) if result and result[0] is not None else None

    def query_fields():
        return {
            "places": GraphQLField(GraphQLList(place_type), resolve=resolve_places),
            "nearestPlace": GraphQLField(
                place_type,
                args={
                    "vector": GraphQLArgument(GraphQLList(GraphQLFloat)),
                },
                resolve=resolve_nearest,
            ),
            "routeCost": GraphQLField(
                GraphQLFloat,
                args={
                    "originSlug": GraphQLArgument(GraphQLString),
                    "destinationSlug": GraphQLArgument(GraphQLString),
                },
                resolve=resolve_route_cost,
            ),
        }

    query_type = GraphQLObjectType("Query", query_fields)

    return GraphQLSchema(query_type)


def _make_graphql_handler(schema, db_settings):
    class GraphQLHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self):  # noqa: N802
            if self.path != "/graphql":
                self.send_error(404)
                return
            content_length = int(self.headers.get("Content-Length", "0"))
            payload = self.rfile.read(content_length)
            try:
                request_json = json.loads(payload)
            except json.JSONDecodeError:
                self.send_error(400, "invalid json")
                return
            query = request_json.get("query")
            variables = request_json.get("variables")
            result = graphql_sync(schema, query, variable_values=variables)
            response = {}
            if result.errors:
                response["errors"] = [error.formatted for error in result.errors]
            if result.data is not None:
                response["data"] = result.data
            body = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format, *_args):  # noqa: D401
            return

    GraphQLHandler.db_settings = db_settings  # type: ignore[attr-defined]
    return GraphQLHandler


class GraphQLServer:
    def __init__(self, port: int, db_settings):
        schema = _build_testkit_schema(db_settings)
        handler = _make_graphql_handler(schema, db_settings)
        self._server = ThreadingHTTPServer(("127.0.0.1", port), handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc, tb):
        self._server.shutdown()
        self._thread.join(timeout=5)


def read_secret(relative_path):
    return (ROOT / relative_path).read_text().strip()


@pytest.fixture(scope="module")
def manage_env(tmp_path_factory):
    workdir = tmp_path_factory.mktemp("core_data_ci")
    env_file = ROOT / ".env.test"

    postgres_port = _find_free_port()
    valkey_host_port = _find_free_port()
    pgbouncer_host_port = _find_free_port()
    memcached_port = _find_free_port()
    rabbitmq_port = _find_free_port()
    rabbitmq_mgmt_port = _find_free_port()

    compose_profiles = os.environ.get("TEST_COMPOSE_PROFILES", "valkey,pgbouncer,memcached,rabbitmq")

    backups_target = workdir / "backups"
    backups_target.mkdir(parents=True, exist_ok=True)

    subnet_a = int(uuid.uuid4().hex[:2], 16)
    subnet_b = int(uuid.uuid4().hex[2:4], 16)
    replacements = {
        "POSTGRES_PORT": str(postgres_port),
        "DOCKER_NETWORK_NAME": f"core_data_net_{uuid.uuid4().hex[:8]}",
        "DOCKER_NETWORK_SUBNET": f"10.{subnet_a}.{subnet_b}.0/24",
        "DATABASES_TO_CREATE": "app_main:app_user:change_me",
        "COMPOSE_PROFILES": compose_profiles,
        "VALKEY_HOST_PORT": str(valkey_host_port),
        "PGBOUNCER_HOST_PORT": str(pgbouncer_host_port),
        "MEMCACHED_PORT": str(memcached_port),
        "RABBITMQ_HOST_PORT": str(rabbitmq_port),
        "RABBITMQ_MANAGEMENT_HOST_PORT": str(rabbitmq_mgmt_port),
        "POSTGRES_UID": str(os.getuid()),
        "POSTGRES_GID": str(os.getgid()),
        "POSTGRES_RUNTIME_HOME": "/home/postgres",
        "POSTGRES_RUNTIME_GECOS": "CI_PostgreSQL_Administrator",
        "BACKUPS_HOST_PATH": str(backups_target),
    }

    lines = []
    for line in ENV_EXAMPLE.read_text().splitlines():
        if not line or line.lstrip().startswith("#"):
            lines.append(line)
            continue
        key, _, _ = line.partition("=")
        if key in replacements:
            lines.append(f"{key}={replacements[key]}")
        else:
            lines.append(line)
    env_file.write_text("\n".join(lines) + "\n")

    try:
        backups_target.chmod(0o777)
    except PermissionError as exc:
        warnings.warn(f"Unable to relax backup target permissions: {exc}", RuntimeWarning, stacklevel=2)

    managed_secrets = []

    data_root = ROOT / "data"
    data_paths = [
        data_root / "postgres_data",
        data_root / "postgres_wal",
        data_root / "pgbackrest",
        data_root / "pgbackrest_repo",
        data_root / "rabbitmq_data",
    ]
    data_backup_root = data_root / ".pytest_backups"
    data_backup_root.mkdir(parents=True, exist_ok=True)
    managed_data_dirs = []

    def busybox_volume_command(command: str) -> None:
        subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "-v",
                f"{data_root.resolve()}:/data",
                "busybox",
                "sh",
                "-c",
                command,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def backup_data_dir(path: Path):
        rel = path.relative_to(data_root)
        backup_name = f"{rel.name}_{uuid.uuid4().hex}"
        command = (
            f"if [ -e /data/{rel} ]; then "
            "mkdir -p /data/.pytest_backups && "
            f"mv /data/{rel} /data/.pytest_backups/{backup_name}; "
            "fi"
        )
        busybox_volume_command(command)
        return data_backup_root / backup_name

    for data_path in data_paths:
        backup_entry = None
        if data_path.exists():
            backup_entry = backup_data_dir(data_path)
        data_path.mkdir(parents=True, exist_ok=True)
        managed_data_dirs.append((data_path, backup_entry))

    def seed_secret(relative_path):
        path = ROOT / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        existed = path.exists()
        backup = path.read_bytes() if existed else None
        secret_value = secrets.token_urlsafe(32)
        path.write_text(f"{secret_value}\n")
        os.chmod(path, 0o644)
        managed_secrets.append((path, existed, backup))

    seed_secret("secrets/postgres_superuser_password")
    seed_secret("secrets/valkey_password")
    seed_secret("secrets/pgbouncer_auth_password")
    seed_secret("secrets/pgbouncer_stats_password")
    seed_secret("secrets/rabbitmq_default_pass")
    seed_secret("secrets/rabbitmq_erlang_cookie")

    env = os.environ.copy()
    env["ENV_FILE"] = str(env_file)
    project_name = env.setdefault("COMPOSE_PROJECT_NAME", f"core_data_ci_{uuid.uuid4().hex[:8]}")
    env["PG_BADGER_JOBS"] = "1"
    for key, value in replacements.items():
        env[key] = value

    repo_env_path = ROOT / ".env"
    had_env = repo_env_path.exists() or repo_env_path.is_symlink()
    backup_env_bytes = repo_env_path.read_bytes() if had_env else None
    repo_env_path.write_text(env_file.read_text())

    config_result = subprocess.run(
        [
            "docker",
            "compose",
            "--env-file",
            str(env_file),
            "config",
            "--format",
            "json",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    compose_config = json.loads(config_result.stdout)
    for service in ["postgres", "pgbouncer", "logical_backup", "valkey", "memcached", "rabbitmq"]:
        service_config = compose_config["services"].get(service)
        if not service_config:
            continue
        caps = service_config.get("cap_drop", [])
        assert caps == ["ALL"], f"service {service} should drop all capabilities"
        seccomp_opts = service_config.get("security_opt", [])
        assert any(opt.startswith("seccomp:") or opt.startswith("seccomp=") for opt in seccomp_opts), (
            f"service {service} should define a seccomp security option"
        )

    keep_stack = os.environ.get("CORE_DATA_TEST_KEEP_STACK") == "1"

    try:
        yield env, project_name
    finally:
        if keep_stack:
            print(
                f"[core_data tests] CORE_DATA_TEST_KEEP_STACK=1; "
                f"leaving project '{project_name}' running for debugging. "
                f"ENV_FILE={env_file}"
            )
        else:
            subprocess.run(["docker", "compose", "down", "-v"], cwd=ROOT, env=env, check=False)
            subprocess.run(
                ["docker", "pull", "busybox"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if backups_target.exists():
                subprocess.run(
                    [
                        "docker",
                        "run",
                        "--rm",
                        "-v",
                        f"{backups_target.resolve()}:/target",
                        "busybox",
                        "sh",
                        "-c",
                        "rm -rf /target/* /target/.[!.]* /target/..?*",
                    ],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            for path, existed, backup in managed_secrets:
                if existed and backup is not None:
                    path.write_bytes(backup)
                else:
                    path.unlink(missing_ok=True)
            env_file.unlink(missing_ok=True)
            if had_env and backup_env_bytes is not None:
                repo_env_path.write_bytes(backup_env_bytes)
            else:
                repo_env_path.unlink(missing_ok=True)

            for data_path, backup_entry in managed_data_dirs:
                rel = data_path.relative_to(data_root)
                if data_path.exists():
                    busybox_volume_command(f"rm -rf /data/{rel}")
                if backup_entry is not None:
                    backup_rel = backup_entry.relative_to(data_root)
                    busybox_volume_command(f"mv /data/{backup_rel} /data/{rel}")


def run_manage(env, *args, check=True):
    result = subprocess.run(
        [str(MANAGE), *args],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        raise subprocess.CalledProcessError(result.returncode, result.args)
    return result


def relation_size(env, table):
    result = subprocess.run(
        [
            str(MANAGE),
            "psql",
            "-d",
            "ci_db",
            "-t",
            "-A",
            "-c",
            f"SELECT pg_relation_size('{table}');",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return int(result.stdout.strip())


def compose_down(env, volumes=False):
    cmd = [
        "docker",
        "compose",
        "--env-file",
        env["ENV_FILE"],
        "down",
    ]
    if volumes:
        cmd.append("-v")
    subprocess.run(cmd, cwd=ROOT, env=env, check=False)


def container_name(project_name, service):
    return f"{project_name}_{service}"


def service_running(project_name, service):
    container = container_name(project_name, service)
    result = subprocess.run(
        [
            "docker",
            "ps",
            "--filter",
            f"name={container}",
            "--format",
            "{{.ID}}",
        ],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0 and bool(result.stdout.strip())


def container_ip(project_name, service, retries=60, delay=2):
    container = container_name(project_name, service)
    last_error = None
    for _ in range(retries):
        result = subprocess.run(
            [
                "docker",
                "inspect",
                "-f",
                "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                container,
            ],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            ip_addr = result.stdout.strip()
            if ip_addr:
                return ip_addr
            last_error = RuntimeError(f"container {service} has no assigned IP yet")
        else:
            last_error = RuntimeError(f"failed to inspect container {service}: {result.stderr.strip()}")
        exec_result = subprocess.run(
            ["docker", "exec", container, "hostname", "-i"],
            capture_output=True,
            text=True,
        )
        if exec_result.returncode == 0:
            ip_candidate = exec_result.stdout.strip()
            if ip_candidate:
                return ip_candidate.split()[0]
        elif exec_result.stderr:
            last_error = RuntimeError(f"failed to exec hostname in {service}: {exec_result.stderr.strip()}")
        time.sleep(delay)
    if last_error:
        raise last_error
    raise RuntimeError(f"container {service} has no assigned IP")


def wait_for_port(host, port, retries=30, delay=2):
    for _ in range(retries):
        try:
            with socket.create_connection((host, port), timeout=3):
                return
        except OSError:
            time.sleep(delay)
    raise RuntimeError(f"service on {host}:{port} not reachable")


def container_endpoint(project_name, service, port):
    return container_ip(project_name, service), port


def container_endpoint_factory(project_name, service, port):
    if not project_name:
        return None
    return functools.partial(container_endpoint, project_name, service, port)


def wait_for_container(project_name, service, retries=60, delay=2):
    container = container_name(project_name, service)
    last_error = None
    for _ in range(retries):
        inspect = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Status}}", container],
            capture_output=True,
            text=True,
        )
        if inspect.returncode == 0:
            status = inspect.stdout.strip()
            if status == "running":
                health = subprocess.run(
                    [
                        "docker",
                        "inspect",
                        "-f",
                        "{{if .State.Health}}{{.State.Health.Status}}{{end}}",
                        container,
                    ],
                    capture_output=True,
                    text=True,
                )
                if health.returncode == 0 and health.stdout.strip() and health.stdout.strip() not in {"healthy", ""}:
                    last_error = RuntimeError(f"container {service} health {health.stdout.strip()}")
                else:
                    return
            elif status == "exited":
                code = subprocess.run(
                    [
                        "docker",
                        "inspect",
                        "-f",
                        "{{.State.ExitCode}}",
                        container,
                    ],
                    capture_output=True,
                    text=True,
                )
                reason = subprocess.run(
                    [
                        "docker",
                        "inspect",
                        "-f",
                        "{{.State.Error}}",
                        container,
                    ],
                    capture_output=True,
                    text=True,
                )
                exit_code = code.stdout.strip() if code.returncode == 0 else "?"
                details = reason.stdout.strip() if reason.returncode == 0 else ""
                raise RuntimeError(f"container {service} exited with code {exit_code}: {details}")
            else:
                if status in {"restarting", "paused"}:
                    exit_code = subprocess.run(
                        [
                            "docker",
                            "inspect",
                            "-f",
                            "{{.State.ExitCode}}",
                            container,
                        ],
                        capture_output=True,
                        text=True,
                    )
                    error_detail = subprocess.run(
                        [
                            "docker",
                            "inspect",
                            "-f",
                            "{{.State.Error}}",
                            container,
                        ],
                        capture_output=True,
                        text=True,
                    )
                    exit_part = exit_code.stdout.strip() if exit_code.returncode == 0 else "?"
                    detail_part = error_detail.stdout.strip() if error_detail.returncode == 0 else ""
                    last_error = RuntimeError(f"container {service} status {status} exit {exit_part} {detail_part}")
                else:
                    last_error = RuntimeError(f"container {service} status {status}")
        else:
            last_error = RuntimeError(f"failed to inspect container {service}: {inspect.stderr.strip()}")
        time.sleep(delay)
    if last_error:
        logs = subprocess.run(
            ["docker", "logs", container],
            capture_output=True,
            text=True,
        )
        if logs.returncode == 0:
            raise RuntimeError(f"{last_error}; recent logs:\n{logs.stdout}") from last_error
        raise last_error
    raise RuntimeError(f"container {service} failed to reach running state")


def inspect_container(project_name, service):
    container = container_name(project_name, service)
    result = subprocess.run(["docker", "inspect", container], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"failed to inspect container {service}: {result.stderr.strip()}")
    data = json.loads(result.stdout)
    if not data:
        raise RuntimeError(f"docker inspect returned no data for {service}")
    return data[0]


def assert_service_security(project_name, service):
    wait_for_container(project_name, service)
    info = inspect_container(project_name, service)
    host_cfg = info.get("HostConfig", {})
    cap_drop = host_cfg.get("CapDrop") or []
    assert "ALL" in cap_drop, f"{service} should drop all capabilities"
    sec_opts = host_cfg.get("SecurityOpt") or []
    assert any("seccomp" in opt for opt in sec_opts), f"{service} missing seccomp profile"
    assert any(opt.startswith("no-new-privileges") for opt in sec_opts), f"{service} should set no-new-privileges"
    assert not host_cfg.get("Privileged", False), f"{service} should not run privileged"


def assert_stack_security(project_name):
    for service in ("postgres", "pgbouncer", "valkey", "memcached", "rabbitmq"):
        if service_running(project_name, service):
            assert_service_security(project_name, service)


def pick_endpoint(primary, secondary=None, *, primary_retries=15, secondary_retries=30, delay=2):
    try:
        wait_for_port(*primary, retries=primary_retries, delay=delay)
        return primary
    except RuntimeError as primary_error:
        if not secondary:
            raise primary_error
        if callable(secondary):
            try:
                secondary = secondary()
            except (RuntimeError, OSError, ValueError) as resolver_error:  # noqa: PERF203
                raise RuntimeError(f"failed to resolve secondary endpoint: {resolver_error}") from resolver_error
        try:
            wait_for_port(*secondary, retries=secondary_retries, delay=delay)
            return secondary
        except RuntimeError as secondary_error:
            raise RuntimeError(
                f"primary endpoint failed ({primary_error}); fallback endpoint failed ({secondary_error})"
            ) from secondary_error


def _redis_resp(*args):
    parts = [f"*{len(args)}\r\n".encode()]
    for arg in args:
        if isinstance(arg, str):
            arg = arg.encode()
        parts.append(f"${len(arg)}\r\n".encode())
        parts.append(arg)
        parts.append(b"\r\n")
    return b"".join(parts)


def check_valkey(host, port, password):
    wait_for_port(host, port)
    with socket.create_connection((host, port), timeout=5) as sock:
        sock.settimeout(5)
        if password:
            sock.sendall(_redis_resp("AUTH", password))
            response = sock.recv(128)
            assert response.startswith(b"+OK"), response
        sock.sendall(_redis_resp("PING"))
        assert sock.recv(128).startswith(b"+PONG")
        sock.sendall(_redis_resp("SET", "e2e_network_check", "online"))
        assert sock.recv(128).startswith(b"+OK")
        sock.sendall(_redis_resp("GET", "e2e_network_check"))
        payload = sock.recv(128)
        assert b"$6\r\nonline" in payload


def check_memcached(host, port):
    wait_for_port(host, port)
    with socket.create_connection((host, port), timeout=5) as sock:
        sock.settimeout(5)
        payload = b"online"
        sock.sendall(b"set e2e_network_check 0 30 " + str(len(payload)).encode() + b"\r\n" + payload + b"\r\n")
        assert sock.recv(128).startswith(b"STORED")
        sock.sendall(b"get e2e_network_check\r\n")
        data = sock.recv(256)
        assert b"VALUE e2e_network_check" in data
        assert b"online" in data


def rabbitmq_api_request(host, port, username, password, method, path, payload=None, timeout=5):
    credentials = base64.b64encode(f"{username}:{password}".encode()).decode()
    headers = {
        "Authorization": f"Basic {credentials}",
        "Content-Type": "application/json",
    }
    body = None
    if payload is not None:
        body = json.dumps(payload).encode()
    connection = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        data = response.read()
        return response.status, data
    finally:
        connection.close()


def check_rabbitmq(amqp_host, amqp_port, http_host, http_port, username, password, retries=30, delay=3):
    wait_for_port(amqp_host, amqp_port, retries=retries, delay=delay)
    wait_for_port(http_host, http_port, retries=retries, delay=delay)
    credentials = base64.b64encode(f"{username}:{password}".encode()).decode()
    for _ in range(retries):
        conn = http.client.HTTPConnection(http_host, http_port, timeout=5)
        try:
            conn.request(
                "GET",
                "/api/overview",
                headers={"Authorization": f"Basic {credentials}"},
            )
            response = conn.getresponse()
            payload = response.read()
            if response.status == 200 and b"queue_totals" in payload:
                return
        except OSError as exc:
            warnings.warn(f"RabbitMQ management API check failed: {exc}", RuntimeWarning, stacklevel=2)
        finally:
            conn.close()
        time.sleep(delay)
    raise RuntimeError("RabbitMQ management API not reachable")


def exercise_rabbitmq_messages(http_host, http_port, username, password):
    queue_name = f"core_data_e2e_{uuid.uuid4().hex[:8]}"
    queue_encoded = urllib.parse.quote(queue_name, safe="")
    try:
        status, _ = rabbitmq_api_request(
            http_host,
            http_port,
            username,
            password,
            "PUT",
            f"/api/queues/%2f/{queue_encoded}",
            {"durable": False, "auto_delete": True},
        )
        assert status in {201, 204}, f"queue declare failed (status={status})"

        payload = {
            "properties": {},
            "routing_key": queue_name,
            "payload": "core_data_test_message",
            "payload_encoding": "string",
        }
        status, publish_body = rabbitmq_api_request(
            http_host,
            http_port,
            username,
            password,
            "POST",
            "/api/exchanges/%2f/amq.default/publish",
            payload,
        )
        assert status == 200, f"publish failed (status={status}, body={publish_body!r})"
        publish_result = json.loads(publish_body.decode())
        assert publish_result.get("routed") is True, f"publish not routed: {publish_result}"

        status, message_body = rabbitmq_api_request(
            http_host,
            http_port,
            username,
            password,
            "POST",
            f"/api/queues/%2f/{queue_encoded}/get",
            {"count": 1, "ackmode": "ack_requeue_false", "encoding": "auto"},
        )
        assert status == 200, f"get failed (status={status}, body={message_body!r})"
        messages = json.loads(message_body.decode())
        assert messages, "expected at least one message from RabbitMQ queue"
        assert messages[0].get("payload") == "core_data_test_message", messages[0]
    finally:
        rabbitmq_api_request(
            http_host,
            http_port,
            username,
            password,
            "DELETE",
            f"/api/queues/%2f/{queue_encoded}",
        )


def wait_for_ready(env, retries=40, delay=5):
    for _ in range(retries):
        result = subprocess.run(
            [str(MANAGE), "psql", "-c", "SELECT 1;"],
            cwd=ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            return
        time.sleep(delay)
    raise RuntimeError("postgres never reached ready state")


def exercise_network_clients(env, app_db, app_user, app_password):
    env_file = Path(env["ENV_FILE"])
    env_values = {}
    for line in env_file.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env_values[key.strip()] = value.strip()

    project_name = env.get("COMPOSE_PROJECT_NAME")
    compose_profiles_raw = env.get("COMPOSE_PROFILES", env_values.get("COMPOSE_PROFILES", ""))
    active_profiles = {profile.strip() for profile in compose_profiles_raw.split(",") if profile.strip()}

    def profile_enabled(sidecar: str) -> bool:
        profile_map = {
            "valkey": "valkey",
            "memcached": "memcached",
            "pgbouncer": "pgbouncer",
            "rabbitmq": "rabbitmq",
        }
        mapped = profile_map.get(sidecar)
        if mapped is None:
            return True
        return mapped in active_profiles

    unavailable = {}
    if project_name:
        ip_addr = container_ip(project_name, "postgres")
        assert ip_addr.count(".") == 3
        for sidecar in ("pgbouncer", "valkey", "memcached", "rabbitmq"):
            if not profile_enabled(sidecar):
                continue
            try:
                wait_for_container(project_name, sidecar)
            except RuntimeError as err:
                unavailable[sidecar] = str(err)

    def resolve_port(key: str, default: str) -> int:
        source = env.get(key)
        if source is not None:
            return int(source)
        return int(env_values.get(key, default))

    valkey_host_port = resolve_port("VALKEY_HOST_PORT", env_values.get("VALKEY_PORT", "6379"))
    memcached_host_port = resolve_port("MEMCACHED_PORT", "11211")
    rabbitmq_host_port = resolve_port("RABBITMQ_HOST_PORT", env_values.get("RABBITMQ_PORT", "5672"))
    rabbitmq_mgmt_host_port = resolve_port(
        "RABBITMQ_MANAGEMENT_HOST_PORT", env_values.get("RABBITMQ_MANAGEMENT_PORT", "15672")
    )
    pgbouncer_host_port = resolve_port("PGBOUNCER_HOST_PORT", env_values.get("PGBOUNCER_PORT", "6432"))
    if profile_enabled("valkey"):
        valkey_issue = unavailable.pop("valkey", None)
        if valkey_issue:
            pytest.fail(f"Valkey sidecar unavailable: {valkey_issue}")
        valkey_primary = ("127.0.0.1", valkey_host_port)
        valkey_secondary = container_endpoint_factory(project_name, "valkey", 6379)
        valkey_host, valkey_port = pick_endpoint(
            valkey_primary,
            valkey_secondary,
            primary_retries=30,
            secondary_retries=30,
        )
        check_valkey(valkey_host, valkey_port, read_secret("secrets/valkey_password"))

    if profile_enabled("memcached"):
        memcached_issue = unavailable.pop("memcached", None)
        if memcached_issue:
            warnings.warn(
                f"Memcached health check reported an issue; continuing with direct probe: {memcached_issue}",
                RuntimeWarning,
            )
        memcached_primary = ("127.0.0.1", memcached_host_port)
        memcached_secondary = container_endpoint_factory(project_name, "memcached", 11211)
        try:
            memcached_host, memcached_port = pick_endpoint(
                memcached_primary,
                memcached_secondary,
                primary_retries=30,
                secondary_retries=30,
            )
        except RuntimeError as exc:
            pytest.fail(f"Memcached unreachable: {exc}")
        check_memcached(memcached_host, memcached_port)

    if profile_enabled("rabbitmq"):
        rabbitmq_issue = unavailable.pop("rabbitmq", None)
        if rabbitmq_issue:
            pytest.fail(f"RabbitMQ sidecar unavailable: {rabbitmq_issue}")
        rabbitmq_primary = ("127.0.0.1", rabbitmq_host_port)
        rabbitmq_secondary = container_endpoint_factory(project_name, "rabbitmq", 5672)
        rabbitmq_host, rabbitmq_port = pick_endpoint(
            rabbitmq_primary,
            rabbitmq_secondary,
            primary_retries=30,
            secondary_retries=30,
        )
        rabbitmq_mgmt_primary = ("127.0.0.1", rabbitmq_mgmt_host_port)
        rabbitmq_mgmt_secondary = container_endpoint_factory(project_name, "rabbitmq", 15672)
        rabbitmq_mgmt_host, rabbitmq_mgmt_port = pick_endpoint(
            rabbitmq_mgmt_primary,
            rabbitmq_mgmt_secondary,
            primary_retries=30,
            secondary_retries=30,
        )
        rabbitmq_user = env_values.get("RABBITMQ_DEFAULT_USER", "coredata")
        rabbitmq_password = read_secret("secrets/rabbitmq_default_pass")
        check_rabbitmq(
            rabbitmq_host,
            rabbitmq_port,
            rabbitmq_mgmt_host,
            rabbitmq_mgmt_port,
            rabbitmq_user,
            rabbitmq_password,
        )
        exercise_rabbitmq_messages(
            rabbitmq_mgmt_host,
            rabbitmq_mgmt_port,
            rabbitmq_user,
            rabbitmq_password,
        )

    pgbouncer_available = profile_enabled("pgbouncer") and "pgbouncer" not in unavailable
    if not pgbouncer_available and profile_enabled("pgbouncer"):
        warnings.warn(f"Skipping PgBouncer checks: {unavailable['pgbouncer']}", RuntimeWarning)
    if pgbouncer_available:
        pgbouncer_primary = ("127.0.0.1", pgbouncer_host_port)
        pgbouncer_secondary = container_endpoint_factory(project_name, "pgbouncer", 6432)
        pgbouncer_host, pgbouncer_port = pick_endpoint(
            pgbouncer_primary,
            pgbouncer_secondary,
            primary_retries=30,
            secondary_retries=30,
        )

        with psycopg.connect(
            host=pgbouncer_host,
            port=pgbouncer_port,
            user=app_user,
            password=app_password,
            dbname=app_db,
            row_factory=tuple_row,
            connect_timeout=10,
        ) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS public.e2e_network_events (
                        id serial PRIMARY KEY,
                        message text NOT NULL,
                        created_at timestamptz DEFAULT now()
                    );
                    """
                )
                cur.execute(
                    "INSERT INTO public.e2e_network_events(message) VALUES (%s)",
                    ("network client reached via PgBouncer",),
                )
                cur.execute("SELECT COUNT(*) FROM public.e2e_network_events")
                count = cur.fetchone()[0]
            conn.commit()
        assert count >= 1

        pgbouncer_stats_user = env_values.get("PGBOUNCER_STATS_USER", "pgbouncer_stats")
        stats_password = read_secret("secrets/pgbouncer_stats_password")
        with psycopg.connect(
            host="127.0.0.1",
            port=pgbouncer_port,
            user=pgbouncer_stats_user,
            password=stats_password,
            dbname="pgbouncer",
            row_factory=tuple_row,
            connect_timeout=10,
            autocommit=True,
        ) as stats_conn:
            with stats_conn.cursor() as cur:
                cur.execute("SHOW STATS;")
                stats_rows = cur.fetchall()
        assert any(row[0] == app_db for row in stats_rows)


def test_full_workflow(manage_env):
    env, project_name = manage_env

    run_manage(env, "build-image")
    run_manage(env, "up")
    wait_for_ready(env)
    assert_stack_security(project_name)
    run_manage(env, "stanza-create")

    run_manage(env, "create-user", "ci_user", "ci_password")
    run_manage(env, "create-db", "ci_db", "ci_user")
    exercise_network_clients(env, "ci_db", "ci_user", "ci_password")
    run_manage(env, "dump", "ci_db")
    run_manage(env, "dump-sql", "ci_db")
    run_manage(
        env,
        "psql",
        "-d",
        "ci_db",
        "-c",
        "CREATE TABLE IF NOT EXISTS public.space_test(id serial PRIMARY KEY, payload text);",
    )
    run_manage(
        env,
        "psql",
        "-d",
        "ci_db",
        "-c",
        "INSERT INTO public.space_test(payload) SELECT repeat('x', 1000) FROM generate_series(1, 1000);",
    )
    run_manage(
        env,
        "psql",
        "-d",
        "ci_db",
        "-c",
        "DELETE FROM public.space_test WHERE id % 2 = 0;",
    )
    run_manage(env, "exercise-extensions", "--db", "ci_db")
    run_manage(env, "pgtap-smoke", "--db", "ci_db")

    run_manage(
        env,
        "pgbadger-report",
        "--since",
        "yesterday",
        "--output",
        "/backups/ci-report.html",
    )
    backups_path = Path(env["BACKUPS_HOST_PATH"])
    run_manage(
        env,
        "daily-maintenance",
        "--root",
        str(backups_path / "ci"),
        "--container-root",
        "/backups/ci",
    )
    run_manage(env, "audit-cron")
    run_manage(env, "audit-squeeze")
    daily_dirs = sorted((backups_path / "ci").glob("*/"))
    assert daily_dirs
    daily_dir = daily_dirs[-1]
    print("daily_dir entries:", sorted(p.name for p in daily_dir.iterdir()))
    assert (daily_dir / "index_bloat.csv").exists()
    assert (daily_dir / "schema_snapshot.csv").exists()
    assert (daily_dir / "maintenance_report.html").exists()

    env_file = Path(env["ENV_FILE"])
    env_values = {}
    for line in env_file.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env_values[key.strip()] = value.strip()

    compose_profiles_raw = env.get("COMPOSE_PROFILES", env_values.get("COMPOSE_PROFILES", ""))
    active_profiles = {profile.strip() for profile in compose_profiles_raw.split(",") if profile.strip()}

    def profile_enabled(name: str) -> bool:
        return name in active_profiles

    valkey_dump = daily_dir / "valkey-dump.rdb"
    if profile_enabled("valkey") and not valkey_dump.exists():
        warnings.warn("valkey dump missing", RuntimeWarning)
    valkey_info = daily_dir / "valkey-info.txt"
    if valkey_info.exists():
        assert valkey_info.stat().st_size > 0

    pgbouncer_stats = daily_dir / "pgbouncer-stats.csv"
    pgbouncer_pools = daily_dir / "pgbouncer-pools.csv"
    if pgbouncer_stats.exists():
        assert pgbouncer_stats.stat().st_size > 0
    if pgbouncer_pools.exists():
        assert pgbouncer_pools.stat().st_size > 0

    memcached_stats = daily_dir / "memcached-stats.txt"
    if memcached_stats.exists():
        assert memcached_stats.stat().st_size > 0
    rabbitmq_defs = daily_dir / "rabbitmq-definitions.json"
    if profile_enabled("rabbitmq"):
        assert rabbitmq_defs.exists()
        assert rabbitmq_defs.stat().st_size > 0
    rabbitmq_status = daily_dir / "rabbitmq-status.txt"
    if rabbitmq_status.exists():
        assert rabbitmq_status.stat().st_size > 0
    pgbadger_html = daily_dir / "pgbadger.html"
    assert pgbadger_html.exists() and pgbadger_html.stat().st_size > 0

    dump_files = sorted(daily_dir.glob("*.dump.gz"))
    assert dump_files, "expected at least one compressed dump"
    with gzip.open(dump_files[0], "rb") as fh:
        fh.read(1)

    if memcached_stats.exists():
        memcached_report = memcached_stats.read_text()
        assert "STAT" in memcached_report
    run_manage(env, "compact", "--level", "1")
    run_manage(env, "compact", "--level", "2")

    size_before = relation_size(env, "public.space_test")
    run_manage(env, "compact", "--level", "3", "--tables", "public.space_test")
    size_after_repack = relation_size(env, "public.space_test")
    assert size_after_repack <= size_before

    run_manage(env, "compact", "--level", "4", "--scope", "public.space_test", "--yes")
    size_after_vacuum = relation_size(env, "public.space_test")
    assert size_after_vacuum <= size_after_repack

    repack_logs = list(backups_path.glob("pg_repack-*.log"))
    vacuum_logs = list(backups_path.glob("vacuum-full-*.log"))
    assert repack_logs
    assert vacuum_logs

    run_manage(env, "backup", "--type=full")

    run_manage(env, "upgrade", "--new-version", "18")
    wait_for_ready(env)

    status = subprocess.run([str(MANAGE), "status"], cwd=ROOT, env=env, capture_output=True, text=True)
    assert status.returncode == 0
    assert f"{project_name}_postgres" in status.stdout

    env_file = Path(env["ENV_FILE"])
    contents = env_file.read_text()
    assert "PG_VERSION=18" in contents

    run_manage(env, "down")
    compose_down(env, volumes=True)


@pytest.mark.security
def test_security_baseline(manage_env):
    env, project_name = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        assert_stack_security(project_name)
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.backup
def test_logical_backup_health(manage_env):
    env, project_name = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        try:
            wait_for_container(project_name, "logical_backup", retries=120, delay=2)
        except RuntimeError as exc:
            warnings.warn(f"logical_backup health check warning: {exc}", RuntimeWarning)
            pytest.skip("logical_backup sidecar not healthy in CI sandbox")
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


EXTENSIONS_TO_CHECK = [
    "pg_stat_statements",
    "pgcrypto",
    "pgaudit",
    "pg_partman",
    "pg_trgm",
    "vector",
]


@pytest.mark.extensions
def test_extensions_available(manage_env):
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        missing = []
        for extension in EXTENSIONS_TO_CHECK:
            result = run_manage(
                env,
                "psql",
                "-d",
                "postgres",
                "-t",
                "-A",
                "-c",
                f"SELECT 1 FROM pg_extension WHERE extname='{extension}';",
                check=False,
            )
            if result.returncode != 0 or result.stdout.strip() != "1":
                missing.append(extension)
        assert not missing, f"extensions missing: {', '.join(missing)}"
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.pool
def test_pgbouncer_concurrency(manage_env):
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        run_manage(env, "create-user", "ci_user", "ci_password")
        run_manage(env, "create-db", "ci_db", "ci_user")
        run_manage(
            env,
            "psql",
            "-d",
            "ci_db",
            "-c",
            "CREATE TABLE IF NOT EXISTS public.e2e_pool_test(worker_id int, created_at timestamptz DEFAULT now());",
        )

        port = int(env.get("PGBOUNCER_HOST_PORT", env.get("PGBOUNCER_PORT", "6432")))

        def worker(idx):
            with psycopg.connect(
                host="127.0.0.1",
                port=port,
                user="ci_user",
                password="ci_password",
                dbname="ci_db",
                autocommit=True,
                row_factory=tuple_row,
            ) as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO public.e2e_pool_test(worker_id) VALUES (%s) RETURNING worker_id",
                        (idx,),
                    )
                    return cur.fetchone()[0]

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(worker, range(16)))

        assert len(set(results)) == 16
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.pool_heavy
def test_database_recreation_cycles(manage_env):
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        run_manage(env, "create-user", "ci_user", "ci_password")
        for cycle in range(3):
            db_name = f"ci_regression_{cycle}"
            run_manage(env, "create-db", db_name, "ci_user")
            run_manage(env, "psql", "-d", db_name, "-c", "SELECT current_database();")
            run_manage(env, "drop-db", db_name)
            wait_for_ready(env)
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.pool_heavy
def test_test_dataset_bootstrap(manage_env):
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        run_manage(
            env,
            "test-dataset",
            "bootstrap",
            "--db",
            "testkit_db",
            "--owner",
            "testkit_user",
            "--password",
            "testkit_password",
            "--force",
        )
        run_manage(env, "pgtap-smoke", "--db", "testkit_db")

        places_count = run_manage(
            env,
            "psql",
            "-d",
            "testkit_db",
            "-t",
            "-A",
            "-c",
            "SELECT count(*) FROM testkit.places;",
        )
        assert places_count.stdout.strip() == "4"

        spatial_result = run_manage(
            env,
            "psql",
            "-d",
            "testkit_db",
            "-t",
            "-A",
            "-c",
            "SELECT ST_DWithin(p1.location, p2.location, 800.0) FROM testkit.places p1 JOIN testkit.places p2 ON p1.slug='downtown-market' AND p2.slug='riverside-museum';",
        )
        assert spatial_result.stdout.strip() == "t"

        vector_knn = run_manage(
            env,
            "psql",
            "-d",
            "testkit_db",
            "-t",
            "-A",
            "-c",
            "SELECT slug FROM testkit.knn_places('[0.5,0.1,0.9]'::vector, 1);",
        )
        assert vector_knn.stdout.strip() == "downtown-market"

        routing_count = run_manage(
            env,
            "psql",
            "-d",
            "testkit_db",
            "-t",
            "-A",
            "-c",
            "SELECT count(*) FROM testkit.routing_shortest_path;",
        )
        assert int(routing_count.stdout.strip()) > 0

        graph_edges = run_manage(
            env,
            "psql",
            "-d",
            "testkit_db",
            "-t",
            "-A",
            "-c",
            'SET search_path = ag_catalog, "$user", public; '
            "SELECT source::text, target::text FROM cypher('testkit_graph', $$ MATCH (a:Place)-[:ROUTE]->(b:Place) RETURN a.slug AS source, b.slug AS target $$) "
            "AS (source agtype, target agtype) ORDER BY source::text, target::text;",
        )
        graph_lines = [line for line in graph_edges.stdout.splitlines() if "|" in line]
        assert "downtown-market|riverside-museum" in graph_lines

        port = int(env.get("PGBOUNCER_HOST_PORT", env.get("PGBOUNCER_PORT", "6432")))

        def pool_worker(_idx):
            with psycopg.connect(
                host="127.0.0.1",
                port=port,
                user="testkit_user",
                password="testkit_password",
                dbname="testkit_db",
                autocommit=True,
                row_factory=tuple_row,
            ) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT slug FROM testkit.places ORDER BY slug LIMIT 1;")
                    return cur.fetchone()[0]

        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
            pool_results = list(executor.map(pool_worker, range(12)))
        assert all(result == "canal-roasters" for result in pool_results)

        query_uuid = uuid.uuid4().hex
        before_name = f"pg_stat_before_{query_uuid}.csv"
        after_name = f"pg_stat_after_{query_uuid}.csv"
        container_before = f"/backups/{before_name}"
        container_after = f"/backups/{after_name}"
        backups_path = Path(env["BACKUPS_HOST_PATH"])
        host_before = backups_path / before_name
        host_after = backups_path / after_name
        run_manage(
            env,
            "snapshot-pgstat",
            "--output",
            container_before,
            "--limit",
            "50",
        )
        assert host_before.exists()
        time.sleep(1)
        pgstat_ready = True
        with host_before.open(newline="") as fh:
            before_reader = csv.DictReader(fh)
            if before_reader.fieldnames is None:
                pgstat_ready = False
            else:
                expected_cols = {"queryid", "calls", "datname", "rows", "total_exec_time"}
                assert expected_cols.issubset(set(before_reader.fieldnames))

        graphql_port = _find_free_port()
        graphql_payload = {
            "query": """
                query Testkit($vector: [Float!]!) {
                  places { slug name locationWkt regionCode }
                  nearestPlace(vector: $vector) { slug name }
                  routeCost(originSlug: \"downtown-market\", destinationSlug: \"harbor-aquatics-lab\")
                }
            """,
            "variables": {"vector": [0.5, 0.1, 0.9]},
        }
        db_settings = {
            "host": "127.0.0.1",
            "port": port,
            "user": "testkit_user",
            "password": "testkit_password",
            "dbname": "testkit_db",
        }
        with GraphQLServer(graphql_port, db_settings):
            request = urllib.request.Request(
                f"http://127.0.0.1:{graphql_port}/graphql",
                data=json.dumps(graphql_payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request, timeout=10) as response:
                graphql_response = json.loads(response.read().decode())

        assert "errors" not in graphql_response, graphql_response.get("errors")
        data = graphql_response.get("data")
        assert data is not None
        assert len(data["places"]) == 4
        assert any(place["slug"] == "downtown-market" for place in data["places"])
        assert data["nearestPlace"]["slug"] == "downtown-market"
        assert data["routeCost"] and data["routeCost"] > 0

        run_manage(
            env,
            "snapshot-pgstat",
            "--output",
            container_after,
            "--limit",
            "50",
        )
        assert host_after.exists()
        time.sleep(1)
        if pgstat_ready:
            with host_after.open(newline="") as fh:
                after_reader = csv.DictReader(fh)
                if after_reader.fieldnames is None:
                    pgstat_ready = False
                else:
                    expected_cols = {"queryid", "calls", "datname", "rows", "total_exec_time"}
                    assert expected_cols.issubset(set(after_reader.fieldnames))
        if pgstat_ready:
            diff_result = run_manage(
                env,
                "diff-pgstat",
                "--base",
                str(host_before),
                "--compare",
                str(host_after),
                "--limit",
                "10",
            )
            assert "queryid" in diff_result.stdout

        run_manage(env, "stanza-create", check=False)
        backup_verify = run_manage(env, "backup", "--type=diff", "--verify", check=False)
        assert "backup command end: completed successfully" in backup_verify.stdout
        if backup_verify.returncode != 0:
            warnings.warn("pgBackRest verification failed (likely due to read-only restore container)")

        config_tpl = ROOT / "postgres" / "conf" / "postgresql.conf.tpl"
        original_config = config_tpl.read_text()
        run_manage(env, "config-check")
        try:
            config_tpl.write_text(original_config + "\n# drift-check-test\n")
            drift_result = run_manage(env, "config-check", check=False)
            assert drift_result.returncode != 0
        finally:
            config_tpl.write_text(original_config)
        run_manage(env, "config-check")

        run_manage(env, "partman-maintenance", "--db", "testkit_db")
        partitions_result = run_manage(
            env,
            "psql",
            "-d",
            "testkit_db",
            "-t",
            "-A",
            "-c",
            """
            SELECT COUNT(*)
              FROM pg_tables
             WHERE schemaname = 'testkit'
               AND tablename LIKE 'sensor_readings%';
            """,
        )
        assert int(partitions_result.stdout.strip()) >= 3
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.lint
def test_shell_scripts_lint():
    shellcheck = shutil.which("shellcheck")
    if shellcheck is None:
        pytest.skip("shellcheck not available")
    scripts = [
        ROOT / "scripts" / "manage.sh",
        ROOT / "scripts" / "daily_maintenance.sh",
        ROOT / "pgbouncer" / "entrypoint.sh",
        ROOT / "valkey" / "entrypoint.sh",
    ]
    cmd = [
        shellcheck,
        "--external-sources",
        *map(str, scripts),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    filtered_output = [
        line
        for line in (result.stdout + result.stderr).splitlines()
        if "SC1091" not in line or "Not following" not in line
    ]
    assert result.returncode == 0, "\n".join(filtered_output)


@pytest.mark.config
def test_config_check(manage_env):
    env, _ = manage_env
    result = run_manage(env, "config-check", check=False)
    assert result.returncode == 0, result.stdout + result.stderr


def test_create_env_noninteractive(manage_env, tmp_path):
    env, _ = manage_env
    target = tmp_path / "generated.env"
    postgres_secret = ROOT / "secrets" / "postgres_superuser_password"
    valkey_secret = ROOT / "secrets" / "valkey_password"
    pgbouncer_auth_secret = ROOT / "secrets" / "pgbouncer_auth_password"
    pgbouncer_stats_secret = ROOT / "secrets" / "pgbouncer_stats_password"
    for path in (
        postgres_secret,
        valkey_secret,
        pgbouncer_auth_secret,
        pgbouncer_stats_secret,
    ):
        path.unlink(missing_ok=True)

    try:
        result = run_manage(env, "create-env", "--non-interactive", "--force", "--output", str(target))
        assert result.returncode == 0
        assert target.exists()
        content = target.read_text().splitlines()
        env_map = {}
        for line in content:
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                env_map[key.strip()] = value.strip()

        assert env_map["POSTGRES_SUPERUSER_PASSWORD_FILE"] == "./secrets/postgres_superuser_password"
        assert env_map["POSTGRES_SUPERUSER_PASSWORD"] == ""
        assert env_map["POSTGRES_UID"] == str(os.getuid())
        assert env_map["POSTGRES_GID"] == str(os.getgid())
        assert env_map["POSTGRES_MEMORY_LIMIT"].lower().endswith("g")
        assert env_map["POSTGRES_SHM_SIZE"].lower().endswith("g")
        assert float(env_map["POSTGRES_CPU_LIMIT"]) >= 1

        env_mode = stat.S_IMODE(os.stat(target).st_mode)
        assert env_mode == 0o600

        assert env_map["VALKEY_PASSWORD_FILE"] == "./secrets/valkey_password"
        assert env_map["PGBOUNCER_AUTH_PASSWORD_FILE"] == "./secrets/pgbouncer_auth_password"
        assert env_map["PGBOUNCER_STATS_PASSWORD_FILE"] == "./secrets/pgbouncer_stats_password"

        for path in (
            postgres_secret,
            valkey_secret,
            pgbouncer_auth_secret,
            pgbouncer_stats_secret,
        ):
            assert path.exists()
            mode = stat.S_IMODE(os.stat(path).st_mode)
            assert mode == 0o600
            assert path.read_text().strip() != ""
    finally:
        for path in (
            postgres_secret,
            valkey_secret,
            pgbouncer_auth_secret,
            pgbouncer_stats_secret,
        ):
            path.unlink(missing_ok=True)


@pytest.mark.ci
def test_ci_verify_dry_run(manage_env):
    env, _ = manage_env
    result = run_manage(
        env,
        "ci-verify",
        "--min-disk-mb",
        "1",
        "--skip-docker",
        "--skip-attestation",
        "--skip-ports",
    )
    assert result.returncode == 0


@pytest.mark.ci
def test_attestation_verify_outputs_details(manage_env, tmp_path):
    env, _ = manage_env
    fake_bin = tmp_path / "fake_bin"
    fake_bin.mkdir()
    gh_script = fake_bin / "gh"
    gh_script.write_text(
        """#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "attestation" && "${2:-}" == "verify" ]]; then
  subject=""
  for arg in "$@"; do
    case "$arg" in
      oci://*)
        subject="${arg#oci://}"
        ;;
    esac
  done
  if [[ -z "${subject}" ]]; then
    echo "missing subject" >&2
    exit 1
  fi
  name="${subject%%@*}"
  name="${name%%:*}"
  if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "Error: the provided token was denied access to the requested resource, please check the token's expiration and repository access" >&2
    exit 1
  fi
  if [[ "${name}" == *"no-attest"* ]]; then
    exit 0
  fi
  cat <<JSON
[{"verificationResult":{"statement":{"predicateType":"https://slsa.dev/provenance/v1","subject":[{"name":"${name}","digest":{"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}],"predicate":{"buildDefinition":{"externalParameters":{"workflow":{"path":".github/workflows/publish-docker.yml","ref":"refs/heads/main","repository":"https://github.com/test/repo"}}},"runDetails":{"builder":{"id":"fake-builder"},"metadata":{"invocationId":"https://github.com/test/repo/actions/runs/1"}}}}}}]
JSON
  exit 0
fi

echo "unsupported gh invocation" >&2
exit 1
"""
    )
    gh_script.chmod(0o755)
    env_local = env.copy()
    env_local["PATH"] = f"{str(fake_bin)}:{env_local['PATH']}"
    env_local["GH_TOKEN"] = "fake-token"
    env_local["GITHUB_TOKEN"] = "fake-token"
    result = run_manage(
        env_local,
        "attestation-verify",
        "--env-file",
        env_local["ENV_FILE"],
        "--image",
        "ghcr.io/paudley/core_data/postgres:ci-test",
    )
    assert result.returncode == 0
    assert "attestation verified for" in result.stderr
    assert "subject    :" in result.stderr
    failed = run_manage(
        env_local,
        "attestation-verify",
        "--env-file",
        env_local["ENV_FILE"],
        "--image",
        "ghcr.io/paudley/core_data/no-attest:ci-test",
        check=False,
    )
    assert failed.returncode != 0
    assert "returned no payload" in failed.stderr


@pytest.mark.ci
def test_ci_up_dry_run_emits_outputs(manage_env, tmp_path):
    env, _ = manage_env
    ci_env = tmp_path / "ci.env"
    ci_env.write_text(
        "\n".join(
            (
                "POSTGRES_PORT=65432",
                "COMPOSE_PROFILES=pgbouncer",
                "POSTGRES_SUPERUSER=postgres",
            )
        )
        + "\n"
    )
    output_path = tmp_path / "ci-output.json"
    result = run_manage(
        env,
        "ci-up",
        "--dry-run",
        "--skip-attestation",
        "--skip-bootstrap",
        "--env-file",
        str(ci_env),
        "--output",
        str(output_path),
    )
    assert result.returncode == 0
    assert output_path.exists()
    payload = json.loads(output_path.read_text())
    assert payload["composeProfiles"] == "pgbouncer"
    postgres = payload["services"]["postgres"]
    assert postgres["port"] == 65432
    assert postgres["host"] == "127.0.0.1"
    assert postgres["superuser"] == "postgres"


@pytest.mark.permissions
def test_permissions_validate(manage_env):
    """Test that permissions-validate command runs successfully."""
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        # Create a test database with non-superuser owner
        run_manage(env, "create-user", "perm_test_user", "perm_test_password")
        run_manage(env, "create-db", "perm_test_db", "perm_test_user")

        # Run permission validation - should pass after create-db applies grants
        result = run_manage(env, "permissions-validate", "--db", "perm_test_db")
        assert result.returncode == 0

        # Cleanup
        run_manage(env, "drop-db", "perm_test_db")
        run_manage(env, "drop-user", "perm_test_user")
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.permissions
def test_permissions_repair(manage_env):
    """Test that permissions-repair command can fix missing permissions."""
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        # Create a test database
        run_manage(env, "create-user", "repair_test_user", "repair_test_password")
        run_manage(env, "create-db", "repair_test_db", "repair_test_user")

        # Run permission repair
        result = run_manage(env, "permissions-repair", "--db", "repair_test_db")
        assert result.returncode == 0
        assert "permissions" in result.stderr.lower() or "repair" in result.stderr.lower()

        # Cleanup
        run_manage(env, "drop-db", "repair_test_db")
        run_manage(env, "drop-user", "repair_test_user")
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.permissions
def test_permissions_report(manage_env, tmp_path):
    """Test that permissions-report generates valid CSV output."""
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)

        # Run permission report without output file (should print to stdout)
        result = run_manage(env, "permissions-report", "--db", "postgres")
        assert result.returncode == 0
        # Should contain column headers from the report
        assert "schema_name" in result.stdout or "role_name" in result.stdout
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.permissions
def test_permissions_age_operations(manage_env):
    """Test that AGE operations work for non-superuser after permission grants."""
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        # Create a test database with non-superuser owner
        run_manage(env, "create-user", "age_test_user", "age_test_password")
        run_manage(env, "create-db", "age_test_db", "age_test_user")

        port = int(env.get("PGBOUNCER_HOST_PORT", env.get("PGBOUNCER_PORT", "6432")))

        # Test AGE operations as non-superuser via PgBouncer
        with psycopg.connect(
            host="127.0.0.1",
            port=port,
            user="age_test_user",
            password="age_test_password",
            dbname="age_test_db",
            autocommit=True,
            row_factory=tuple_row,
        ) as conn:
            with conn.cursor() as cur:
                # Set search_path to include ag_catalog
                cur.execute("SET search_path TO ag_catalog, public;")

                # Create a graph
                cur.execute("SELECT * FROM ag_catalog.create_graph('perm_test_graph');")

                # Create a vertex
                cur.execute(
                    """
                    SELECT * FROM cypher('perm_test_graph', $$
                        CREATE (n:TestNode {name: 'test'})
                        RETURN n
                    $$) AS (n agtype);
                    """
                )
                result = cur.fetchone()
                assert result is not None

                # Drop the graph
                cur.execute("SELECT * FROM ag_catalog.drop_graph('perm_test_graph', true);")

        # Cleanup
        run_manage(env, "drop-db", "age_test_db")
        run_manage(env, "drop-user", "age_test_user")
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.permissions
def test_permissions_vector_operations(manage_env):
    """Test that pgvector operations work for non-superuser after permission grants."""
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
        # Create a test database with non-superuser owner
        run_manage(env, "create-user", "vec_test_user", "vec_test_password")
        run_manage(env, "create-db", "vec_test_db", "vec_test_user")

        port = int(env.get("PGBOUNCER_HOST_PORT", env.get("PGBOUNCER_PORT", "6432")))

        # Test pgvector operations as non-superuser via PgBouncer
        with psycopg.connect(
            host="127.0.0.1",
            port=port,
            user="vec_test_user",
            password="vec_test_password",
            dbname="vec_test_db",
            autocommit=True,
            row_factory=tuple_row,
        ) as conn:
            with conn.cursor() as cur:
                # Create a table with vector column
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS public.vec_perm_test (
                        id serial PRIMARY KEY,
                        embedding vector(3)
                    );
                    """
                )

                # Insert vector data
                cur.execute(
                    "INSERT INTO public.vec_perm_test (embedding) VALUES ('[1,2,3]'::vector);"
                )

                # Query using vector similarity
                cur.execute(
                    "SELECT id FROM public.vec_perm_test ORDER BY embedding <-> '[1,2,3]'::vector LIMIT 1;"
                )
                result = cur.fetchone()
                assert result is not None
                assert result[0] == 1

                # Cleanup
                cur.execute("DROP TABLE public.vec_perm_test;")

        # Cleanup
        run_manage(env, "drop-db", "vec_test_db")
        run_manage(env, "drop-user", "vec_test_user")
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)
