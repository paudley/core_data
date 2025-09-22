# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# PostgreSQL configuration template rendered during init

listen_addresses = '*'
port = 5432
max_connections = 200
shared_buffers = 512MB
work_mem = 16MB
maintenance_work_mem = 256MB
effective_cache_size = 1536MB
shared_preload_libraries = 'pgaudit,pg_stat_statements,pg_cron,pg_squeeze,auto_explain,pg_buffercache'
wal_level = logical
archive_mode = on
archive_command = 'pgbackrest --config=/var/lib/postgresql/data/pgbackrest.conf --stanza=main archive-push %p'
archive_timeout = 60s
max_wal_senders = 10
wal_keep_size = 2GB
default_statistics_target = 200
random_page_cost = 1.1
autovacuum = on
autovacuum_max_workers = 5
autovacuum_naptime = 30s
autovacuum_analyze_scale_factor = 0.1
autovacuum_vacuum_scale_factor = 0.02
log_destination = 'csvlog'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 0
log_min_duration_statement = 500
pg_stat_statements.max = 10000
pg_stat_statements.track = all
pg_stat_statements.save = on
auto_explain.log_min_duration = 250
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_nested_statements = on
auto_explain.sample_rate = 1.0
log_line_prefix = '%m [%p] %q%u@%d '
pgaudit.log = 'write,ddl'
pgaudit.log_client = on
pgaudit.log_parameter = on
include_if_exists = 'postgresql.pgtune.conf'
cron.database_name = 'postgres'
cron.log_run = on
cron.max_running_jobs = 8
statement_timeout = 60000
lock_timeout = 10000
deadlock_timeout = 1000
datestyle = 'iso, mdy'
timezone = '${TZ}'
