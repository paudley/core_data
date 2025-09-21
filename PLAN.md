<!--
SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
SPDX-License-Identifier: MIT
-->

# Project Plan

## Objectives
- Deliver a reproducible PostgreSQL 17 platform with built-in extensions (PostGIS, pg_vector, Apache AGE, pg_cron, pg_squeeze) using Docker Compose.
- Provide automation for lifecycle operations via `./scripts/manage.sh`, covering backups, restores, QA provisioning, log analytics, and retention.
- Maintain the automated upgrade helper and document fallback paths when upstream images are unavailable.
- Validate the stack continuously via the CI smoke test (`python -m pytest -k full_workflow`) and local reruns before release.

## Milestones & Timeline
1. **Foundation Hardening (Week 1)** – Finalize `.env` templates, lock down `postgres/conf/*.tpl`, and document the build process in `README.md`. Validate container health using `docker compose up -d` followed by `docker compose logs postgres`.
2. **Operations Toolkit (Week 2)** – Extend `manage.sh` and `scripts/lib/` as needed to cover user management, pgBackRest automation, and PITR flows. Add command usage examples to `AGENTS.md` and verify with `./scripts/manage.sh backup --type=full`.
3. **Observability & QA Automation (Week 3)** – Integrate PgHero defaults, establish log retention, and script fast QA clones via `manage.sh provision-qa`. Capture the workflow in runbooks and smoke-test with disposable volumes.
4. **Resilience & Upgrade Strategy (Week 4)** – Implement pgBackRest retention policies, exercise `manage.sh restore-snapshot --target-time="<timestamp>"`, wire up the `upgrade --new-version` helper in a safe environment, and land the CI pipeline that runs the pytest smoke test plus publishes generated backups/logs as artifacts.

## Workstreams & Owners
- **Platform Engineering:** Maintain Docker build assets (`postgres/Dockerfile`, init scripts) and validate schema initialization.
- **Operations Engineering:** Own backup cadence, storage configuration under `data/pgbackrest_repo/`, retention policies, and recovery rehearsals.
- **Developer Enablement:** Curate documentation (`README.md`, `AGENTS.md`) and publish quick-start checklists for new contributors.
- **Automation & Upgrades:** Maintain the pgautoupgrade workflow, track base image availability, and evolve the CI smoke test to cover real major-version transitions as new releases ship.

## Risks & Mitigations
- **Configuration Drift:** Mitigate by mandating changes through version-controlled `.tpl` files and peer review.
- **Backup Integrity:** Schedule recurring restore drills and checksum verification of `pgbackrest` snapshots.
- **Secret Exposure:** Enforce `.env` handling rules, integrate pre-commit checks, and rotate credentials defined in `DATABASES_TO_CREATE`.
- **Upgrade Debt:** Until automation lands, maintain a tested manual pg_upgrade procedure tied to each release.

## Success Metrics
- <15 minutes to bootstrap a fresh environment using documented steps.
- Automated backups passing restore drills twice per sprint.
- Zero open high-severity issues for documentation gaps or failed runbooks at release.
- Manual upgrade playbook rehearsed at least once per quarter until automation is delivered.
