# PgBouncer Transaction Pooling Guide

This guide covers using PgBouncer in transaction pooling mode with core_data.

## Overview

**Transaction pooling** assigns a server connection to a client only for the duration of a transaction. After `COMMIT` or `ROLLBACK`, the connection returns to the pool and may be assigned to a different client.

### Port Architecture

| Port | Service | Use Case |
|------|---------|----------|
| 5432 | PgBouncer | Default client connections (pooled) |
| 6432 | PgBouncer | Legacy PgBouncer port (pooled) |
| 5433 | PostgreSQL | Direct connections (bypasses pooling) |

### When to Use Transaction Mode

- High connection count applications (serverless, microservices)
- Short-lived transactions
- Applications that don't rely on session state

### When to Use Session Mode

Set `PGBOUNCER_POOL_MODE=session` if you need:
- Prepared statements without PgBouncer 1.21+ support
- LISTEN/NOTIFY
- Advisory locks
- Long-running cursors

## Transaction Mode Limitations & Solutions

### 1. Prepared Statements

**Issue**: Traditional prepared statements fail because the backend connection may change between `PREPARE` and `EXECUTE`.

**Solution**: PgBouncer 1.21+ with `max_prepared_statements` (enabled by default in core_data):
```bash
PGBOUNCER_MAX_PREPARED_STATEMENTS=1024  # Default
```

PgBouncer automatically tracks protocol-level prepared statements and re-prepares them when a client gets a new backend connection.

**Note**: SQL-level `PREPARE`/`DEALLOCATE` commands are NOT tracked. Use your driver's native prepared statement support.

### 2. Session Variables (SET Commands)

**Issue**: `SET` commands affect session state that doesn't persist across connection reassignments.

**Solutions**:
1. **Use `SET LOCAL`** (recommended) - affects only current transaction:
   ```sql
   BEGIN;
   SET LOCAL work_mem = '256MB';
   -- query runs with 256MB work_mem
   COMMIT;  -- setting automatically reverts
   ```

2. **Connection string parameters**:
   ```
   postgresql://user@host:5432/db?options=-c%20search_path%3Dmyschema
   ```

3. **Role-level defaults** (for permanent settings):
   ```sql
   ALTER ROLE myuser SET search_path = myschema;
   ```

### 3. LISTEN/NOTIFY

**Issue**: `LISTEN` establishes a persistent subscription that breaks when connections are reassigned.

**Solutions**:
1. Connect directly to PostgreSQL on port 5433 for LISTEN channels
2. Use RabbitMQ (included in core_data) for pub/sub patterns
3. Use session pooling mode for notification-heavy workloads

### 4. Temporary Tables

**Issue**: Temporary tables exist only for the session lifetime.

**Solutions**:
1. Create and use temp tables within a single transaction:
   ```sql
   BEGIN;
   CREATE TEMP TABLE tmp_results (id int) ON COMMIT DROP;
   INSERT INTO tmp_results SELECT ...;
   SELECT * FROM tmp_results;
   COMMIT;  -- table automatically dropped
   ```

2. Use CTEs (WITH clauses) for intermediate results:
   ```sql
   WITH tmp AS (SELECT ... complex query ...)
   SELECT * FROM tmp WHERE ...;
   ```

### 5. Advisory Locks

**Issue**: Session-level advisory locks (`pg_advisory_lock()`) may be held by a different client after connection reassignment.

**Solution**: Use transaction-level advisory locks:
```sql
BEGIN;
SELECT pg_advisory_xact_lock(12345);  -- released on COMMIT/ROLLBACK
-- do work
COMMIT;
```

### 6. Cursors (WITH HOLD)

**Issue**: `DECLARE CURSOR WITH HOLD` survives transaction boundaries but not connection reassignments.

**Solutions**:
1. Avoid `WITH HOLD` - use standard cursors within transactions
2. Implement pagination at application level:
   ```sql
   SELECT * FROM large_table
   WHERE id > $last_seen_id
   ORDER BY id LIMIT 100;
   ```

## Client Library Configuration

### Python

**psycopg2**:
```python
import psycopg2

conn = psycopg2.connect(
    host="localhost",
    port=5432,  # PgBouncer
    dbname="app_main",
    sslmode="require"
)

# Use SET LOCAL in transactions
with conn:
    with conn.cursor() as cur:
        cur.execute("SET LOCAL work_mem = '256MB'")
        cur.execute("SELECT ...")
```

**psycopg3 (psycopg)**:
```python
import psycopg
from psycopg.pool import ConnectionPool

pool = ConnectionPool(
    conninfo="host=localhost port=5432 dbname=app_main sslmode=require",
    kwargs={"prepare_threshold": None}  # Disable client-side statement caching
)
```

**SQLAlchemy**:
```python
from sqlalchemy import create_engine
from sqlalchemy.pool import NullPool

# Let PgBouncer handle pooling
engine = create_engine(
    "postgresql://user:pass@localhost:5432/app_main",
    poolclass=NullPool
)
```

