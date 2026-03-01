# Changelog

All notable changes to the Sure Helm chart will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.9-alpha] - 2026-03-01

### Added
- **Pipelock security proxy** (`pipelock.enabled=true`): Separate Deployment + Service that provides two scanning layers
  - **Forward proxy** (port 8888): Scans outbound HTTPS from Faraday-based clients (e.g. ruby-openai). Auto-injects `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` env vars into app pods
  - **MCP reverse proxy** (port 8889): Scans inbound MCP traffic for DLP, prompt injection, and tool poisoning. Auto-computes upstream URL via `sure.pipelockUpstream` helper
  - **WebSocket proxy** configuration support (disabled by default, requires Pipelock >= 0.2.9)
  - ConfigMap with scanning config (DLP, prompt injection detection, MCP input/tool scanning, response scanning)
  - ConfigMap checksum annotation for automatic pod restart on config changes
  - Helm helpers: `sure.pipelockImage`, `sure.pipelockUpstream`
  - Health and readiness probes on the Pipelock deployment
  - `imagePullSecrets` with fallback to app-level secrets
  - Boolean safety: uses `hasKey` to prevent Helm's `default` from swallowing explicit `false`
  - Configurable ports via `forwardProxy.port` and `mcpProxy.port` (single source of truth across Service, Deployment, and env vars)
- `pipelock.example.yaml` reference config for Docker Compose deployments

### Changed
- Consolidated `compose.example.pipelock.yml` into `compose.example.ai.yml` — Pipelock now runs alongside Ollama in one compose file with health checks, config volume mount, and MCP env vars (`MCP_API_TOKEN`, `MCP_USER_EMAIL`)
- CI: Pipelock scan `fail-on-findings` changed from `false` to `true`; added `exclude-paths` for locale help text false positives

## [0.6.7-alpha] - 2026-01-10

### Added
- **Redis Sentinel support for Sidekiq high availability**: Application now automatically detects and configures Sidekiq to use Redis Sentinel when `redisOperator.mode=sentinel` and `redisOperator.sentinel.enabled=true`
  - New Helm template helpers (`sure.redisSentinelEnabled`, `sure.redisSentinelHosts`, `sure.redisSentinelMaster`) for Sentinel configuration detection
  - Automatic injection of `REDIS_SENTINEL_HOSTS` and `REDIS_SENTINEL_MASTER` environment variables when Sentinel mode is enabled
  - Sidekiq configuration supports Sentinel authentication with `sentinel_username` (defaults to "default") and `sentinel_password`
  - Robust validation of Sentinel endpoints with port range checking (1-65535) and graceful fallback to direct Redis URL on invalid configuration
  - Production-ready HA timeouts: 200ms connect, 1s read/write, 3 reconnection attempts
  - Backward compatible with existing `REDIS_URL` deployments

### [0.6.6] - 2025-12-31

### Added

- First version/release that aligns versions with monorepo
- CNPG: render `Cluster.spec.backup` from `cnpg.cluster.backup`.
  - If `backup.method` is omitted and `backup.volumeSnapshot` is present, the chart will infer `method: volumeSnapshot`.
  - For snapshot backups, `backup.volumeSnapshot.className` is required (template fails early if missing).
  - Example-only keys like `backup.ttl` and `backup.volumeSnapshot.enabled` are stripped to avoid CRD warnings.
- CNPG: render `Cluster.spec.plugins` from `cnpg.cluster.plugins` (enables barman-cloud plugin / WAL archiver configuration).

### [0.0.0], [0.6.5]

### Added

- First (nightly/test) releases via <https://we-promise.github.io/sure/index.yaml>

## Notes
- Chart version and application version are kept in sync
- Requires Kubernetes >= 1.25.0
- When upgrading from pre-Sentinel configurations, existing deployments using `REDIS_URL` continue to work unchanged
