#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Helper routines for exercising bundled extensions (pgvector, PostGIS, Apache AGE, pgTap).
set -euo pipefail

LIB_EXT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${LIB_EXT_DIR}/common.sh"

exercise_extensions() {
  ensure_env
  local database=${1:-${POSTGRES_DB:-postgres}}
  echo "[extensions] Running smoke queries against ${database}" >&2
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --set ON_ERROR_STOP=on --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${database}" <<'SQL'
-- pgvector smoke
CREATE TEMP TABLE IF NOT EXISTS core_data_vector_demo(id serial primary key, embedding vector(3));
INSERT INTO core_data_vector_demo(embedding) VALUES ('[1,2,3]'),('[2,2,2]');
SELECT embedding <-> '[1,2,4]'::vector AS distance FROM core_data_vector_demo ORDER BY distance LIMIT 1;

-- PostGIS smoke
SELECT ST_AsText(ST_Buffer(ST_GeomFromText('POINT(0 0)'), 1.0));

-- Apache AGE smoke
LOAD 'age';
SET search_path = ag_catalog, "$user", public;
SELECT create_graph('core_data_smoke_graph');
SELECT create_vlabel('core_data_smoke_graph', 'person')
  WHERE NOT EXISTS (SELECT 1 FROM ag_catalog.ag_label WHERE name = 'person');
SELECT create_vertex('core_data_smoke_graph', 'person', '{"name":"Alice"}'::jsonb);
SELECT * FROM cypher('core_data_smoke_graph', $$ MATCH (n:person) RETURN n.name $$) AS (name agtype);
SELECT drop_graph('core_data_smoke_graph', true);
SQL
}

run_pgtap_smoke() {
  ensure_env
  local database=${1:-${POSTGRES_DB:-postgres}}
  echo "[pgtap] running smoke plan in ${database}" >&2
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --set ON_ERROR_STOP=on --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${database}" <<'SQL'
CREATE SCHEMA IF NOT EXISTS test_core_data;
SET search_path = test_core_data, public;
SELECT plan(3);
SELECT ok(current_schema = 'test_core_data', 'search_path set to test schema');
SELECT has_extension('pgvector', 'pgvector extension installed');
SELECT has_extension('postgis', 'postgis extension installed');
SELECT * FROM finish();
SQL
}
