#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

"""Compare installed extension versions against upstream releases."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from packaging.version import Version

DEFAULT_ENV_PATH = Path(__file__).resolve().parents[1] / ".env"
DEFAULT_COMPOSE_BIN = os.environ.get("COMPOSE_BIN", "docker compose")
DEFAULT_SERVICE = os.environ.get("POSTGRES_SERVICE_NAME", "postgres")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")


@dataclass
class ComponentConfig:
    name: str
    source: str
    repo: Optional[str] = None
    alias: Optional[str] = None
    pattern: Optional[str] = None
    kind: str = "extension"  # extension|server|core


CONFIG: Dict[str, ComponentConfig] = {
    "postgresql": ComponentConfig(name="postgresql", source="github", repo="postgres/postgres", kind="server"),
    "postgis": ComponentConfig(name="postgis", source="github", repo="postgis/postgis"),
    "postgis_raster": ComponentConfig(name="postgis_raster", source="alias", alias="postgis"),
    "postgis_topology": ComponentConfig(name="postgis_topology", source="alias", alias="postgis"),
    "postgis_tiger_geocoder": ComponentConfig(name="postgis_tiger_geocoder", source="alias", alias="postgis"),
    "address_standardizer": ComponentConfig(name="address_standardizer", source="alias", alias="postgis"),
    "address_standardizer_data_us": ComponentConfig(name="address_standardizer_data_us", source="alias", alias="postgis"),
    "vector": ComponentConfig(name="vector", source="github", repo="pgvector/pgvector"),
    "pgvector": ComponentConfig(name="pgvector", source="alias", alias="vector"),
    "age": ComponentConfig(name="age", source="github", repo="apache/age"),
    "pg_cron": ComponentConfig(name="pg_cron", source="github", repo="citusdata/pg_cron"),
    "pg_partman": ComponentConfig(name="pg_partman", source="github", repo="pgpartman/pg_partman"),
    "pg_partman_bgw": ComponentConfig(name="pg_partman_bgw", source="alias", alias="pg_partman"),
    "hypopg": ComponentConfig(name="hypopg", source="github", repo="HypoPG/hypopg"),
    "pg_repack": ComponentConfig(name="pg_repack", source="github", repo="reorg/pg_repack", pattern=r"(?i)(?:ver[_-])?([0-9_.]+)"),
    "pg_squeeze": ComponentConfig(name="pg_squeeze", source="github", repo="cybertec-postgresql/pg_squeeze"),
    "pgtap": ComponentConfig(name="pgtap", source="github", repo="theory/pgtap"),
    "pgrouting": ComponentConfig(name="pgrouting", source="github", repo="pgRouting/pgrouting"),
    # Core extensions follow server lifecycle
    "pg_stat_statements": ComponentConfig(name="pg_stat_statements", source="alias", alias="postgresql", kind="core"),
    "pg_buffercache": ComponentConfig(name="pg_buffercache", source="alias", alias="postgresql", kind="core"),
    "pgcrypto": ComponentConfig(name="pgcrypto", source="alias", alias="postgresql", kind="core"),
    "citext": ComponentConfig(name="citext", source="alias", alias="postgresql", kind="core"),
    "hstore": ComponentConfig(name="hstore", source="alias", alias="postgresql", kind="core"),
    "pg_trgm": ComponentConfig(name="pg_trgm", source="alias", alias="postgresql", kind="core"),
    "uuid-ossp": ComponentConfig(name="uuid-ossp", source="alias", alias="postgresql", kind="core"),
    "fuzzystrmatch": ComponentConfig(name="fuzzystrmatch", source="alias", alias="postgresql", kind="core"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", type=Path, default=DEFAULT_ENV_PATH)
    parser.add_argument("--compose-bin", default=DEFAULT_COMPOSE_BIN)
    parser.add_argument("--service", default=DEFAULT_SERVICE)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--only-outdated", action="store_true")
    parser.add_argument("--inside-container", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    return parser.parse_args()


def load_env(path: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


def run_command(cmd: List[str]) -> str:
    result = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return result.stdout.strip()


def fetch_installed_versions(args: argparse.Namespace, env: Dict[str, str]) -> Tuple[str, Dict[str, str]]:
    superuser = env.get("POSTGRES_SUPERUSER", "postgres")
    database = env.get("POSTGRES_DB", "postgres")

    if args.inside_container:
        base_cmd = ["psql", "--username", superuser, "--dbname", database]
    else:
        base_cmd = args.compose_bin.split() + ["exec", "-T", args.service, "psql", "--username", superuser, "--dbname", database]

    server_cmd = base_cmd + ["-t", "--command", "SHOW server_version;"]
    server_version = run_command(server_cmd).strip()

    ext_cmd = base_cmd + ["--csv", "--no-align", "--command", "SELECT extname, extversion FROM pg_extension;"]
    output = run_command(ext_cmd)
    installed: Dict[str, str] = {}
    reader = csv.reader(output.splitlines())
    for row in reader:
        if len(row) != 2:
            continue
        installed[row[0]] = row[1]
    return server_version, installed


def normalize_version(tag: str, pattern: Optional[str] = None) -> Optional[str]:
    if not tag:
        return None
    if pattern:
        match = re.search(pattern, tag)
        if match:
            tag = match.group(1)
        else:
            return None
    tag = tag.strip()
    tag = re.sub(r"^(REL[_-])", "", tag, flags=re.IGNORECASE)
    tag = re.sub(r"^(VER[_-])", "", tag, flags=re.IGNORECASE)
    tag = tag.lstrip("vV")
    tag = tag.replace("_", ".")
    tag = tag.strip()
    return tag or None


def compare_versions(installed: Optional[str], latest: Optional[str]) -> str:
    if not installed:
        return "not_installed"
    if not latest:
        return "unknown"
    if Version:
        try:
            if Version(installed) < Version(latest):
                return "outdated"
            return "current"
        except Exception:
            pass

    def split(ver: str) -> List[int]:
        return [int(part) for part in re.findall(r"\d+", ver)]

    try:
        if split(installed) < split(latest):
            return "outdated"
    except ValueError:
        return "unknown"
    return "current"


def fetch_github_latest(repo: str) -> Optional[str]:
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    try:
        import urllib.request

        headers = {"User-Agent": "core-data-version-check"}
        if GITHUB_TOKEN:
            headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"  # pragma: allowlist secret
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)
    except Exception:
        return None
    tag = data.get("tag_name") or data.get("name")
    return tag


def resolve_latest(component: str, cache: Dict[str, Optional[str]]) -> Optional[str]:
    if component in cache:
        return cache[component]
    cfg = CONFIG.get(component)
    if not cfg:
        cache[component] = None
        return None
    if cfg.source == "alias" and cfg.alias:
        latest = resolve_latest(cfg.alias, cache)
        cache[component] = latest
        return latest
    if cfg.source == "github" and cfg.repo:
        tag = fetch_github_latest(cfg.repo)
        latest = normalize_version(tag or "", cfg.pattern)
        cache[component] = latest
        return latest
    cache[component] = None
    return None


def main() -> int:
    args = parse_args()
    env = load_env(args.env)

    server_version, installed = fetch_installed_versions(args, env)

    cache: Dict[str, Optional[str]] = {"postgresql": normalize_version(server_version)}
    rows: List[Dict[str, str]] = []

    for name, cfg in CONFIG.items():
        installed_version = server_version if cfg.kind == "server" else installed.get(name)
        if cfg.kind == "core":
            latest_version = server_version
        else:
            latest_version = resolve_latest(name, cache)
            if latest_version and cfg.kind == "server":
                latest_version = normalize_version(latest_version)
        status = compare_versions(installed_version, latest_version)
        rows.append({
            "component": name,
            "installed_version": installed_version or "",
            "latest_version": latest_version or "",
            "status": status,
            "source": (cfg.alias or cfg.repo or cfg.source or ""),
        })

    display_rows = rows
    if args.only_outdated:
        display_rows = [row for row in rows if row["status"] == "outdated"]

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("w", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=["component", "installed_version", "latest_version", "status", "source"])
            writer.writeheader()
            writer.writerows(display_rows)

    if not args.quiet:
        if not display_rows and args.only_outdated:
            print("All tracked components are up to date.")
        else:
            widths = {
                key: max(len(key), *(len(row[key]) for row in display_rows))
                for key in ["component", "installed_version", "latest_version"]
            }
            fmt = f"{{:<{widths['component']}}}  {{:<{widths['installed_version']}}}  {{:<{widths['latest_version']}}}  {{}}"
            header = fmt.format("Component", "Installed", "Latest", "Status")
            print(header)
            print("-" * len(header))
            for row in display_rows:
                print(fmt.format(
                    row["component"],
                    row["installed_version"],
                    row["latest_version"],
                    row["status"],
                ))

    return 0


if __name__ == "__main__":
    sys.exit(main())
