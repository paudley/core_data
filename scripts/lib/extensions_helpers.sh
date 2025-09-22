#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Helper functions for shared extension bootstrap logic.

generate_pg_partman_sql() {
  cat <<'SQL'
DO
$$
DECLARE
  ext_schema text;
BEGIN
  SELECT n.nspname INTO ext_schema
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'pg_partman';
  IF ext_schema IS NOT NULL AND ext_schema <> 'partman' THEN
    RAISE NOTICE 'Recreating pg_partman extension in schema partman (was %).', ext_schema;
    EXECUTE 'DROP EXTENSION pg_partman CASCADE';
  END IF;
END;
$$;
CREATE SCHEMA IF NOT EXISTS partman AUTHORIZATION CURRENT_USER;
SET search_path = partman, public;
CREATE EXTENSION IF NOT EXISTS pg_partman;
RESET search_path;
SQL
}
