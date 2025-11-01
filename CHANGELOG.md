# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) with PostgreSQL version alignment.

## [Unreleased]

## [17.2-v1.0.0] - TBD

### Added

#### Core Database
- PostgreSQL 17.2 on Debian Bookworm base image
- Custom Docker image with comprehensive extension suite
- Automated database initialization and configuration templating
- User and permission management via environment variables

#### Spatial Extensions
- PostGIS 3 with raster and topology support
- PostGIS Tiger Geocoder for US address normalization
- pgRouting for geospatial routing algorithms

#### Vector and Graph Database
- pgvector for AI/ML vector similarity search
- Apache AGE (latest) for graph database capabilities built from source

#### Performance and Optimization
- pg_squeeze built from source for online table bloat removal
- pg_stat_statements for query performance monitoring
- auto_explain for automatic query plan logging
- pg_buffercache for buffer cache inspection
- Connection pooling via PgBouncer 1.24.1

#### Maintenance and Operations
- pg_cron for scheduled job execution within PostgreSQL
- pg_partman for partition management automation
- pg_repack for online table reorganization
- pgBackRest for backup and recovery
- pgBadger for log analysis and reporting
- Automated logical backups with pg_dump

#### Security and Auditing
- pgaudit for detailed audit logging
- pgcrypto for cryptographic functions
- Network access controls with configurable pg_hba.conf
- Network probing and validation scripts

#### Testing and Development
- pgTAP for database unit testing
- HypoPG for hypothetical index analysis
- Python-based smoke test suite with pytest
- Docker Compose profiles for full and minimal deployments

#### Additional Extensions
- postgres_fdw and dblink for foreign data access
- hstore for key-value storage
- citext for case-insensitive text
- pg_trgm for trigram text search
- btree_gin and btree_gist for advanced indexing

#### Supporting Services
- PgHero for database performance monitoring and insights
- Valkey 7 (Redis-compatible) for caching and pub/sub
- RabbitMQ 3.13 with management interface for message queuing
- Memcached 1.6 for distributed caching
- Volume preparation service for proper permissions

#### Development Tools
- Comprehensive management script (`scripts/manage.sh`)
- Service URL discovery and health checks
- Docker diagnostics and troubleshooting tools
- Automated test fixtures and sample data

#### Documentation
- Best practices guide for Dockerized PostgreSQL 17
- Initial concept and architecture documentation
- Service configuration examples
- Environment variable reference

### Infrastructure
- Multi-profile Docker Compose configuration
- Health checks for all services
- Persistent volume management
- Network isolation and custom Docker networks
- Graceful shutdown handling

### Changed
- N/A (Initial release)

### Deprecated
- N/A (Initial release)

### Removed
- N/A (Initial release)

### Fixed
- N/A (Initial release)

### Security
- Implemented comprehensive audit logging
- Network access controls and isolation
- Secure credential management via environment variables
- No hardcoded secrets in repository

[unreleased]: https://github.com/paudley/core_data/compare/17.2-v1.0.0...HEAD
[17.2-v1.0.0]: https://github.com/paudley/core_data/releases/tag/17.2-v1.0.0
