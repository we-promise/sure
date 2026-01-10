# Changelog

All notable changes to the Sure Helm chart will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### [0.0.0]

- First (nightly/test) releases via <https://we-promise.github.io/sure/index.yaml>

### [0.6.5]

- First version/release that aligns versions with monorepo
- CNPG: render `Cluster.spec.backup` from `cnpg.cluster.backup`.
  - If `backup.method` is omitted and `backup.volumeSnapshot` is present, the chart will infer `method: volumeSnapshot`.
  - For snapshot backups, `backup.volumeSnapshot.className` is required (template fails early if missing).
  - Example-only keys like `backup.ttl` and `backup.volumeSnapshot.enabled` are stripped to avoid CRD warnings.
- CNPG: render `Cluster.spec.plugins` from `cnpg.cluster.plugins` (enables barman-cloud plugin / WAL archiver configuration).

## [0.6.7-alpha] - 2026-01-10

### Added
- **Redis Sentinel support for Sidekiq high availability**: Application now automatically detects and configures Sidekiq to use Redis Sentinel when `redisOperator.mode=sentinel` and `redisOperator.sentinel.enabled=true`
  - New Helm template helpers (`sure.redisSentinelEnabled`, `sure.redisSentinelHosts`, `sure.redisSentinelMaster`) for Sentinel configuration detection
  - Automatic injection of `REDIS_SENTINEL_HOSTS` and `REDIS_SENTINEL_MASTER` environment variables when Sentinel mode is enabled
  - Sidekiq configuration supports Sentinel authentication with `sentinel_username` (defaults to "default") and `sentinel_password`
  - Robust validation of Sentinel endpoints with port range checking (1-65535) and graceful fallback to direct Redis URL on invalid configuration
  - Production-ready HA timeouts: 200ms connect, 1s read/write, 3 reconnection attempts
  - Backward compatible with existing `REDIS_URL` deployments

## Notes
- Chart version and application version are kept in sync
- Requires Kubernetes >= 1.25.0
- When upgrading from pre-Sentinel configurations, existing deployments using `REDIS_URL` continue to work unchanged