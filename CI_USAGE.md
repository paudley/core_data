# CI Usage

This repository ships helpers and workflows tuned for CI pipelines that rely on published, attested images and minimal host privileges. Follow the steps below to bring the stack up, run tests, and tear it down safely.

## Prerequisites
- Docker available to the runner (userland; no host sudo assumptions).
- `gh` CLI installed when you want to verify image attestations.
- Python toolchain provided by `uv` (the repo uses `uv run`/`uv sync` against the local `.venv`).

## Quickstart (CI runner)
1. Generate environment and secrets (idempotent, non-interactive):
   ```bash
   ./scripts/manage.sh create-env --non-interactive --force
   ```
   This aligns `POSTGRES_UID/GID` (and RabbitMQ equivalents) to the invoking user so containers can read `./secrets/*` after `volume_prep` chowns them.

2. Optional safety gate: verify prerequisites and image attestations (recommended in pipelines):
   ```bash
   ./scripts/manage.sh ci-verify --env-file ci.env.example --require-attestation
   ```

3. Bring up the CI stack with prebuilt images and emit connection details for downstream jobs:
   ```bash
   ./scripts/manage.sh ci-up --env-file ci.env.example --output ./backups/ci-output.json
   ```
   The output JSON includes host/ports, superuser, and password file paths for services enabled via `COMPOSE_PROFILES`.

4. Run the CI test markers (uses the repo-local `.venv`):
   ```bash
   uv sync --dev
   uv run python -m pytest -m ci --junitxml=report-ci.xml
   ```
   Other markers you may want to run individually: `security`, `backup`, `extensions`, `pool`, `pool_heavy`, `lint`, `config`.

5. Tear down and clean up:
   ```bash
   ./scripts/manage.sh ci-down --volumes --prune-data --prune-secrets
   ```

## Published images and attestations
- Postgres image tag is `${POSTGRES_IMAGE_NAME:-core_data/postgres}:${POSTGRES_IMAGE_TAG:-17.2-bookworm-core}`. CI builds/publishes to GHCR; attestations can be checked with:
  ```bash
  gh attestation verify --repo paudley/core_data --subject ghcr.io/paudley/core_data/postgres:<tag>
  ```
- Images are signed keylessly with cosign during publish. Verify using the Actions OIDC issuer:
  ```bash
  cosign verify \
    --certificate-identity-regexp '^https://github.com/paudley/core_data/actions/runs/[0-9]+$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    ghcr.io/paudley/core_data/postgres@<digest>
  ```
- `./scripts/manage.sh ci-verify --require-attestation` performs this automatically for all services in scope for the active compose profiles.

## Troubleshooting in CI
- **`/run/secrets/...: Permission denied`**: ensure `create-env` ran in the same workspace and that `POSTGRES_UID/GID` and `RABBITMQ_UID/GID` reflect the runner user. `volume_prep` will chown `./secrets/*` to that UID at startup.
- **Containers unhealthy**: collect diagnostics with `./scripts/collect_diagnostics.sh --output diagnostics-ci` and upload the folder as an artifact; include compose logs and per-container logs for review.
- **Dory hangs on ready state**: check `docker compose logs postgres` and `pg_log` tail; `tests/test_manage.py::wait_for_ready` times out after 40x5s retries—fail fast by surfacing logs when health checks fail.

## Suggested CI workflow shape
- Pre-step: reset `./secrets` and run `create-env --non-interactive --force`.
- Build (or download) Postgres image; tag to `${POSTGRES_IMAGE_NAME}:${POSTGRES_IMAGE_TAG}` for compose to consume.
- Run `ci-up`, then targeted pytest markers (`-m ci` or others) using `uv run`.
- Always upload diagnostics bundles and JUnit reports when jobs fail to simplify debugging.
