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
- `/tmp` free: about `6.8G`
- Sure repo size: `138M`

### Disk-space gate

Use disk space as a bootstrap gate, not just an observation.

Hard minimums:

- `/`: `2 GiB`
- `/root`: `4 GiB`
- `/tmp`: `1 GiB`

Preferred safety buffer:

- `/root`: at least `2x` current repo size, with a `2 GiB` floor

If any hard minimum fails, stop and free space before continuing.

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
3. Read Ruby version from `.ruby-version` and install exactly that version.
4. Read Bundler version from `Gemfile.lock` and install exactly that version.
5. Prefer PostgreSQL client tooling instead of local PostgreSQL server.
6. Install Redis locally.
7. Keep caches and dependency storage under `/root`.
8. Record version drift when the host has a newer Node than the repo reference, but do not change it unless the repo proves sensitive to that drift.

## Step 2 result, missing OS packages installed

Installed on the reference host:

- `build-essential`
- `pkg-config`
- `libpq-dev`
- `postgresql-client`
- `redis-server`
- `libyaml-dev`
- `libvips`
- `libvips-dev`
- `libxml2-dev`
- `libxslt1-dev`
- `zlib1g-dev`

Re-audit result after install:

- `psql`: present, `15.16`
- `redis-server`: present, `7.0.15`
- `gcc`, `make`, and `pkg-config`: present
- Ruby: still missing
- Bundler: still missing
- disk-space gate: still `pass`

Disk effect observed on the reference host:

- `/` free dropped from about `6.8G` to about `6.3G`
- `/root` stayed around `6.0G` free
- the heaviest dependency expansion came from `libvips-dev`
- the post-install state still cleared the hard disk gate, so it was safe to continue

## Step 3 result, Ruby and Bundler installed

Installed on the reference host:

- `rbenv`
- `ruby-build`
- `libreadline-dev`
- `libgdbm-dev`
- `libgdbm-compat-dev`
- `bison`

Then:

- read Ruby version from `.ruby-version`
- read Bundler version from `Gemfile.lock`
- updated `/root/.rbenv/plugins/ruby-build` to a current upstream release so the repo-required Ruby was available
- installed the repo-required Ruby via `rbenv`
- installed the lockfile-compatible Bundler

Re-audit result after install:

- Ruby: present, `3.4.7`, detected via `/root/.rbenv/shims/ruby`
- Bundler: present, `2.6.7`, detected via `/root/.rbenv/shims/bundle`
- disk-space gate: still `pass`

Important findings:

- Debian's system Ruby may still exist on the host and can appear earlier on PATH in bare shells
- the audit helper must therefore prefer the `rbenv` toolchain when it matches repo requirements
- the Ruby bootstrap script should never hardcode a version, it should always read `.ruby-version`
- the Bundler bootstrap script should never hardcode a version, it should always read `Gemfile.lock`

## Step 4 result, runtime services and db bootstrap validated

Observed on the reference host:

- Redis package was installed but not running by default
- `redis-server --daemonize yes` worked
- `bundle exec rails runner 'puts Redis.new.ping'` returned `PONG`
- local PostgreSQL server was not present initially, so `rails db:prepare` failed with `PG::ConnectionBad` against `127.0.0.1:5432`
- after installing local PostgreSQL 15, starting the cluster manually, relaxing loopback auth to `trust`, and creating `sure_development` plus `sure_test`, `rails db:prepare` succeeded

Important implication:

- client-only PostgreSQL is the right default preference during early bootstrap
- but once `db:prepare` is the active blocker, a minimal local PostgreSQL server becomes justified for a self-contained development runtime on this host

## Suggested follow-up audit checks after installs

Preferred:

```bash
python3 .openclaw/skills/sure-openclaw-build-bootstrap/scripts/audit_sure_build_env.py /path/to/sure
```

Then add:

```bash
export RBENV_ROOT=/root/.rbenv
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init -)"

ruby -v
bundle -v
bundle config list
npm config get cache
redis-cli ping
POSTGRES_USER=root POSTGRES_DB=sure_development bundle exec rails db:prepare
```

This confirms both the toolchain and the persistence strategy.
