# SPDX-FileCopyrightText: 2026 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

"""Tests for the data-cleanup management command.

The scenarios use isolated temporary data roots so the command can prove its
selection rules without touching local service state. They also replace Docker
Compose with a tiny fake binary, which keeps the safety-gate behavior testable
without requiring containers. These tests cover the operator contract for
dry-run reporting, targeted deletion, and running-stack refusal.
"""

import json
import os
import stat
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANAGE = ROOT / "scripts" / "manage.sh"


def _write_fake_compose_bin(tmp_path: Path, *, running: bool = False) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    docker = bin_dir / "docker"
    docker.write_text("#!/usr/bin/env bash\nexit 0\n")
    docker.chmod(stat.S_IRWXU)

    compose = bin_dir / "fake-compose"
    compose.write_text(
        "#!/usr/bin/env bash\n"
        'if [[ "${1:-}" == "ps" && "${2:-}" == "-q" ]]; then\n'
        f"  {'echo core_data_postgres_1' if running else ':'}\n"
        "  exit 0\n"
        "fi\n"
        "exit 0\n"
    )
    compose.chmod(stat.S_IRWXU)
    return bin_dir


def _run_data_cleanup(
    tmp_path: Path,
    data_root: Path,
    *args: str,
    running: bool = False,
) -> subprocess.CompletedProcess[str]:
    bin_dir = _write_fake_compose_bin(tmp_path, running=running)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["COMPOSE_BIN"] = "fake-compose"
    env["CORE_DATA_DATA_ROOT"] = str(data_root)
    return subprocess.run(
        [str(MANAGE), "data-cleanup", *args],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def _make_stash(path: Path, *, old: bool) -> None:
    path.mkdir(parents=True)
    payload = path / "payload"
    payload.write_text("data")
    if old:
        old_time = time.time() - (8 * 24 * 60 * 60)
        os.utime(payload, (old_time, old_time))
        os.utime(path, (old_time, old_time))


def test_data_cleanup_dry_run_reports_stale_pytest_backups(tmp_path: Path) -> None:
    """Verify dry-run selection for stale pytest backup directories.

    The command should report only stale entries under `.pytest_backups`.
    Recent stashes and live service directories must remain outside the
    candidate list.
    """
    data_root = tmp_path / "data"
    backup_root = data_root / ".pytest_backups"
    old_stash = backup_root / "postgres_wal_old"
    recent_stash = backup_root / "postgres_wal_recent"
    live_data = data_root / "postgres_wal"
    _make_stash(old_stash, old=True)
    _make_stash(recent_stash, old=False)
    _make_stash(live_data, old=True)

    result = _run_data_cleanup(tmp_path, data_root, "--json")

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["mode"] == "dry-run"
    assert payload["candidates"] == 1
    assert payload["paths"] == [str(old_stash)]
    assert old_stash.exists()
    assert recent_stash.exists()
    assert live_data.exists()


def test_data_cleanup_execute_removes_only_stale_pytest_backups(
    tmp_path: Path,
) -> None:
    """Verify execute mode deletes only stale pytest backup directories.

    The command should remove the stale stash selected by the default retention.
    It must leave recent pytest stashes and similarly named live service
    directories in place.
    """
    data_root = tmp_path / "data"
    backup_root = data_root / ".pytest_backups"
    old_stash = backup_root / "postgres_data_old"
    recent_stash = backup_root / "postgres_data_recent"
    live_data = data_root / "postgres_data"
    _make_stash(old_stash, old=True)
    _make_stash(recent_stash, old=False)
    _make_stash(live_data, old=True)

    result = _run_data_cleanup(tmp_path, data_root, "--execute", "--json")

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["mode"] == "execute"
    assert payload["candidates"] == 1
    assert not old_stash.exists()
    assert recent_stash.exists()
    assert live_data.exists()


def test_data_cleanup_execute_refuses_when_compose_containers_running(
    tmp_path: Path,
) -> None:
    """Verify execute mode refuses to run while containers are active.

    The fake Compose binary reports a running container to exercise the safety
    gate. The stale stash must remain present when that gate blocks deletion.
    """
    data_root = tmp_path / "data"
    old_stash = data_root / ".pytest_backups" / "postgres_wal_old"
    _make_stash(old_stash, old=True)

    result = _run_data_cleanup(tmp_path, data_root, "--execute", running=True)

    assert result.returncode == 1
    assert "refusing to delete while compose containers are running" in result.stderr
    assert old_stash.exists()
