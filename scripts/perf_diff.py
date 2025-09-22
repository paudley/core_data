#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

"""Compare two pg_stat_statements snapshots and report deltas."""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from typing import Dict, Tuple

Snapshot = Dict[Tuple[str, str], Dict[str, float]]


def load_snapshot(path: Path) -> Snapshot:
    data: Snapshot = {}
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        required = {"datname", "queryid", "calls", "total_exec_time", "rows"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"{path} missing columns: {', '.join(sorted(missing))}")
        for row in reader:
            key = (row["datname"], row["queryid"])
            data[key] = {
                "datname": row["datname"],
                "queryid": row["queryid"],
                "calls": float(row["calls"] or 0),
                "total_exec_time": float(row["total_exec_time"] or 0),
                "rows": float(row["rows"] or 0),
            }
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--compare", required=True, type=Path)
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()

    base = load_snapshot(args.base)
    compare = load_snapshot(args.compare)

    deltas = []
    for key in set(base) | set(compare):
        b = base.get(key, {"calls": 0.0, "total_exec_time": 0.0, "rows": 0.0})
        c = compare.get(key, {"calls": 0.0, "total_exec_time": 0.0, "rows": 0.0})
        delta = {
            "datname": key[0],
            "queryid": key[1],
            "calls_delta": c["calls"] - b["calls"],
            "exec_time_delta": c["total_exec_time"] - b["total_exec_time"],
            "rows_delta": c["rows"] - b["rows"],
        }
        deltas.append(delta)

    deltas.sort(key=lambda d: d["exec_time_delta"], reverse=True)
    limit = args.limit if args.limit > 0 else len(deltas)

    writer = csv.writer(sys.stdout)
    writer.writerow(["datname", "queryid", "calls_delta", "exec_time_delta", "rows_delta"])
    for row in deltas[:limit]:
        writer.writerow([
            row["datname"],
            row["queryid"],
            f"{row['calls_delta']:.2f}",
            f"{row['exec_time_delta']:.2f}",
            f"{row['rows_delta']:.2f}",
        ])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
