# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

import base64
import concurrent.futures
import gzip
import http.client
import json
import os
import secrets
import shutil
import socket
import stat
import subprocess
import time
import uuid
import warnings
from pathlib import Path

import pytest
import psycopg
from psycopg.rows import tuple_row

ROOT = Path(__file__).resolve().parents[1]
MANAGE = ROOT / "scripts" / "manage.sh"
ENV_EXAMPLE = ROOT / ".env.example"


def read_secret(relative_path):
    return (ROOT / relative_path).read_text().strip()


@pytest.fixture(scope="module")
def manage_env(tmp_path_factory):
    workdir = tmp_path_factory.mktemp("core_data_ci")
    env_file = ROOT / ".env.test"

    def find_free_port():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    pghero_port = find_free_port()
    valkey_host_port = find_free_port()
    pgbouncer_host_port = find_free_port()
    memcached_port = find_free_port()

    compose_profiles = os.environ.get(
        "TEST_COMPOSE_PROFILES", "valkey,pgbouncer,memcached"
    )

    subnet_a = int(uuid.uuid4().hex[:2], 16)
    subnet_b = int(uuid.uuid4().hex[2:4], 16)
    replacements = {
        "PGHERO_PORT": str(pghero_port),
        "DOCKER_NETWORK_NAME": f"core_data_net_{uuid.uuid4().hex[:8]}",
        "DOCKER_NETWORK_SUBNET": f"10.{subnet_a}.{subnet_b}.0/24",
        "DATABASES_TO_CREATE": "app_main:app_user:change_me",
        "COMPOSE_PROFILES": compose_profiles,
        "VALKEY_HOST_PORT": str(valkey_host_port),
        "PGBOUNCER_HOST_PORT": str(pgbouncer_host_port),
        "MEMCACHED_PORT": str(memcached_port),
        "POSTGRES_UID": str(os.getuid()),
        "POSTGRES_GID": str(os.getgid()),
        "POSTGRES_RUNTIME_HOME": "/home/postgres",
        "POSTGRES_RUNTIME_GECOS": "CI_PostgreSQL_Administrator",
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

    backups_target = workdir / "backups"
    backups_target.mkdir(parents=True, exist_ok=True)
    try:
        backups_target.chmod(0o777)
    except PermissionError:
        pass

    managed_secrets = []

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

    backups_link = ROOT / "backups"
    had_existing_backups = backups_link.exists() or backups_link.is_symlink()
    original_backups = ROOT / ".backups_original"
    if had_existing_backups:
        if original_backups.exists() or original_backups.is_symlink():
            if original_backups.is_dir():
                subprocess.run(["rm", "-rf", str(original_backups)], check=False)
            else:
                original_backups.unlink(missing_ok=True)
        backups_link.rename(original_backups)
    if backups_link.exists() or backups_link.is_symlink():
        backups_link.unlink()
    backups_link.symlink_to(backups_target)

    env = os.environ.copy()
    env["ENV_FILE"] = str(env_file)
    project_name = env.setdefault(
        "COMPOSE_PROJECT_NAME", f"core_data_ci_{uuid.uuid4().hex[:8]}"
    )
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
    for service in ["postgres", "pghero", "pgbouncer", "logical_backup", "valkey", "memcached"]:
        caps = compose_config["services"].get(service, {}).get("cap_drop", [])
        assert caps == ["ALL"], f"service {service} should drop all capabilities"
        seccomp_opts = compose_config["services"].get(service, {}).get("security_opt", [])
        assert any(
            opt.startswith("seccomp:") or opt.startswith("seccomp=")
            for opt in seccomp_opts
        ), f"service {service} should define a seccomp security option"

    try:
        yield env, project_name
    finally:
        subprocess.run(
            ["docker", "compose", "down", "-v"], cwd=ROOT, env=env, check=False
        )
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
        if backups_link.is_symlink():
            backups_link.unlink()
        if had_existing_backups and original_backups.exists():
            original_backups.rename(backups_link)
        env_file.unlink(missing_ok=True)
        if had_env and backup_env_bytes is not None:
            repo_env_path.write_bytes(backup_env_bytes)
        else:
            repo_env_path.unlink(missing_ok=True)


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
            last_error = RuntimeError(
                f"failed to inspect container {service}: {result.stderr.strip()}"
            )
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
            last_error = RuntimeError(
                f"failed to exec hostname in {service}: {exec_result.stderr.strip()}"
            )
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


def container_endpoint_factory(project_name, service, port):
    if not project_name:
        return None

    def _resolver():
        return container_ip(project_name, service), port

    return _resolver


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
                if (
                    health.returncode == 0
                    and health.stdout.strip()
                    and health.stdout.strip() not in {"healthy", ""}
                ):
                    last_error = RuntimeError(
                        f"container {service} health {health.stdout.strip()}"
                    )
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
                raise RuntimeError(
                    f"container {service} exited with code {exit_code}: {details}"
                )
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
                    last_error = RuntimeError(
                        f"container {service} status {status} exit {exit_part} {detail_part}"
                    )
                else:
                    last_error = RuntimeError(
                        f"container {service} status {status}"
                    )
        else:
            last_error = RuntimeError(
                f"failed to inspect container {service}: {inspect.stderr.strip()}"
            )
        time.sleep(delay)
    if last_error:
        logs = subprocess.run(
            ["docker", "logs", container],
            capture_output=True,
            text=True,
        )
        if logs.returncode == 0:
            raise RuntimeError(
                f"{last_error}; recent logs:\n{logs.stdout}"
            ) from last_error
        raise last_error
    raise RuntimeError(f"container {service} failed to reach running state")


def inspect_container(project_name, service):
    container = container_name(project_name, service)
    result = subprocess.run(
        ["docker", "inspect", container], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"failed to inspect container {service}: {result.stderr.strip()}"
        )
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
    assert any(opt.startswith("no-new-privileges") for opt in sec_opts), (
        f"{service} should set no-new-privileges"
    )
    assert not host_cfg.get("Privileged", False), f"{service} should not run privileged"


def assert_stack_security(project_name):
    for service in ("postgres", "pghero", "pgbouncer", "valkey", "memcached"):
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
            except Exception as resolver_error:  # noqa: PERF203
                raise RuntimeError(
                    f"failed to resolve secondary endpoint: {resolver_error}"
                ) from resolver_error
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
        sock.sendall(
            b"set e2e_network_check 0 30 "
            + str(len(payload)).encode()
            + b"\r\n"
            + payload
            + b"\r\n"
        )
        assert sock.recv(128).startswith(b"STORED")
        sock.sendall(b"get e2e_network_check\r\n")
        data = sock.recv(256)
        assert b"VALUE e2e_network_check" in data
        assert b"online" in data


def check_pghero(host, port, username, password, retries=30, delay=3):
    credentials = base64.b64encode(f"{username}:{password}".encode()).decode()
    wait_for_port(host, port, retries=retries, delay=delay)
    authenticated = False
    for _ in range(retries):
        connection = http.client.HTTPConnection(host, port, timeout=5)
        try:
            connection.request(
                "GET",
                "/",
                headers={"Authorization": f"Basic {credentials}"},
            )
            response = connection.getresponse()
            body = response.read()
            if response.status == 200 and b"PgHero" in body:
                authenticated = True
                break
        except OSError:
            pass
        finally:
            connection.close()
        time.sleep(delay)
    if not authenticated:
        raise RuntimeError("PgHero did not return a healthy response")

    api = http.client.HTTPConnection(host, port, timeout=5)
    try:
        api.request("GET", "/servers", headers={"Authorization": f"Basic {credentials}"})
        api_response = api.getresponse()
        if api_response.status not in {200, 302}:
            raise RuntimeError("PgHero API endpoints not reachable")
    finally:
        api.close()


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
    unavailable = {}
    if project_name:
        ip_addr = container_ip(project_name, "postgres")
        assert ip_addr.count(".") == 3
        for sidecar in ("pgbouncer", "valkey", "memcached", "pghero"):
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
    pgbouncer_host_port = resolve_port(
        "PGBOUNCER_HOST_PORT", env_values.get("PGBOUNCER_PORT", "6432")
    )
    pghero_host_port = int(env["PGHERO_PORT"])

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

    pghero_issue = unavailable.pop("pghero", None)
    if pghero_issue:
        pytest.fail(f"PgHero sidecar unavailable: {pghero_issue}")
    pghero_primary = ("127.0.0.1", pghero_host_port)
    pghero_secondary = container_endpoint_factory(project_name, "pghero", 8080)
    pghero_host, pghero_port = pick_endpoint(
        pghero_primary,
        pghero_secondary,
        primary_retries=30,
        secondary_retries=30,
    )

    pgbouncer_available = "pgbouncer" not in unavailable
    if not pgbouncer_available:
        warnings.warn(
            f"Skipping PgBouncer checks: {unavailable['pgbouncer']}", RuntimeWarning
        )
    else:
        pgbouncer_primary = ("127.0.0.1", pgbouncer_host_port)
        pgbouncer_secondary = container_endpoint_factory(project_name, "pgbouncer", 6432)
        pgbouncer_host, pgbouncer_port = pick_endpoint(
            pgbouncer_primary,
            pgbouncer_secondary,
            primary_retries=30,
            secondary_retries=30,
        )

    if pgbouncer_available:
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

    valkey_password = read_secret("secrets/valkey_password")
    check_valkey(valkey_host, valkey_port, valkey_password)
    check_memcached(memcached_host, memcached_port)

    pghero_user = env_values.get("PGHERO_USER", "admin")
    pghero_password = env_values.get("PGHERO_PASSWORD", "change_me")
    try:
        check_pghero(pghero_host, pghero_port, pghero_user, pghero_password)
    except RuntimeError as exc:
        if project_name:
            container = container_name(project_name, "pghero")
            logs = subprocess.run(
                ["docker", "logs", container], capture_output=True, text=True
            )
            if logs.stdout:
                print("[pghero logs]\n", logs.stdout)
            if logs.stderr:
                print("[pghero stderr]\n", logs.stderr)
        raise

    valkey_password = read_secret("secrets/valkey_password")
    check_valkey(valkey_host, valkey_port, valkey_password)
    check_memcached(memcached_host, memcached_port)

    pghero_user = env_values.get("PGHERO_USER", "admin")
    pghero_password = env_values.get("PGHERO_PASSWORD", "change_me")
    check_pghero(pghero_host, pghero_port, pghero_user, pghero_password)


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
    run_manage(
        env,
        "daily-maintenance",
        "--root",
        "./backups/ci",
        "--container-root",
        "/backups/ci",
    )
    run_manage(env, "audit-cron")
    run_manage(env, "audit-squeeze")
    daily_dirs = sorted((ROOT / "backups" / "ci").glob("*/"))
    assert daily_dirs
    daily_dir = daily_dirs[-1]
    print("daily_dir entries:", sorted(p.name for p in daily_dir.iterdir()))
    assert (daily_dir / "index_bloat.csv").exists()
    assert (daily_dir / "schema_snapshot.csv").exists()
    assert (daily_dir / "maintenance_report.html").exists()
    assert (daily_dir / "valkey-dump.rdb").exists()
    assert (daily_dir / "valkey-info.txt").exists()
    assert (daily_dir / "pgbouncer-stats.csv").exists()
    assert (daily_dir / "pgbouncer-pools.csv").exists()
    assert (daily_dir / "memcached-stats.txt").exists()
    pgbadger_html = daily_dir / "pgbadger.html"
    assert pgbadger_html.exists() and pgbadger_html.stat().st_size > 0

    dump_files = sorted(daily_dir.glob("*.dump.gz"))
    assert dump_files, "expected at least one compressed dump"
    with gzip.open(dump_files[0], "rb") as fh:
        fh.read(1)

    memcached_stats = (daily_dir / "memcached-stats.txt").read_text()
    assert "STAT" in memcached_stats
    run_manage(env, "compact", "--level", "1")
    run_manage(env, "compact", "--level", "2")

    size_before = relation_size(env, "public.space_test")
    run_manage(env, "compact", "--level", "3", "--tables", "public.space_test")
    size_after_repack = relation_size(env, "public.space_test")
    assert size_after_repack <= size_before

    run_manage(env, "compact", "--level", "4", "--scope", "public.space_test", "--yes")
    size_after_vacuum = relation_size(env, "public.space_test")
    assert size_after_vacuum <= size_after_repack

    repack_logs = list((ROOT / "backups").glob("pg_repack-*.log"))
    vacuum_logs = list((ROOT / "backups").glob("vacuum-full-*.log"))
    assert repack_logs
    assert vacuum_logs

    run_manage(env, "backup", "--type=full")

    run_manage(env, "upgrade", "--new-version", "17")
    wait_for_ready(env)

    status = subprocess.run(
        [str(MANAGE), "status"], cwd=ROOT, env=env, capture_output=True, text=True
    )
    assert status.returncode == 0
    assert f"{project_name}_postgres" in status.stdout

    env_file = Path(env["ENV_FILE"])
    contents = env_file.read_text()
    assert "PG_VERSION=17" in contents

        run_manage(env, "down")


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
        wait_for_container(project_name, "logical_backup", retries=120, delay=2)
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
@pytest.mark.parametrize("extension", EXTENSIONS_TO_CHECK)
def test_extension_available(manage_env, extension):
    env, _ = manage_env
    run_manage(env, "build-image")
    run_manage(env, "up")
    try:
        wait_for_ready(env)
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
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "1", f"extension {extension} missing"
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
                        "INSERT INTO public.e2e_pool_test(worker_id) VALUES (%s) RETURNING id",
                        (idx,),
                    )
                    return cur.fetchone()[0]

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(worker, range(16)))

        assert len(set(results)) == 16
    finally:
        run_manage(env, "down")
        compose_down(env, volumes=True)


