# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

import os
import random
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

    pghero_port = random.randint(20000, 40000)

    subnet_a = int(uuid.uuid4().hex[:2], 16)
    subnet_b = int(uuid.uuid4().hex[2:4], 16)
    replacements = {
        "PG_DATA_DIR": str(workdir / "postgres_data"),
        "CORE_DATA_PGBACKREST_REPO_DIR": str(workdir / "pgbackrest_repo"),
        "PGHERO_DATA_DIR": str(workdir / "pghero_data"),
        "PGHERO_PORT": str(pghero_port),
        "DOCKER_NETWORK_NAME": f"core_data_net_{uuid.uuid4().hex[:8]}",
        "DOCKER_NETWORK_SUBNET": f"10.{subnet_a}.{subnet_b}.0/24",
        "DATABASES_TO_CREATE": "app_main:app_user:change_me",
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

    managed_paths = [Path(replacements[key]) for key in ("PG_DATA_DIR", "CORE_DATA_PGBACKREST_REPO_DIR", "PGHERO_DATA_DIR")]
    for directory in managed_paths:
        directory.mkdir(parents=True, exist_ok=True)
        try:
            directory.chmod(0o777)
        except PermissionError:
            pass

    backups_target = workdir / "backups"
    backups_target.mkdir(parents=True, exist_ok=True)
    try:
        backups_target.chmod(0o777)
    except PermissionError:
        pass

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
    project_name = env.setdefault("COMPOSE_PROJECT_NAME", f"core_data_ci_{uuid.uuid4().hex[:8]}")
    env["PG_BADGER_JOBS"] = "1"

    repo_env_path = ROOT / ".env"
    had_env = repo_env_path.exists() or repo_env_path.is_symlink()
    backup_env_bytes = repo_env_path.read_bytes() if had_env else None
    repo_env_path.write_text(env_file.read_text())

    try:
        yield env, project_name
    finally:
        subprocess.run(["docker", "compose", "down", "-v"], cwd=ROOT, env=env, check=False)
        subprocess.run(["docker", "pull", "busybox"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for directory in managed_paths:
            if directory.exists():
                subprocess.run([
                    "docker", "run", "--rm",
                    "-v", f"{directory.resolve()}:/target",
                    "busybox", "sh", "-c",
                    "rm -rf /target/* /target/.[!.]* /target/..?*"
                ], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["rmdir", str(directory)], check=False)
        if backups_target.exists():
            subprocess.run([
                "docker", "run", "--rm",
                "-v", f"{backups_target.resolve()}:/target",
                "busybox", "sh", "-c",
                "rm -rf /target/* /target/.[!.]* /target/..?*"
            ], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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

    run_manage(env, "create-user", "ci_user", "ci_password")
    run_manage(env, "create-db", "ci_db", "ci_user")
    run_manage(env, "dump", "ci_db")
    run_manage(env, "dump-sql", "ci_db")
    run_manage(env, "psql", "-d", "ci_db", "-c", "CREATE TABLE IF NOT EXISTS public.space_test(id serial PRIMARY KEY, payload text);")
    run_manage(env, "psql", "-d", "ci_db", "-c", "INSERT INTO public.space_test(payload) SELECT repeat('x', 1000) FROM generate_series(1, 1000);")
    run_manage(env, "psql", "-d", "ci_db", "-c", "DELETE FROM public.space_test WHERE id % 2 = 0;")
    run_manage(env, "exercise-extensions", "--db", "ci_db")
    run_manage(env, "pgtap-smoke", "--db", "ci_db")

    run_manage(env, "pgbadger-report", "--since", "yesterday", "--output", "/backups/ci-report.html")
    run_manage(env, "daily-maintenance", "--root", "./backups/ci", "--container-root", "/backups/ci")
    run_manage(env, "audit-cron")
    run_manage(env, "audit-squeeze")
    daily_dirs = sorted((ROOT / "backups" / "ci").glob("*/"))
    assert daily_dirs
    daily_dir = daily_dirs[-1]
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

    run_manage(env, "stanza-create")
    run_manage(env, "backup", "--type=full")

    run_manage(env, "upgrade", "--new-version", "17")
    wait_for_ready(env)

    status = subprocess.run([str(MANAGE), "status"], cwd=ROOT, env=env, capture_output=True, text=True)
    assert status.returncode == 0
    assert f"{project_name}_postgres" in status.stdout

    env_file = Path(env["ENV_FILE"])
    contents = env_file.read_text()
    assert "PG_VERSION=17" in contents

    run_manage(env, "down")
