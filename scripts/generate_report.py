#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

"""Generate an HTML maintenance summary for daily outputs."""

from __future__ import annotations

import argparse
import csv
import html
from pathlib import Path
from typing import List, Dict, Tuple

SECTION_FILES: List[Tuple[str, str]] = [
    ("Autovacuum Findings", "autovacuum_findings.csv"),
    ("Index Bloat", "index_bloat.csv"),
    ("pg_squeeze Activity", "pg_squeeze.csv"),
    ("pg_cron Schedule", "cron_schedule.csv"),
    ("Replication Lag", "replication_lag.csv"),
    ("Role Audit", "role_audit.csv"),
    ("Extension Audit", "extension_audit.csv"),
    ("Security Audit", "security_audit.txt"),
    ("pg_stat_statements Snapshot", "pg_stat_statements.csv"),
    ("Schema Snapshot", "schema_snapshot.csv"),
    ("pgAudit Summary", "pgaudit_summary.csv"),
]


def load_csv(path: Path, limit: int = 10) -> Tuple[List[str], List[Dict[str, str]], int]:
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)
    return reader.fieldnames or [], rows[:limit], len(rows)


def render_table(headers: List[str], rows: List[Dict[str, str]]) -> str:
    if not headers or not rows:
        return "<p>No rows</p>"
    head_html = "".join(f"<th>{html.escape(h)}</th>" for h in headers)
    body_rows = []
    for row in rows:
        body_cells = "".join(html.escape(row.get(h, "")) for h in headers)
        body_rows.append(f"<tr><td>{'</td><td>'.join(html.escape(row.get(h, '')) for h in headers)}</td></tr>")
    body_html = "".join(body_rows)
    return f"<table><thead><tr>{head_html}</tr></thead><tbody>{body_html}</tbody></table>"


def render_text(path: Path, limit: int = 2000) -> str:
    text = path.read_text()
    snippet = text[:limit]
    escaped = html.escape(snippet)
    if len(text) > limit:
        escaped += "\n…"
    return f"<pre>{escaped}</pre>"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rows", type=int, default=10, help="Rows per table to render")
    args = parser.parse_args()

    sections: List[str] = []

    for title, filename in SECTION_FILES:
        path = args.input / filename
        if not path.exists():
            continue
        if path.suffix == ".txt":
            content = render_text(path)
            sections.append(f"<section><h2>{html.escape(title)}</h2>{content}</section>")
            continue
        headers, rows, total = load_csv(path, args.rows)
        table_html = render_table(headers, rows)
        sections.append(
            f"<section><h2>{html.escape(title)} (showing {min(len(rows), args.rows)} of {total})" \
            f"</h2>{table_html}</section>"
        )

    pg_badger = args.input / "pgbadger.html"
    if pg_badger.exists():
        sections.append(
            f"<section><h2>pgBadger Report</h2><p>See <a href='pgbadger.html'>pgbadger.html</a></p></section>"
        )

    if not sections:
        sections.append("<p>No reports generated.</p>")

    html_doc = """<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\">
  <title>core_data Maintenance Report</title>
  <style>
    body { font-family: sans-serif; margin: 1.5rem; }
    table { border-collapse: collapse; margin-bottom: 1.5rem; width: 100%; }
    th, td { border: 1px solid #ddd; padding: 0.4rem; font-size: 0.9rem; }
    th { background-color: #f2f2f2; text-align: left; }
    section { margin-bottom: 2rem; }
  </style>
</head>
<body>
  <h1>core_data Maintenance Report</h1>
  <p>Generated from {directory}</p>
  {sections}
</body>
</html>
""".format(directory=html.escape(str(args.input)), sections="\n".join(sections))

    args.output.write_text(html_doc)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
