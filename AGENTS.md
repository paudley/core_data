
# Repository Guidelines

## Project Structure & Module Organization
The root directory contains `docker-compose.yml`, `.env.example`, and the long-form architecture notes in `PROJECT.md`. PostgreSQL build assets live under `postgres/`, with configuration templates in `postgres/conf/*.tpl` and initialization scripts in `postgres/initdb/NN-description.sh`. Operational tooling is in `scripts/`: the `manage.sh` CLI sources helpers from `scripts/lib/`. Persistent state is mounted from `data/` (`postgres_data/`, `pgbackrest_repo/`, `pghero_data/`); keep this directory out of version control.

## Build, Test, and Development Commands
`docker compose build postgres` rebuilds the custom image after modifying `postgres/Dockerfile` or config templates. `docker compose up -d` provisions the database stack using the active `.env`. Use `docker compose logs postgres` to inspect startup output and health checks. Run `./scripts/manage.sh psql -d app_main -U app_user` for an interactive shell, `./scripts/manage.sh backup --type=full` to seed the pgBackRest repository, `./scripts/manage.sh pgtune-config` to generate host-specific overrides in `postgresql.pgtune.conf`, `./scripts/manage.sh pgbadger-report --since "yesterday"` to produce HTML log analytics under `/backups`, and schedule `./scripts/manage.sh daily-maintenance --root ./backups/daily` nightly to capture dumps/logs and prune old runs.`

## Coding Style & Naming Conventions
Shell scripts should follow the Google Shell Style Guide: `#!/usr/bin/env bash`, `set -euo pipefail`, two-space indentation, and lowercase `snake_case` function names. Name init scripts with zero-padded prefixes (`01-init-db-user-creation.sh`) to enforce execution order. Keep environment variables upper snake case and explain new ones in `.env.example`. Template files should remain `.tpl` and consume `${VAR}` placeholders only.

## Testing Guidelines
Use `docker compose exec postgres pg_isready` and `./scripts/manage.sh psql -c 'SELECT 1;'` to confirm container health after changes. For init script updates, recreate the cluster (`docker compose down -v && docker compose up -d`) in a disposable environment and verify schema, users, and extensions. Always run `./scripts/manage.sh backup --type=diff` plus `restore-snapshot --target-time="<timestamp>"` when altering backup workflows.

## Commit & Pull Request Guidelines
Adopt Conventional Commits (`feat:`, `fix:`, `chore:`) with concise scopes (`feat(initdb): add analytics role`). Reference the operational impact in the body—highlight affected services, required `.env` mutations, and rollback steps. Pull requests should include: objective summary, applied commands, testing evidence (log snippets or `SELECT 1` output), and links to related tickets. Update `PROJECT.md` whenever design or runbook expectations change.

## Security & Configuration Tips
Never commit a real `.env`; start from `.env.example` and store secrets in your secrets manager. Restrict host port exposure to PgHero via `PGHERO_PORT`, leaving Postgres internal-only unless explicitly required. Protect backups by binding `data/pgbackrest_repo/` to secured storage and rotating credentials used in `DATABASES_TO_CREATE`.
