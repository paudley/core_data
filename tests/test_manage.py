# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

import json
import os
import secrets
import socket
import stat
import subprocess
import time
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MANAGE = ROOT / "scripts" / "manage.sh"
ENV_EXAMPLE = ROOT / ".env.example"


@pytest.fixture(scope="module")
def manage_env(tmp_path_factory):
    workdir = tmp_path_factory.mktemp("core_data_ci")
    env_file = ROOT / ".env.test"

    def find_free_port():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    pghero_port = find_free_port()
    valkey_port = find_free_port()
    pgbouncer_port = find_free_port()
    memcached_port = find_free_port()

    subnet_a = int(uuid.uuid4().hex[:2], 16)
    subnet_b = int(uuid.uuid4().hex[2:4], 16)
    replacements = {
        "PGHERO_PORT": str(pghero_port),
        "DOCKER_NETWORK_NAME": f"core_data_net_{uuid.uuid4().hex[:8]}",
        "DOCKER_NETWORK_SUBNET": f"10.{subnet_a}.{subnet_b}.0/24",
        "DATABASES_TO_CREATE": "app_main:app_user:change_me",
        "VALKEY_PORT": str(valkey_port),
        "PGBOUNCER_PORT": str(pgbouncer_port),
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


def test_full_workflow(manage_env):
    env, project_name = manage_env

    run_manage(env, "build-image")
    run_manage(env, "up")
    wait_for_ready(env)
    run_manage(env, "stanza-create")

    run_manage(env, "create-user", "ci_user", "ci_password")
    run_manage(env, "create-db", "ci_db", "ci_user")
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
