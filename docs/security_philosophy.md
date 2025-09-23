# Security Philosophy

Our priority chain is **data infrastructure as code ➜ automated admin ➜ human-friendly ➜ best-practices by default (including security and performance)**. Security features exist to reinforce those first three pillars, not supplant them. Whenever we harden the stack we:

1. Keep the declarative infrastructure intact (compose, initdb, scripts).
2. Preserve unattended automation (CI, backups, cron invocations).
3. Maintain a comfortable operator experience (CLI prompts, docs, dashboards).
4. Enforce the pragmatic hardening that fits most deployments out of the box.

## Capability Policy

Dropping Linux capabilities is our default posture for long-running services. We centralise the rule in the `x-security-defaults` anchor inside `docker-compose.yml` so every service opts in automatically. The matrix below captures the current state.

| Service | Capabilities granted | Rationale / verification |
| --- | --- | --- |
| `postgres` | `cap_drop: [ALL]` | Runs as non-root with no privileged syscalls required. Verified via `docker compose config --format json` during `pytest -k manage_env` and by exercising initdb, pg_partman, pg_dump, pg_restore, backups, and async queue flows. |
| `logical_backup` | `cap_drop: [ALL]` | Same image as `postgres`; only `pg_dump*` tooling executes. Verified by the integration test suite and manual backup/restore runs. |
| `pghero` | `cap_drop: [ALL]` | Ruby app that only queries Postgres; no extra kernel features required. |
| `pgbouncer` | `cap_drop: [ALL]` | Bitnami image drops root privileges internally; connection pooling works without additional capabilities. |
| `valkey` | `cap_drop: [ALL]` | Alpine ValKey container operates entirely in user space; health checks succeed under the drop. |
| `memcached` | `cap_drop: [ALL]` | Uses standard TCP sockets and in-memory storage; no capabilities needed. |
| `volume_prep` | uses Docker defaults | Runs as `root` solely to chown initial volumes before other services start. We leave it outside the anchor because it needs short-lived filesystem ownership privileges and exits immediately after preparation. |

If a future service genuinely needs a capability, document the syscall failure, add the minimum `cap_add` entry with justification, and update this matrix plus the automated test coverage.

## Verification

- `pytest -k manage_env` ensures the compose configuration retains `cap_drop: [ALL]` for every runtime service listed above.
- Full workflow tests (`pytest -k full_workflow`) exercise pg_dump/pg_restore, async queue automation, pg_partman maintenance, ValKey, Memcached, and PgBouncer with the capability policy in place.
- Manual smoke tests (`./scripts/manage.sh backup --type=full --verify`, `./scripts/manage.sh daily-maintenance`) remain part of the release checklist when altering security posture.

Re-run these checks whenever the compose topology changes or when adding new operational automation.
