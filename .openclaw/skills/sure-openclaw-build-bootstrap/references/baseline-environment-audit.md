# Baseline environment audit

This reference captures the first real audit of the Sure repository running inside the existing OpenClaw workspace container.

## Why this matters

Before installing anything, confirm what already exists. This prevents unnecessary packages, avoids masking version drift, and gives future bootstrap runs a stable starting point.

## Reference host result

Audit timestamp context: 2026-04-26, Discord build thread for SureBot environment setup.

### Tool availability

- `ruby`: missing
- `bundle`: missing
- `node`: `v24.14.1`
- `npm`: `11.11.0`
- `psql`: missing
- `redis-server`: missing
- `git`: present, `2.39.5`
- `curl`: present, `7.88.1`

### Disk and repo footprint

- `/` free: about `6.8G`
- `/root` free: about `6.0G`
- Sure repo size: `138M`

### Repo-declared expectations

- `.ruby-version`: `3.4.7`
- `Gemfile` defers Ruby version to `.ruby-version`
- `Gemfile.lock` expects Bundler `2.6.7`
- `package.json` is light and currently only declares Biome-based JS tooling

### Devcontainer reference hints

The repo's devcontainer is useful as a source of expectations, but should not be treated as the runtime target for this environment.

Observed hints:

- Ruby `3.4.x` slim Bookworm image
- `postgresql-client`
- `libpq-dev`
- Redis service
- Node `20.x`

## Interpretation

At baseline, the environment is incomplete for Rails work:

- Rails commands cannot run because Ruby and Bundler are absent.
- Database connectivity checks cannot run because `psql` is absent.
- Local cache or background job assumptions that depend on Redis will fail until Redis is installed.
- Node and npm are already available, so JavaScript lint tooling is likely the least risky part of the bootstrap.

## Bootstrap implications

1. Decide strategy from host classification first.
   - If already virtualized or containerized, prefer a lean in-place bootstrap.
   - If not virtualized, consider the repo devcontainer the default path.
2. Install only what is missing.
3. Pin Ruby to `3.4.7`.
4. Use Bundler `2.6.7` to match the lockfile.
5. Prefer PostgreSQL client tooling instead of local PostgreSQL server.
6. Install Redis locally.
7. Keep caches and dependency storage under `/root`.
8. Record version drift when the host has a newer Node than the repo reference, but do not change it unless the repo proves sensitive to that drift.

## Suggested follow-up audit checks after installs

Preferred:

```bash
python3 .openclaw/skills/sure-openclaw-build-bootstrap/scripts/audit_sure_build_env.py /path/to/sure
```

Then add:

```bash
bundle config list
npm config get cache
```

This confirms both the toolchain and the persistence strategy.
