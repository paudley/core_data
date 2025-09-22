#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Canonical list of default extensions enabled across bootstrap flows.
CORE_EXTENSION_LIST=(
  age
  btree_gin
  btree_gist
  citext
  dblink
  hstore
  fuzzystrmatch
  pg_buffercache
  pg_cron
  pg_partman
  hypopg
  pg_repack
  pg_squeeze
  pg_stat_statements
  pg_trgm
  pgcrypto
  pgstattuple
  pgtap
  pgaudit
  postgres_fdw
  postgis
  postgis_raster
  postgis_topology
  address_standardizer
  address_standardizer_data_us
  postgis_tiger_geocoder
  pgrouting
  uuid-ossp
  vector
)
