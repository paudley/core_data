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
- PGDATA, WAL, and pgBackRest now live on dedicated Docker named volumes for near-native Linux I/O, while `./backups` remains a bind mount for easy artifact exports.
- Secrets stay in Docker secrets (`POSTGRES_PASSWORD_FILE`) and the container runs as the non-root `postgres` UID/GID at all times, keeping the least-privilege posture consistent across init and steady state.
- TLS is enforced by default with auto-generated self-signed certificates (override with your own CA material), and a multi-stage health probe (`scripts/healthcheck.sh`) guards dependent services before they start.
- Logging uses Docker's `local` driver with rotation and non-blocking delivery, preventing runaway JSON logs from filling the host while preserving enough history for incident response.
- Optional profiles bundle ValKey, PgBouncer, and Memcached with sensible defaults, secrets, and CLI helpers so you can layer caches and pooling alongside PostgreSQL in one step.
- CI smoke test (`python -m pytest -k full_workflow`) provisions a stack, exercises critical commands, and verifies upgrade safety.

### Default Extension Bundle
core_data provisions a batteries-included extension stack in every non-template database at init time:

- **Performance & Observability** — `pg_stat_statements`, `auto_explain`, `pg_buffercache`.
- **Security & Compliance** — `pgaudit`, `pgcrypto`, `"uuid-ossp"`.
- **Developer Ergonomics** — `hstore`, `citext`, `pg_trgm`, `btree_gin`, `btree_gist`, `hypopg`.
- **Connectivity** — `postgres_fdw`, `dblink`.
- **Spatial, Vector, Graph** — `postgis`, `postgis_raster`, `postgis_topology`, `vector`, `age`.
- **Maintenance & Testing** — `pg_cron` (kept in the `postgres` database), `pg_partman`, `pg_repack`, `pg_squeeze`, `pgstattuple`, `pgtap`.
- **Geospatial Extras** — `postgis_tiger_geocoder`, `address_standardizer`, `address_standardizer_data_us`, `pgrouting`, `fuzzystrmatch`.

The same bundle is installed into `template1` so freshly created databases inherit the tooling automatically.

`pg_partman_bgw` is preloaded with a one-hour interval targeting the `postgres` database under the `postgres` superuser. Adjust `pg_partman_bgw.dbname`/`role` in `postgresql.conf.tpl` (or via `postgresql.pgtune.conf`) if you manage partitions from a different control schema.

Use `./scripts/manage.sh partman-show-config` to inspect tracked parents, `partman-maintenance` to run `run_maintenance_proc()` on demand, and `partman-create-parent schema.table control_column '1 day'` to bootstrap new partition sets without hand-writing SQL.

Run `./scripts/manage.sh async-queue bootstrap` when you want a lightweight background-job queue. It provisions an `asyncq.jobs` table plus helpers (`enqueue`, `dequeue`, `complete`, `fail`, `extend_lease`) that rely on `FOR UPDATE SKIP LOCKED`, `pg_notify`, and UUID leasing. Point a worker at the queue with `SELECT * FROM asyncq.dequeue('default');` in a loop and call `asyncq.complete(...)` or `asyncq.fail(...)` as you process jobs.

## Quick Start
1. Bootstrap environment config: `./scripts/manage.sh create-env` to walk through password creation, host UID/GID selection, and resource sizing (writes `.env` + secrets).
2. Build and start the stack:
   ```bash
   ./scripts/manage.sh build-image
   ./scripts/manage.sh up
   ```
3. Verify health (multi-stage probe):
   ```bash
   docker compose exec postgres /opt/core_data/scripts/healthcheck.sh
   ./scripts/manage.sh psql -c 'SELECT 1;'
 ```
4. Explore the CLI: `./scripts/manage.sh help`

## Project Ethos
We optimize for **data infrastructure as code ➜ automated admin ➜ human-friendly ➜ best-practices by default (including security and performance)**. In practice that means:

1. **Data infrastructure as code.** Declarative, reproducible Postgres once, versioned forever.
2. **Automated admin.** Every recurring task should be scriptable and CI-friendly before we worry about shell ergonomics.
3. **Human-friendly.** CLI helpers, sensible prompts, and clear docs matter—but only after the first two goals are met.
4. **Best-practices by default.** Security and performance guardrails (cap drops, TLS, tuned memory, backups) are enabled out of the box, with deliberate escape hatches when absolutely required.

