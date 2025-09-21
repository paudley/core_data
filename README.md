<!--
SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
SPDX-License-Identifier: MIT
-->

# core_data

[![CI](https://github.com/paudley/core_data/actions/workflows/ci.yml/badge.svg)](https://github.com/paudley/core_data/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A reproducible PostgreSQL 17 platform delivered as code. core_data builds a hardened database image with spatial, vector, and graph extensions, provisions PgHero for observability, and ships a management CLI that automates backups, restores, QA cloning, and upgrades. Everything lives in version control so environments can be rebuilt consistently across laptops, CI, and production.

## Why You Want This
- Run the same Postgres 17 stack everywhere: laptop, CI runner, or production.
- Ship with the heavy hitters pre-installed—PostGIS, pgvector, AGE, pg_cron, pgBackRest—without custom build scripts.
- Automate the boring-but-critical tasks: backups, restores, QA clones, log analytics, and even major version upgrades via pgautoupgrade.
- Treat your database like code with reproducible `.env` configs, templated init scripts, and a pytest smoke test that catches regressions early.


## Highlights
- Custom Docker image with PostGIS, pgvector, Apache AGE, pg_cron, pg_squeeze, pgAudit, pgBadger, pgBackRest, and pgtune baked in.
- Init scripts render configuration from templates, create application databases, and enable extensions automatically.
- `./scripts/manage.sh` wraps lifecycle tasks: image builds, `psql`, logical dumps, pgBackRest backups/restores, QA cloning, log analysis, daily maintenance, and major upgrades via pgautoupgrade.
- PgBackRest repository and PostgreSQL data directories mount from the host for durable backups and WAL archival.
- CI smoke test (`python -m pytest -k full_workflow`) provisions a stack, exercises critical commands, and verifies upgrade safety.

## Quick Start
1. Copy the template: `cp .env.example .env` and customize credentials, host paths, and network settings.
2. Build and start the stack:
   ```bash
   ./scripts/manage.sh build-image
   ./scripts/manage.sh up
   ```
3. Verify health:
   ```bash
   docker compose exec postgres pg_isready
   ./scripts/manage.sh psql -c 'SELECT 1;'
   ```
4. Explore the CLI: `./scripts/manage.sh help`

## Project Layout
```
core_data/
├── .env.example              # Template for environment-specific settings (never commit real secrets)
├── docker-compose.yml        # Orchestrates PostgreSQL and PgHero services
├── scripts/                  # Operator tooling (manage.sh + lib modules + maintenance workflow)
├── postgres/                 # Custom image build assets, configs, and initdb scripts
├── backups/                  # Host output directory for logical dumps and reports
├── data/                     # Host bind mounts for postgres_data / pgbackrest_repo / pghero_data
├── README.md                 # This guide
└── AGENTS.md                 # Contributor quick-reference & runbooks
```
Keep `data/` out of version control—it holds live cluster state and backup archives.

## Management CLI
`./scripts/manage.sh` is the operator entry point. Frequently used commands:

| Command | Description |
| --- | --- |
| `build-image` | Build the custom PostgreSQL image defined in `postgres/Dockerfile`. |
| `up` / `down` | Start or stop the Compose stack (volumes preserved). |
| `psql` | Open psql inside the container (respects `PGHOST`, `PGUSER`, etc.). |
| `dump` / `dump-sql` | Produce logical backups (custom or plain format) under `/backups`. |
| `restore-dump` | Drop and recreate a database before restoring a `.dump.gz`. |
| `backup` / `stanza-create` / `restore-snapshot` | Manage pgBackRest backups and restores. |
| `daily-maintenance` | Run dumps, log capture, pgBadger analysis, and retention pruning. |
| `provision-qa` | Differential backup + targeted restore for QA databases. |
| `upgrade --new-version` | Orchestrate pgautoupgrade (takes backups, validates base image, restarts). |

The CLI sources modular helpers from `scripts/lib/` so each function can be imported by tests or future automation.

## Automation & Testing
- **CI Workflow:** `.github/workflows/ci.yml` builds the image, runs `python -m pytest -k full_workflow`, and uploads generated backups for inspection.
- **Smoke Test:** `tests/test_manage.py` spins up a disposable environment, exercises key CLI commands (including `daily-maintenance`, pgBackRest, and `upgrade`), and tears everything down. Run locally with `python -m pytest -k full_workflow` (Docker required).
- **Documentation:** `AGENTS.md` offers contributor runbooks and on-call notes.

## Credits
Thank you to the maintainers and communities behind the components that make core_data possible:
- [PostgreSQL](https://www.postgresql.org/) – the database at the heart of the platform.
- [Docker](https://www.docker.com/) & [Docker Compose](https://docs.docker.com/compose/) – containerization and orchestration.
- [PgBackRest](https://pgbackrest.org/) – resilient backup and restore tooling.
- [PgHero](https://github.com/ankane/pghero) – query insights and monitoring.
- [pgBadger](https://github.com/darold/pgbadger) – PostgreSQL log analytics.
- [pg_cron](https://github.com/citusdata/pg_cron) – database-native scheduling.
- [pg_squeeze](https://github.com/cybertec-postgresql/pg_squeeze) – automatic bloat mitigation.
- [pgvector](https://github.com/pgvector/pgvector) – high-dimensional vector search.
- [PostGIS](https://postgis.net/) – spatial superpowers for PostgreSQL.
- [Apache AGE](https://age.apache.org/) – graph database extension.
- [pgaudit](https://github.com/pgaudit/pgaudit) – enhanced auditing.
- [pg_repack](https://github.com/reorg/pg_repack) & [pgtap](https://github.com/theory/pgtap) – maintenance & testing extensions.

Their work powers the database-as-code experience delivered by core_data.
