<!--
SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
SPDX-License-Identifier: MIT
-->

# Testing the Database with core_data

core_data bakes testing tooling into the image so both humans and agents can validate schema changes, stored procedures, and operational workflows quickly. This guide covers the main approaches: lightweight smoke checks, pgTap unit tests, automated CLI workflows, and integration-test strategies.

## Quick Smoke Checks

Run these after any change to make sure the stack still boots:

```bash
python -m pytest -k full_workflow
./scripts/manage.sh up
./scripts/manage.sh psql -c 'SELECT 1;'
./scripts/manage.sh down
```

The pytest suite provisions a disposable environment, exercises the key manage commands (logical dumps, pgBackRest backups, `daily-maintenance`, and the upgrade helper), and cleans up. Keep it passing before every merge.

## Using pgTap for Database Unit Tests

pgTap ships in the image. Typical workflow:

1. Connect to the target database:
   ```bash
   ./scripts/manage.sh psql -d app_main
   ```
2. Create a test schema to keep objects isolated:
   ```sql
   CREATE SCHEMA IF NOT EXISTS test;
   SET search_path = test, public;
   ``
3. Write tests using pgTap assertions:
   ```sql
   -- file: test/sample.sql
   BEGIN;
     SELECT plan(2);
     SELECT ok(1 = 1, 'math still works');
     SELECT has_table('public', 'users', 'users table exists');
   COMMIT;
   ```
4. Execute tests inside the container:
   ```bash
   ./scripts/manage.sh psql -d app_main -f test/sample.sql
   ```

Organize pgTap files under a `tests/sql/` folder and invoke them via CI or a Makefile target. pgTap assertions cover schema introspection, data checks, and function signatures.

## Scenario Testing with manage.sh

Wrap higher-level scenarios in shell scripts or pytest helpers using `./scripts/manage.sh` commands. Examples:

- **Backup & Restore Validation**
  ```bash
  ./scripts/manage.sh backup --type=full
  ./scripts/manage.sh restore-snapshot --delta --target=name=latest
  ./scripts/manage.sh psql -d app_main -c "SELECT COUNT(*) FROM important_table;"
  ```
- **QA Clone Smoke Test**
  ```bash
  ./scripts/manage.sh provision-qa app_main
  ./scripts/manage.sh psql -d app_main -c "SELECT current_setting('server_version');"
  ```

Combine these with pgTap tests to ensure both the data and the operational workflows behave correctly.

## Integration Testing Strategies

When building application-level integration tests:

- Prefer ephemeral databases created via `docker compose up` against the core_data image.
- Use the `.env.example` template to generate environment-specific configs programmatically.
- Seed fixtures by dropping SQL files into `postgres/initdb/NN-*.sh` or executing migrations via `./scripts/manage.sh psql -f`.
- Run concurrent tests against isolated databases (`DATABASES_TO_CREATE` supports multiple tenants).

## Automation Tips

- Cache Docker layers in CI to avoid rebuilding the image for every run.
- Mount a temporary backups directory (the pytest fixture does this automatically) to prevent permission issues.
- Use `PG_BADGER_JOBS=1` on small runners to reduce CPU contention.
- When writing new pgTap suites, add a step in the CI workflow or extend `python -m pytest -k full_workflow` to execute them.

## Additional Resources

- [pgTap Documentation](https://pgtap.org/)
- [pgBackRest User Guide](https://pgbackrest.org/user-guide.html)
- [PostgreSQL Testing Guidelines](https://www.postgresql.org/docs/current/testing.html)
- `AGENTS.md` for contributor runbooks and operational checklists.
