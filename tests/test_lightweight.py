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
