#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Canonical list of default extensions enabled across bootstrap flows.
# Note: Order matters for dependencies (e.g., cube must come before earthdistance)
# shellcheck disable=SC2034
CORE_EXTENSION_LIST=(
	age
	btree_gin
	btree_gist
	citext
	cube
	dblink
	earthdistance
	fuzzystrmatch
	hstore
	intarray
	ltree
	bloom
	pg_buffercache
	pg_cron
	pg_partman
	pg_prewarm
	hypopg
	pg_repack
	pg_squeeze
	pg_stat_statements
	pg_trgm
	pgcrypto
	pgsodium
	gzip
	zstd
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
	tablefunc
	unaccent
	uuid-ossp
	vector
)

# Canonical list of libraries that must be in shared_preload_libraries.
# Enforced on every container startup regardless of config state.
# shellcheck disable=SC2034
REQUIRED_PRELOAD_LIBRARIES=(
	age
	pgaudit
	pg_stat_statements
	pg_cron
	pg_squeeze
	auto_explain
	pg_buffercache
	pg_partman_bgw
	pgsodium
)