See `docs/security_philosophy.md` for how capability hardening and related controls fit into that priority order.

## Operational Defaults
- **Resource guardrails.** Container memory, CPU, and shared memory limits come from `.env`, keeping pgtune advice and runtime constraints aligned. Adjust `POSTGRES_MEMORY_LIMIT`, `POSTGRES_CPU_LIMIT`, and `POSTGRES_SHM_SIZE` to match the host.
- **TLS everywhere.** PostgreSQL refuses non-SSL connections from the bridge network. Provide your own certificate/key via Docker secrets or rely on the init hook to mint a self-signed pair under `${PGDATA}/tls`.
- **Named volumes for PGDATA/WAL.** `pgdata`, `pgwal`, and `pgbackrest` volumes provide near-native I/O on Linux. Override the volume definitions if you pin WAL/data to specific devices.
- **Non-root from the start.** A one-shot `volume_prep` helper chowns the volumes before Postgres launches so the main service and sidecars run as your host user by default (UID/GID `${POSTGRES_UID}`), keeping file ownership consistent across deployments. Supply alternative IDs only when required.
- **Automated logical backups.** The `logical_backup` sidecar runs `pg_dump`/`pg_dumpall` on the cadence defined by `LOGICAL_BACKUP_INTERVAL_SECONDS`, writes into `./backups/logical`, prunes according to `LOGICAL_BACKUP_RETENTION_DAYS`, and skips any databases listed in `LOGICAL_BACKUP_EXCLUDE` (defaults to `postgres`). `daily-maintenance` captures the latest run in `logical_backup_status.txt` for auditing.
- **Composable health check.** `scripts/healthcheck.sh` verifies readiness, executes `SELECT 1`, and optionally enforces replication lag ceilings before dependents start.
- **Rotated container logs.** Docker's `local` driver with non-blocking delivery prevents runaway JSON files while retaining compressed history for incident response.
- **Optional service profiles.** `COMPOSE_PROFILES=valkey,pgbouncer,memcached` brings the cache/pooling stack online; drop profiles from the list to opt out without editing `docker-compose.yml`.
- **Seccomp baseline.** Shipping profiles in `seccomp/` cover each service (`postgres.json`, `logical_backup.json`, `pgbouncer.json`, `valkey.json`, `memcached.json`, `pghero.json`). `./scripts/manage.sh seccomp-status` reports the active spec, `seccomp-verify` gates compose configs, and `docs/security_philosophy.md` outlines how to regenerate traces when you need to tighten them further.
- **AppArmor (opt-in).** Minimal profiles live in `apparmor/core_data_minimal.profile`. Load them with `./scripts/manage.sh apparmor-load` (sudo), then set `CORE_DATA_APPARMOR_<SERVICE>=apparmor:core_data_minimal` in `.env` for each service you want to confine. The profile denies access to high-value host paths (`/root`, `/etc/shadow`, Docker socket) while leaving normal container paths alone.

### Service Add-ons
- **ValKey** — Requires authentication by default (`valkey_password` secret), persists to the `valkey_data` volume (`appendonly yes`), exposes `valkey-cli`/`valkey-bgsave`, and is tuned via `.env` knobs such as `VALKEY_MAXMEMORY` and `VALKEY_MAXMEMORY_POLICY`.
- **PgBouncer** — Uses SCRAM auth backed by a dedicated superuser, renders config/userlist from templates, and offers `pgbouncer-stats` / `pgbouncer-pools` helpers. Pool sizing and admin/stat users are driven by the `PGBOUNCER_*` variables.
- **Memcached** — Lightweight hot cache with configurable memory, connection, and thread limits (`MEMCACHED_*`). The `memcached-stats` helper pipes `stats` output for quick validation. All services stay on the internal bridge network by default.

