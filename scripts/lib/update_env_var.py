#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

"""Update or append a KEY=value pair inside an env-style file."""

from __future__ import annotations

import sys
from pathlib import Path


def update_env_var(file_path: str, key: str, value: str) -> None:
    path = Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"env file not found: {file_path}")

    lines = []
    found = False
    for line in path.read_text().splitlines():
        if line.startswith(f"{key}="):
            lines.append(f"{key}={value}")
            found = True
        else:
            lines.append(line)

    if not found:
        lines.append(f"{key}={value}")

    path.write_text("\n".join(lines) + "\n")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: update_env_var.py <file> <key> <value>", file=sys.stderr)
        return 1

    _, file_path, key, value = argv
    try:
        update_env_var(file_path, key, value)
    except FileNotFoundError as exc:
        print(f"[update-env] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised via callers
    sys.exit(main(sys.argv))
