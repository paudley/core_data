[databases]
* = host=${POSTGRES_HOST} port=${POSTGRES_PORT} auth_user=${PGBOUNCER_AUTH_USER}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${PGBOUNCER_PORT}
auth_type = scram-sha-256
auth_user = ${PGBOUNCER_AUTH_USER}
auth_file = /etc/pgbouncer/userlist.txt
auth_query = SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=$1
pool_mode = ${PGBOUNCER_POOL_MODE}
max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN}
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE}
reserve_pool_size = ${PGBOUNCER_RESERVE_POOL_SIZE}
reserve_pool_timeout = ${PGBOUNCER_RESERVE_POOL_TIMEOUT}
min_pool_size = ${PGBOUNCER_MIN_POOL_SIZE}
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits
admin_users = ${PGBOUNCER_ADMIN_USERS}
stats_users = ${PGBOUNCER_STATS_USERS}
tls_mode = disable
unix_socket_dir = /tmp
client_tls_sslmode = disable
server_tls_sslmode = disable
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