## Project Layout
```
core_data/
├── .env.example              # Template for environment-specific settings (never commit real secrets)
├── docker-compose.yml        # Orchestrates PostgreSQL and PgHero services
├── scripts/                  # Operator tooling (manage.sh + lib modules + maintenance workflow)
├── postgres/                 # Custom image build assets, configs, and initdb scripts
├── backups/                  # Host output directory for logical dumps and reports
├── secrets/                  # Docker secret material (e.g., postgres_superuser_password)
├── README.md                 # This guide
├── THIRD_PARTY_LICENSES.md   # Upstream license attributions for vendored tooling
└── AGENTS.md                 # Contributor quick-reference & runbooks
```
If you override the named volumes with host bind mounts, keep those directories out of version control—they contain live cluster state and pgBackRest archives.

## Management CLI
`./scripts/manage.sh` is the operator entry point. Frequently used commands:

| Command | Description |
| --- | --- |
| `build-image` | Build the custom PostgreSQL image defined in `postgres/Dockerfile`. |
| `create-env` | Interactive wizard that copies `.env.example`, sizes resources, seeds secrets, and writes `.env`. |
| `up` / `down` | Start or stop the Compose stack (volumes preserved). |
| `psql` | Open psql inside the container (respects `PGHOST`, `PGUSER`, etc.). |
| `dump` / `dump-sql` | Produce logical backups (custom or plain format) under `/backups`. |
| `restore-dump` | Drop and recreate a database before restoring a `.dump.gz`. |
| `backup [--verify]` / `stanza-create` / `restore-snapshot` | Manage pgBackRest backups & optionally restore the latest backup into a throwaway data dir for checksum verification. |
| `daily-maintenance` | Run dumps, log capture, pgBadger analysis, and retention pruning. |
| `provision-qa` | Differential backup + targeted restore for QA databases. |
| `config-check` | Compare live `postgresql.conf` / `pg_hba.conf` against rendered templates to catch drift. |
| `audit-roles` / `audit-security` | Generate CSV/text reports covering role hygiene, passwords, and HBA/RLS posture. |
| `audit-extensions` | Confirm bundled extensions are present and on expected versions. |
| `audit-autovacuum` | Flag tables with high dead tuple counts or ratios. |
| `audit-replication` | Summarise follower lag and sync state. |
| `audit-cron` / `audit-squeeze` | Inspect pg_cron schedules and pg_squeeze activity tables. |
| `audit-index-bloat` | Estimate index bloat using pgstattuple (supports `--min-size-mb`). |
| `audit-buffercache` | Snapshot shared buffer usage per relation (supports `--limit`). |
| `audit-schema` | Snapshot schema metadata for drift detection. |
| `snapshot-pgstat` | Capture a `pg_stat_statements` baseline (CSV output) for performance trending. |
| `diff-pgstat --base --compare` | Diff two snapshots (CSV-in/CSV-out) to highlight hot queries. |
| `compact --level N` | Layered bloat management: 1=autovacuum audit, 2=pg_squeeze refresh, 3=pg_repack (needs `--tables`), 4=VACUUM FULL (needs `--yes`). |
| `exercise-extensions` | Smoke-test the core extension bundle (vector, PostGIS, AGE, citext, hstore, pgcrypto, hypopg, pg_partman, etc.). |
| `pgtap-smoke` | Run a micro pgTap plan to confirm key extensions (including hypopg/pg_partman) are registered. |
| `async-queue bootstrap` | Install the lightweight async queue schema (`asyncq`) with enqueue/dequeue helpers. |
| `partman-maintenance` | Invoke `run_maintenance_proc()` for the selected database (defaults to `POSTGRES_DB`). |
| `partman-show-config` | Print rows from `part_config` (optionally filter by `--parent schema.table`). |
| `partman-create-parent` | Wrap `create_parent` to bootstrap managed partitions without manual SQL. |
| `valkey-cli` | Run `valkey-cli` inside the ValKey container with secrets wired in. |
| `valkey-bgsave` | Trigger `BGSAVE` so the ValKey RDB is flushed to the `valkey_data` volume. |
| `pgbouncer-stats` / `pgbouncer-pools` | Emit PgBouncer `SHOW STATS` / `SHOW POOLS` via the admin console. |
| `memcached-stats` | Fetch `stats` output from the Memcached service. |
| `version-status` | Compare installed Postgres/extension versions with upstream releases (CSV via `--output`). |
| `upgrade --new-version` | Orchestrate pgautoupgrade (takes backups, validates base image, restarts). |

