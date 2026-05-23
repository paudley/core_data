# CI Workflow Example

This guide demonstrates how to run the **core_data** stack inside GitHub Actions (or any CI service) using the new `ci-*` helpers. The workflow assumes you are consuming published container images (with attestations) and that you do _not_ commit a `.env` file to your repository.

## Required secrets

| Secret | Description |
| --- | --- |
| `GHCR_TOKEN` | Personal access token or Actions token with `packages:read` so the runner can pull ghcr.io images. |
| `CORE_DATA_POSTGRES_SUPERUSER_PASSWORD` | Optional; if omitted `ci-up` generates secrets automatically. |
| `CORE_DATA_NETWORK_ALLOW` | Optional list of CIDRs (comma-separated) granted access during bootstrap. |

## GitHub Actions example

```yaml
name: core-data-ci
on:
  push:
    branches: [main]

jobs:
  smoke:
    runs-on: ubuntu-latest
    env:
      COMPOSE_PROFILES: valkey,pgbouncer
      POSTGRES_IMAGE_NAME: ghcr.io/paudley/core_data/postgres
      POSTGRES_IMAGE_TAG: 18.4-v1.0.0
      CORE_DATA_REQUIRE_ATTESTATION: 1
    steps:
      - uses: actions/checkout@v4

      - name: Configure gh
        run: echo "${{ secrets.GHCR_TOKEN }}" | gh auth login --with-token

      - name: CI verify
        run: ./scripts/manage.sh ci-verify --env-file ci.env.example --require-attestation

      - name: Start stack
        env:
          CORE_DATA_NETWORK_ALLOW: ${{ secrets.CORE_DATA_NETWORK_ALLOW }}
        run: ./scripts/manage.sh ci-up --env-file ci.env.example --output ./backups/ci-output.json

      - name: Smoke test
        run: ./scripts/manage.sh psql -d ci_db -c 'SELECT 1;'

      - name: Tear down
        if: always()
        run: ./scripts/manage.sh ci-down --volumes --prune-data --prune-secrets
```

## Command summary

| Command | Purpose |
| --- | --- |
| `./scripts/manage.sh ci-verify` | Runs docker availability, disk space, port, and attestation checks. Pass `--skip-docker` on runners that do not expose Docker yet. |
| `./scripts/manage.sh bootstrap-ci` | Generates `secrets/`, `network_access/allow.list`, and `data/` scaffolding. `ci-up` calls this automatically unless `--skip-bootstrap` is provided. |
| `./scripts/manage.sh ci-up` | Starts the stack using only environment variables. Supports `--dry-run`, `--profiles`, and `--output` for JSON summaries. |
| `./scripts/manage.sh ci-down` | Stops containers (`docker compose down`) and optionally prunes volumes/data/secrets. |

## JSON outputs

`ci-up` writes a compact JSON file (default `backups/ci-output.json`) containing service connection details:

```json
{
  "composeProfiles": "valkey,pgbouncer",
  "services": {
    "postgres": {
      "host": "127.0.0.1",
      "port": 5433,
      "superuser": "postgres",
      "passwordFile": "secrets/postgres_superuser_password"
    },
    "pgbouncer": {
      "host": "127.0.0.1",
      "port": 6432
    }
  }
}
```

> **Note**: PostgreSQL listens on port 5433 by default so PgBouncer can own the standard port 5432. Clients connecting to 5432 get pooled connections automatically; use 5433 to bypass pooling.

Expose this file as an artifact or parse it to feed downstream jobs (e.g., integration tests running against the CI database).
