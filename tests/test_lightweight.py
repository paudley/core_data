# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

import os
import stat
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANAGE = ROOT / "scripts" / "manage.sh"
PGTUNE = ROOT / "postgres" / "tools" / "pgtune.py"


def test_pgtune_help():
    result = subprocess.run(
        ["python3", str(PGTUNE), "--help"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    # optparse prints usage header to stdout
    assert "Usage" in result.stdout


def test_manage_help_without_docker(tmp_path):
    fake_bin = tmp_path / "docker"
    fake_bin.write_text("#!/usr/bin/env bash\nexit 0\n")
    fake_bin.chmod(stat.S_IRWXU)

    env = os.environ.copy()
    env["PATH"] = f"{tmp_path}:{env['PATH']}"
    env["ENV_FILE"] = str(ROOT / ".env.example")

    result = subprocess.run(
        [str(MANAGE), "help"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    assert "core_data management CLI" in result.stdout


def test_create_user_provisions_rabbitmq_user_when_enabled(tmp_path):
	fake_bin = tmp_path / "bin"
	fake_bin.mkdir()
	log_path = tmp_path / "docker.log"
	docker = fake_bin / "docker"
	docker.write_text(
		"""#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "compose" && "${2:-}" == "config" && "${3:-}" == "--services" ]]; then
  printf '%s\\n' postgres rabbitmq
  exit 0
fi
printf '%s\\n' "$*" >> "${DOCKER_LOG}"
cat >/dev/null
"""
	)
	docker.chmod(stat.S_IRWXU)

	env = os.environ.copy()
	env["PATH"] = f"{fake_bin}:{env['PATH']}"
	env["ENV_FILE"] = str(ROOT / ".env.example")
	env["DOCKER_LOG"] = str(log_path)

	result = subprocess.run(
		[str(MANAGE), "create-user", "app_user", "app_password"],
		cwd=ROOT,
		env=env,
		capture_output=True,
		text=True,
	)

	assert result.returncode == 0, result.stderr
	log = log_path.read_text()
	assert "exec -T --user postgres postgres env" in log
	assert "exec -T rabbitmq sh -eu -c" in log
	assert "rabbitmqctl add_user" in log


def test_create_db_provisions_rabbitmq_vhost_when_enabled(tmp_path):
	fake_bin = tmp_path / "bin"
	fake_bin.mkdir()
	log_path = tmp_path / "docker.log"
	docker = fake_bin / "docker"
	docker.write_text(
		"""#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "compose" && "${2:-}" == "config" && "${3:-}" == "--services" ]]; then
  printf '%s\\n' postgres rabbitmq
  exit 0
fi
printf '%s\\n' "$*" >> "${DOCKER_LOG}"
cat >/dev/null
"""
	)
	docker.chmod(stat.S_IRWXU)

	env = os.environ.copy()
	env["PATH"] = f"{fake_bin}:{env['PATH']}"
	env["ENV_FILE"] = str(ROOT / ".env.example")
	env["DOCKER_LOG"] = str(log_path)

	result = subprocess.run(
		[str(MANAGE), "create-db", "app_db", "app_user"],
		cwd=ROOT,
		env=env,
		capture_output=True,
		text=True,
	)

	assert result.returncode == 0, result.stderr
	log = log_path.read_text()
	assert "rabbitmqctl add_vhost" in log
	assert 'rabbitmqctl set_permissions -p "${vhost}" "${owner}" ".*" ".*" ".*"' in log