The CLI sources modular helpers from `scripts/lib/` so each function can be imported by tests or future automation.

`daily-maintenance` now emits a richer bundle under `backups/daily/<YYYYMMDD>/`, including `pg_stat_statements` snapshots, `pg_buffercache` heatmaps, role/extension/autovacuum/replication CSVs, pg_cron schedules, pg_squeeze activity, and a security checklist alongside logs, dumps, pgBadger HTML, and pgaudit summaries. The workflow also records the most recent sidecar dump run in `logical_backup_status.txt`, runs `partman.run_maintenance_proc()` across each database so freshly created partitions land even if the background worker interval has not elapsed, and captures version drift in `version_status.csv` (focusing on out-of-date components). Pair those reports with `config-check` to keep the rendered configs aligned with the templates. Tune the thresholds via `DAILY_PG_STAT_LIMIT`, `DAILY_BUFFERCACHE_LIMIT`, `DAILY_DEAD_TUPLE_THRESHOLD`, `DAILY_DEAD_TUPLE_RATIO`, and `DAILY_REPLICATION_LAG_THRESHOLD` as needed.

Nightly cron jobs also refresh pg_squeeze targets, reset `pg_stat_statements`, and run a safe `VACUUM (ANALYZE, SKIP_LOCKED, PARALLEL 4)` so statistics stay current without blocking hot tables.

Set `DAILY_EMAIL_REPORT=true` and `DAILY_REPORT_RECIPIENT=ops@example.com` in `.env` to have the maintenance job email the HTML summary via `sendmail` (if available inside the container).

To compare performance snapshots between runs, capture CSVs with `snapshot-pgstat --output /backups/pg_stat_before.csv` and `snapshot-pgstat --output /backups/pg_stat_after.csv`, then run `./scripts/manage.sh diff-pgstat --base /backups/pg_stat_before.csv --compare /backups/pg_stat_after.csv --limit 25` for a ranked delta report.

### Compacting storage
`./scripts/manage.sh compact` provides escalating space-recovery options:

- **Level 1** — run the autovacuum audit (no changes, just reporting).
- **Level 2** — rerun `core_data_admin.refresh_pg_squeeze_targets()` and emit updated `pg_squeeze` findings.
- **Level 3** — execute `pg_repack` for specific tables (`--tables schema.table[,schema.table...]`) without heavy locks.
- **Level 4** — run `VACUUM (FULL, ANALYZE, VERBOSE)` across all tables or a comma-delimited `--scope` (requires `--yes`). Expect exclusive locks; schedule during maintenance windows.

All runs write logs under `backups/` for auditing (`pg_repack-*.log`, `vacuum-full-*.log`).

## Automation & Testing
- **CI Workflow:** `.github/workflows/ci.yml` builds the image, runs `python -m pytest -k full_workflow`, and uploads generated backups for inspection.
- **Smoke Test:** `tests/test_manage.py` spins up a disposable environment, exercises key CLI commands (including `daily-maintenance`, pgBackRest, and `upgrade`), and tears everything down. Run locally with `python -m pytest -k full_workflow` (Docker required).
- **Fast Tests:** `tests/test_lightweight.py` validates offline flows like help output and the vendored tooling without needing Docker.
- **Extension Smoke:** `./scripts/manage.sh exercise-extensions --db <name>` plus `pgtap-smoke` provide quick feedback that the entire core extension bundle (vector/PostGIS/AGE/hstore/citext/pgcrypto/pg_partman/etc.) is ready for use.
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
- [PostGIS](https://postgis.net/) – spatial superpowers for PostgreSQL (including Tiger Geocoder & Address Standardizer).
- [pgRouting](https://pgrouting.org/) – network routing & graph analysis atop PostGIS.
- [Apache AGE](https://age.apache.org/) – graph database extension.
- [pgaudit](https://github.com/pgaudit/pgaudit) – enhanced auditing.
- [pg_partman](https://github.com/pgpartman/pg_partman) – automated time/ID partition management.
- [HypoPG](https://github.com/HypoPG/hypopg) – hypothetical index exploration for query tuning.
- [pg_repack](https://github.com/reorg/pg_repack) & [pgtap](https://github.com/theory/pgtap) – maintenance & testing extensions.

Their work powers the database-as-code experience delivered by core_data.
