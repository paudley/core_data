#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Asynchronous task queue helpers (lightweight job queue built on PostgreSQL primitives).
set -euo pipefail

LIB_ASYNCQ_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${LIB_ASYNCQ_DIR}/common.sh"

ASYNCQ_DEFAULT_SCHEMA=${ASYNCQ_DEFAULT_SCHEMA:-asyncq}
ASYNCQ_DEFAULT_LEASE=${ASYNCQ_DEFAULT_LEASE:-30 seconds}
ASYNCQ_DEFAULT_RETRY=${ASYNCQ_DEFAULT_RETRY:-5 minutes}

async_queue_bootstrap() {
  ensure_env
  local database=${1:-${POSTGRES_DB:-postgres}}
  local schema=${2:-${ASYNCQ_DEFAULT_SCHEMA}}

  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${database}" \
         --set ON_ERROR_STOP=1 --set="schema_name=${schema}" <<'SQL'
DO
$$
DECLARE
  target_schema text := :'schema_name';
BEGIN
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %s', quote_ident(target_schema));
END;
$$;

SET search_path = format('%I, public', :'schema_name');

CREATE TABLE IF NOT EXISTS jobs (
  id              bigserial PRIMARY KEY,
  queue_name      text        NOT NULL DEFAULT 'default',
  payload         jsonb       NOT NULL,
  run_at          timestamptz NOT NULL DEFAULT now(),
  reserved_until  timestamptz,
  reserved_by     uuid,
  attempts        integer     NOT NULL DEFAULT 0,
  max_attempts    integer     NOT NULL DEFAULT 25,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS jobs_queue_run_idx
  ON jobs (queue_name, run_at);
CREATE INDEX IF NOT EXISTS jobs_reserved_until_idx
  ON jobs (reserved_until);

CREATE OR REPLACE FUNCTION enqueue(
    p_queue_name text,
    p_payload jsonb,
    p_run_at timestamptz DEFAULT now(),
    p_max_attempts integer DEFAULT 25)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  job_id bigint;
BEGIN
  INSERT INTO jobs(queue_name, payload, run_at, max_attempts)
       VALUES (p_queue_name, COALESCE(p_payload, '{}'::jsonb), COALESCE(p_run_at, now()), p_max_attempts)
    RETURNING id INTO job_id;

  PERFORM pg_notify(format('asyncq:%s', p_queue_name), job_id::text);
  RETURN job_id;
END;
$$;

CREATE OR REPLACE FUNCTION enqueue(p_payload jsonb)
RETURNS bigint
LANGUAGE sql
AS $$
  SELECT enqueue('default', $1);
$$;

CREATE OR REPLACE FUNCTION dequeue(
    p_queue_name text DEFAULT 'default',
    p_lease interval DEFAULT '${ASYNCQ_DEFAULT_LEASE}',
    p_worker uuid DEFAULT gen_random_uuid())
RETURNS TABLE(job_id bigint, payload jsonb, attempts integer, available_at timestamptz, worker uuid)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH candidate AS (
      SELECT id
        FROM jobs
       WHERE queue_name = p_queue_name
         AND (reserved_until IS NULL OR reserved_until < now())
         AND run_at <= now()
         AND attempts < max_attempts
       ORDER BY run_at, id
       LIMIT 1
       FOR UPDATE SKIP LOCKED
  )
  UPDATE jobs j
     SET reserved_until = now() + p_lease,
         reserved_by = p_worker,
         attempts = j.attempts + 1,
         updated_at = now()
   WHERE j.id IN (SELECT id FROM candidate)
  RETURNING j.id, j.payload, j.attempts, j.run_at, j.reserved_by;
END;
$$;

CREATE OR REPLACE FUNCTION complete(p_job_id bigint, p_worker uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  deleted boolean;
BEGIN
  DELETE FROM jobs
   WHERE id = p_job_id
     AND (reserved_by = p_worker OR reserved_by IS NULL)
  RETURNING true INTO deleted;
  RETURN COALESCE(deleted, false);
END;
$$;

CREATE OR REPLACE FUNCTION fail(
    p_job_id bigint,
    p_worker uuid,
    p_error text,
    p_retry_in interval DEFAULT '${ASYNCQ_DEFAULT_RETRY}')
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  updated boolean;
BEGIN
  UPDATE jobs
     SET reserved_until = NULL,
         reserved_by = NULL,
         run_at = CASE
                    WHEN attempts >= max_attempts THEN NULL
                    ELSE now() + p_retry_in
                  END,
         last_error = p_error,
         updated_at = now()
   WHERE id = p_job_id
     AND (reserved_by = p_worker OR reserved_by IS NULL)
  RETURNING true INTO updated;
  RETURN COALESCE(updated, false);
END;
$$;

CREATE OR REPLACE FUNCTION extend_lease(p_job_id bigint, p_worker uuid, p_lease interval)
RETURNS timestamptz
LANGUAGE plpgsql
AS $$
DECLARE
  new_until timestamptz;
BEGIN
  UPDATE jobs
     SET reserved_until = now() + p_lease,
         updated_at = now()
   WHERE id = p_job_id
     AND reserved_by = p_worker
  RETURNING reserved_until INTO new_until;
  RETURN new_until;
END;
$$;

CREATE OR REPLACE VIEW queue_metrics AS
SELECT queue_name,
       count(*) FILTER (WHERE run_at <= now() AND (reserved_until IS NULL OR reserved_until < now()) AND attempts < max_attempts) AS ready,
       count(*) FILTER (WHERE reserved_until IS NOT NULL AND reserved_until >= now()) AS leased,
       count(*) FILTER (WHERE max_attempts <= attempts) AS dead_letter,
       count(*) AS total
  FROM jobs
 GROUP BY queue_name;

RESET search_path;
SQL
}
