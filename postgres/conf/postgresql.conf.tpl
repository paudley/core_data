# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# PostgreSQL configuration template rendered during init

listen_addresses = '${POSTGRES_LISTEN_ADDRESSES}'
port = 5432
max_connections = ${POSTGRES_MAX_CONNECTIONS}
shared_buffers = ${PG_SHARED_BUFFERS}
work_mem = ${PG_WORK_MEM}
maintenance_work_mem = ${PG_MAINTENANCE_WORK_MEM}
effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE}
shared_preload_libraries = 'pgaudit,pg_stat_statements,pg_cron,pg_squeeze,auto_explain,pg_buffercache,pg_partman_bgw'
wal_level = logical
archive_mode = on
archive_command = 'pgbackrest --config=/var/lib/postgresql/data/pgbackrest.conf --stanza=main archive-push %p'
archive_timeout = 60s
max_wal_senders = ${PG_MAX_WAL_SENDERS}
wal_keep_size = ${PG_WAL_KEEP_SIZE}
max_wal_size = ${PG_MAX_WAL_SIZE}
min_wal_size = ${PG_MIN_WAL_SIZE}
checkpoint_completion_target = ${PG_CHECKPOINT_COMPLETION_TARGET}
default_statistics_target = 200
random_page_cost = ${PG_RANDOM_PAGE_COST}
effective_io_concurrency = ${PG_EFFECTIVE_IO_CONCURRENCY}
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
log_min_duration_statement = ${PG_LOG_MIN_DURATION_STATEMENT}
pg_stat_statements.max = 10000
pg_stat_statements.track = all
pg_stat_statements.save = on
auto_explain.log_min_duration = 250
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_nested_statements = on
auto_explain.sample_rate = 1.0
pg_partman_bgw.interval = 3600
pg_partman_bgw.role = 'postgres'
pg_partman_bgw.dbname = 'postgres'
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
ssl = ${POSTGRES_SSL_ENABLED}
ssl_cert_file = '${POSTGRES_SSL_CERT_FILE}'
ssl_key_file = '${POSTGRES_SSL_KEY_FILE}'
ssl_prefer_server_ciphers = on
datestyle = 'iso, mdy'
timezone = '${TZ}'