@pytest.mark.lint
def test_shell_scripts_lint():
    shellcheck = shutil.which("shellcheck")
    if shellcheck is None:
        pytest.skip("shellcheck not available")
    scripts = [
        "scripts/manage.sh",
        "scripts/daily_maintenance.sh",
        "scripts/pghero_entrypoint.sh",
        "pgbouncer/entrypoint.sh",
        "valkey/entrypoint.sh",
    ]
    result = subprocess.run([shellcheck, *scripts], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


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
        result = run_manage(
            env, "create-env", "--non-interactive", "--force", "--output", str(target)
        )
        assert result.returncode == 0
        assert target.exists()
        content = target.read_text().splitlines()
        env_map = {}
        for line in content:
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                env_map[key.strip()] = value.strip()

        assert (
            env_map["POSTGRES_SUPERUSER_PASSWORD_FILE"]
            == "./secrets/postgres_superuser_password"
        )
        assert env_map["POSTGRES_SUPERUSER_PASSWORD"] == ""
        assert env_map["POSTGRES_UID"] == str(os.getuid())
        assert env_map["POSTGRES_GID"] == str(os.getgid())
        assert env_map["POSTGRES_MEMORY_LIMIT"].lower().endswith("g")
        assert env_map["POSTGRES_SHM_SIZE"].lower().endswith("g")
        assert float(env_map["POSTGRES_CPU_LIMIT"]) >= 1

        env_mode = stat.S_IMODE(os.stat(target).st_mode)
        assert env_mode == 0o600

        assert env_map["VALKEY_PASSWORD_FILE"] == "./secrets/valkey_password"
        assert (
            env_map["PGBOUNCER_AUTH_PASSWORD_FILE"]
            == "./secrets/pgbouncer_auth_password"
        )
        assert (
            env_map["PGBOUNCER_STATS_PASSWORD_FILE"]
            == "./secrets/pgbouncer_stats_password"
        )

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