**asyncpg**:
```python
import asyncpg

pool = await asyncpg.create_pool(
    host="localhost",
    port=5432,
    database="app_main",
    ssl="require",
    statement_cache_size=0  # Critical for transaction pooling
)
```

### Node.js

**node-postgres (pg)**:
```javascript
const { Pool } = require('pg');

const pool = new Pool({
  host: 'localhost',
  port: 5432,
  database: 'app_main',
  ssl: { rejectUnauthorized: false },
  max: 20,  // PgBouncer handles actual pooling
  idleTimeoutMillis: 30000
});
```

**Prisma**:
```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")       // PgBouncer URL with ?pgbouncer=true
  directUrl = env("DIRECT_DATABASE_URL") // Direct PostgreSQL for migrations
}
```

Connection strings:
```bash
DATABASE_URL="postgresql://user:pass@localhost:5432/app_main?pgbouncer=true&connection_limit=1"
DIRECT_DATABASE_URL="postgresql://user:pass@localhost:5433/app_main"  # Port 5433 for migrations
```

### Go

**pgx**:
```go
config, _ := pgxpool.ParseConfig(connString)
config.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
pool, _ := pgxpool.NewWithConfig(context.Background(), config)
```

**database/sql with lib/pq**:
```go
db, _ := sql.Open("postgres", connString)
db.SetMaxOpenConns(20)
db.SetMaxIdleConns(5)
db.SetConnMaxLifetime(5 * time.Minute)
```

### Java (JDBC/HikariCP)

```java
HikariConfig config = new HikariConfig();
config.setJdbcUrl("jdbc:postgresql://localhost:5432/app_main");
config.setMaximumPoolSize(1);  // Let PgBouncer handle pooling
config.addDataSourceProperty("prepareThreshold", "0");
```

## Troubleshooting

### Common Errors

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `prepared statement "..." does not exist` | Statement cache miss after connection reassignment | Disable client statement cache or ensure `max_prepared_statements` > 0 |
| `relation "pg_temp_..." does not exist` | Temp table on different connection | Use temp tables within single transaction with `ON COMMIT DROP` |
| `cannot execute ... in read-only transaction` | Connection in unexpected state | Verify `server_reset_query = DISCARD ALL` |
| `SSL connection closed unexpectedly` | TLS termination issue | Check `PGBOUNCER_CLIENT_TLS_SSLMODE` configuration |
| `no more connections allowed` | Max connections reached | Increase `PGBOUNCER_MAX_CLIENT_CONN` |

### Diagnostic Commands

```bash
# View pool statistics
./scripts/manage.sh pgbouncer-stats

# View active pools
./scripts/manage.sh pgbouncer-pools

# View PgBouncer logs
docker compose logs pgbouncer
```

**Admin console queries** (connect to pgbouncer database):
```sql
SHOW POOLS;      -- Connection pool status
SHOW CLIENTS;    -- Connected clients
SHOW SERVERS;    -- Backend connections
SHOW STATS;      -- Query statistics
SHOW CONFIG;     -- Current configuration
```

### Key Metrics to Monitor

| Metric | Healthy Range | Issue Indicator |
|--------|---------------|-----------------|
| `sv_active` | < `default_pool_size` | High = pool saturation |
| `sv_idle` | > 0 | 0 = no spare capacity |
| `cl_waiting` | 0 | > 0 = clients queued |
| `avg_query_time` | Application-dependent | Sudden increase = problem |
| `maxwait` | < `query_wait_timeout` | High = pool exhaustion |

## Configuration Reference

### PgBouncer Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `PGBOUNCER_POOL_MODE` | transaction | Pooling mode (session/transaction/statement) |
| `PGBOUNCER_MAX_PREPARED_STATEMENTS` | 1024 | Prepared statement cache per connection |
| `PGBOUNCER_MAX_CLIENT_CONN` | 200 | Maximum client connections |
| `PGBOUNCER_DEFAULT_POOL_SIZE` | 20 | Server connections per database/user |
| `PGBOUNCER_SERVER_LIFETIME` | 1800 | Max server connection age (seconds) |
| `PGBOUNCER_SERVER_IDLE_TIMEOUT` | 300 | Close idle server connections after (seconds) |
| `PGBOUNCER_QUERY_WAIT_TIMEOUT` | 30 | Max time client waits for connection |
| `PGBOUNCER_CLIENT_IDLE_TIMEOUT` | 3600 | Close idle client connections after (seconds) |

### PostgreSQL Settings (Transaction Pooling Optimized)

| Variable | Default | Description |
|----------|---------|-------------|
| `PG_PLAN_CACHE_MODE` | auto | Plan caching strategy |
| `PG_JIT_ENABLED` | on | JIT compilation for complex queries |
| `PG_TCP_KEEPALIVES_IDLE` | 60 | Detect dead connections quickly |
| `PG_MAX_PARALLEL_WORKERS_PER_GATHER` | 4 | Parallel query workers |

See `.env.example` for complete configuration options.
