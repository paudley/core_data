# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

import os
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

    subnet_a = int(uuid.uuid4().hex[:2], 16)
    subnet_b = int(uuid.uuid4().hex[2:4], 16)
    replacements = {
        "PG_DATA_DIR": str(workdir / "postgres_data"),
        "CORE_DATA_PGBACKREST_REPO_DIR": str(workdir / "pgbackrest_repo"),
        "PGHERO_DATA_DIR": str(workdir / "pghero_data"),
        "PGHERO_PORT": "18080",
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

    for key in ("PG_DATA_DIR", "CORE_DATA_PGBACKREST_REPO_DIR", "PGHERO_DATA_DIR"):
        directory = Path(replacements[key])
        directory.mkdir(parents=True, exist_ok=True)
        directory.chmod(0o777)

    backups_dir = ROOT / "backups"
    backups_dir.mkdir(exist_ok=True)
    backups_dir.chmod(0o777)

    env = os.environ.copy()
    env["ENV_FILE"] = str(env_file)
    project_name = env.setdefault("COMPOSE_PROJECT_NAME", f"core_data_ci_{uuid.uuid4().hex[:8]}")
    env["PG_BADGER_JOBS"] = "1"

    repo_env_path = ROOT / ".env"
    backup_env_bytes = None
    had_env = repo_env_path.exists() or repo_env_path.is_symlink()
    if had_env:
        backup_env_bytes = repo_env_path.read_bytes()
    repo_env_path.write_text(env_file.read_text())

    try:
        yield env, project_name
    finally:
        subprocess.run(["docker", "compose", "down", "-v"], cwd=ROOT, env=env, check=False)
        subprocess.run(["docker", "pull", "busybox"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for key in ("PG_DATA_DIR", "CORE_DATA_PGBACKREST_REPO_DIR", "PGHERO_DATA_DIR"):
            directory = Path(replacements[key])
            if directory.exists():
                subprocess.run(["chmod", "-R", "777", str(directory)], check=False)
                subprocess.run([
                    "docker", "run", "--rm",
                    "-v", f"{directory}:/target",
                    "busybox", "sh", "-c",
                    "rm -rf /target/* /target/.[!.]* /target/..?*"
                ], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["rmdir", str(directory)], check=False)
        env_file.unlink(missing_ok=True)
        if had_env:
            repo_env_path.write_bytes(backup_env_bytes)
        else:
            repo_env_path.unlink(missing_ok=True)


def run_manage(env, *args, check=True):
    subprocess.run([str(MANAGE), *args], cwd=ROOT, env=env, check=check)


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

    run_manage(env, "pgbadger-report", "--since", "yesterday", "--output", "/backups/ci-report.html")
    run_manage(env, "daily-maintenance", "--root", "./backups/ci", "--container-root", "/backups/ci")

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
