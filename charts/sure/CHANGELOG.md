# Changelog

All notable changes to the Sure Helm chart will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-01-10

### Added
- **Redis Sentinel support for Sidekiq high availability**: Application now automatically detects and configures Sidekiq to use Redis Sentinel when `redisOperator.mode=sentinel` and `redisOperator.sentinel.enabled=true`
  - New Helm template helpers (`sure.redisSentinelEnabled`, `sure.redisSentinelHosts`, `sure.redisSentinelMaster`) for Sentinel configuration detection
  - Automatic injection of `REDIS_SENTINEL_HOSTS` and `REDIS_SENTINEL_MASTER` environment variables when Sentinel mode is enabled
  - Sidekiq configuration supports Sentinel authentication with `sentinel_username` (defaults to "default") and `sentinel_password`
  - Robust validation of Sentinel endpoints with port range checking (1-65535) and graceful fallback to direct Redis URL on invalid configuration
  - Production-ready HA timeouts: 200ms connect, 1s read/write, 3 reconnection attempts
  - Backward compatible with existing `REDIS_URL` deployments

### Changed
- Updated application environment variable injection logic to support Sentinel configuration alongside direct Redis URLs

### Fixed
- NOAUTH authentication errors when connecting to password-protected Sentinel nodes by adding proper authentication credentials

## Notes
- Chart version 1.0.0 targets application version 0.6.5
- Requires Kubernetes >= 1.25.0
- When upgrading from pre-Sentinel configurations, existing deployments using `REDIS_URL` continue to work unchanged
