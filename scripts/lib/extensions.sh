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
SELECT create_graph('core_data_smoke_graph')
  WHERE NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'core_data_smoke_graph');
SELECT * FROM cypher('core_data_smoke_graph', $$ CREATE (n:person {name: 'Alice'}) RETURN n.name $$) AS (name agtype);
SELECT * FROM cypher('core_data_smoke_graph', $$ MATCH (n:person) RETURN n.name $$) AS (name agtype);
SELECT drop_graph('core_data_smoke_graph', true);

RESET search_path;

-- pgcrypto smoke
SELECT encode(digest('core_data', 'sha256'), 'hex');

-- uuid-ossp smoke
SELECT uuid_generate_v4();

-- citext/hstore/pg_trgm smoke
SELECT 'CaseTest'::citext = 'casetest';
SELECT ('key=>value')::hstore -> 'key';
SELECT similarity('core data', 'core_data');

-- pg_buffercache visibility
SELECT count(*) FROM pg_buffercache;

-- pg_partman smoke
CREATE SCHEMA IF NOT EXISTS core_data_partman_tmp;
SET search_path = core_data_partman_tmp, public;
DROP TABLE IF EXISTS partman_demo CASCADE;
CREATE TABLE partman_demo (id bigint, created_at timestamptz NOT NULL DEFAULT now()) PARTITION BY RANGE (created_at);
DO
$$
DECLARE
  partman_schema text;
BEGIN
  SELECT n.nspname INTO partman_schema
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'pg_partman';
  IF partman_schema IS NULL THEN
    RAISE EXCEPTION 'pg_partman extension not installed';
  END IF;
  EXECUTE format('DELETE FROM %I.part_config WHERE parent_table = %L;', partman_schema, 'core_data_partman_tmp.partman_demo');
  EXECUTE format('DROP TABLE IF EXISTS %I.template_core_data_partman_tmp_partman_demo CASCADE;', partman_schema);
  EXECUTE format('SELECT %I.create_parent(''core_data_partman_tmp.partman_demo'', ''created_at'', ''1 day'', ''range'');', partman_schema);
END;
$$;
INSERT INTO partman_demo (id, created_at)
VALUES
  (1, now()),
  (2, now() + interval '1 day');
SELECT n.nspname AS partman_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
 WHERE e.extname = 'pg_partman'
\gset
\if :{?partman_schema}
SELECT format('CALL %I.run_maintenance_proc();', :'partman_schema');
\gexec
\else
SELECT 'pg_partman extension not installed' AS warning;
\endif
SELECT relid::regclass::text AS partition_name
  FROM pg_partition_tree('core_data_partman_tmp.partman_demo')
 WHERE parentrelid = 'core_data_partman_tmp.partman_demo'::regclass
   AND level = 1
 LIMIT 1;

-- hypopg smoke
SELECT indexrelid AS hypo_idx
  FROM hypopg_create_index('CREATE INDEX ON core_data_partman_tmp.partman_demo (created_at)');
\gset
SELECT hypopg_drop_index(:hypo_idx);

-- PostGIS ecosystem helpers
SELECT EXISTS (
  SELECT 1 FROM information_schema.schemata WHERE schema_name = 'tiger'
) AS tiger_schema_exists;
SELECT EXISTS (
  SELECT 1 FROM information_schema.schemata WHERE schema_name = 'tiger_data'
) AS tiger_data_schema_exists;
SELECT EXISTS (
  SELECT 1 FROM information_schema.schemata WHERE schema_name = 'address_standardizer'
) AS address_standardizer_schema;
SELECT EXISTS (
  SELECT 1 FROM information_schema.schemata WHERE schema_name = 'address_standardizer_data_us'
) AS address_standardizer_data_schema;
SELECT pgr_version();
SET search_path = public;
DROP SCHEMA core_data_partman_tmp CASCADE;
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
SELECT plan(29);
SELECT ok(current_schema = 'test_core_data', 'search_path set to test schema');
SELECT has_extension('vector', 'vector extension installed');
SELECT has_extension('postgis', 'postgis extension installed');
SELECT has_extension('age', 'Apache AGE extension installed');
SELECT has_extension('pgtap', 'pgTap extension installed');
SELECT has_extension('pg_repack', 'pg_repack extension installed');
SELECT has_extension('pg_squeeze', 'pg_squeeze extension installed');
SELECT has_extension('pg_stat_statements', 'pg_stat_statements extension installed');
SELECT ok(position('auto_explain' in current_setting('shared_preload_libraries')) > 0, 'auto_explain registered in shared_preload_libraries');
SELECT has_extension('pg_buffercache', 'pg_buffercache extension installed');
SELECT has_extension('pgcrypto', 'pgcrypto extension installed');
SELECT has_extension('citext', 'citext extension installed');
SELECT has_extension('hstore', 'hstore extension installed');
SELECT has_extension('pg_trgm', 'pg_trgm extension installed');
SELECT has_extension('btree_gin', 'btree_gin extension installed');
SELECT has_extension('btree_gist', 'btree_gist extension installed');
SELECT has_extension('postgres_fdw', 'postgres_fdw extension installed');
SELECT has_extension('dblink', 'dblink extension installed');
SELECT has_extension('uuid-ossp', 'uuid-ossp extension installed');
SELECT has_extension('fuzzystrmatch', 'fuzzystrmatch extension installed');
SELECT has_extension('pgaudit', 'pgaudit extension installed');
SELECT has_extension('postgis_raster', 'postgis_raster extension installed');
SELECT has_extension('postgis_topology', 'postgis_topology extension installed');
SELECT has_extension('pgstattuple', 'pgstattuple extension installed');
SELECT has_extension('postgis_tiger_geocoder', 'postgis_tiger_geocoder extension installed');
SELECT has_extension('address_standardizer', 'address_standardizer extension installed');
SELECT has_extension('address_standardizer_data_us', 'address_standardizer_data_us extension installed');
SELECT has_extension('pgrouting', 'pgRouting extension installed');
SELECT has_extension('hypopg', 'hypopg extension installed');
SELECT has_extension('pg_partman', 'pg_partman extension installed');
SELECT * FROM finish();
SQL
}
