---
name: sure-openclaw-build-bootstrap
description: Bootstrap a lean, repeatable Sure build and test environment inside an OpenClaw workspace or similar container/VM. Use when setting up a fresh build environment, auditing missing dependencies before running Sure tests, or turning environment learnings into a repeatable bootstrap flow.
---

# Sure OpenClaw build bootstrap

Use this skill when you need to stand up or re-audit a Sure development environment inside an existing OpenClaw-hosted machine, especially when the goal is to run the Rails test and lint suite without introducing nested Docker or local Postgres state.

## Goal

Create a repeatable bootstrap flow that keeps the environment lean:

- run directly inside the current OpenClaw container or VM when that is the better fit
- prefer the repo devcontainer when the host is a normal non-virtualized machine
- avoid nested Docker or devcontainers as runtime when already inside a constrained VM or container
- prefer rebuildable local services over persistent heavyweight state
- prefer external Postgres for app data when disk is limited

## Workflow

1. Run a baseline environment audit before installing anything.
2. Let the audit decide whether to prefer an in-place bootstrap or the repo devcontainer.
3. Compare the host state with the repo's declared expectations.
4. Gate every material bootstrap step on disk space. Do not continue if the audit fails the disk check.
5. Install only missing pieces.
6. Keep persistent caches under `/root` or another durable host path.
7. Treat local Redis as acceptable, but avoid local Postgres data unless there is a strong reason.
8. Re-run the audit after each material setup step.

## Disk-space gating rules

Treat disk headroom as a hard safety check, not just a nice-to-have.

Current audit gates:

- `/` must have at least `2 GiB` free
- `/root` must have at least `4 GiB` free
- `/tmp` must have at least `1 GiB` free
- `/root` should also keep a preferred buffer of at least `2x` current repo size, with a `2 GiB` floor

Interpretation:

- `pass`: safe to continue
- `warn`: above hard minimums but below preferred buffer, continue carefully
- `fail`: stop and free disk before installing more dependencies or caches

If the audit reports `stop-and-free-disk-space`, do that before the next bootstrap step.

## Step 3, install Ruby and Bundler

Preferred path on the reference host:

- read `.ruby-version` from the repo and use that exact Ruby version
- read `Gemfile.lock` and use the exact `BUNDLED WITH` version
- install `rbenv` and `ruby-build` from apt
- update the `ruby-build` plugin inside `/root/.rbenv/plugins/ruby-build` because Debian Bookworm's packaged definitions may be too old for the repo-required Ruby
- install the repo-required Ruby with `rbenv`
- install the lockfile-compatible Bundler with `gem`

Install missing Ruby build helpers:

```bash
apt-get install -y --no-install-recommends \
  rbenv ruby-build libreadline-dev libgdbm-dev libgdbm-compat-dev bison
```

Refresh `ruby-build` definitions and install Ruby from repo metadata:

```bash
RUBY_VERSION="$(tr -d '[:space:]' < .ruby-version)"
BUNDLER_VERSION="$(awk '/^BUNDLED WITH$/{getline; gsub(/^[[:space:]]+/, ""); print; exit}' Gemfile.lock)"

mkdir -p /root/.rbenv/plugins
rm -rf /root/.rbenv/plugins/ruby-build
git clone --depth=1 https://github.com/rbenv/ruby-build.git /root/.rbenv/plugins/ruby-build

export RBENV_ROOT=/root/.rbenv
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init -)"
export RUBY_BUILD_CACHE_PATH=/root/.cache/ruby-build

rbenv install -s "$RUBY_VERSION"
rbenv global "$RUBY_VERSION"
rbenv rehash
```

Install the lockfile-compatible Bundler:

```bash
gem install bundler -v "$BUNDLER_VERSION" --no-document
rbenv rehash
bundle -v
```

Important notes:

- never hardcode the Ruby version in the bootstrap flow, always read `.ruby-version`
- never hardcode the Bundler version in the bootstrap flow, always read `Gemfile.lock`
- the host may still also have Debian's system Ruby on PATH, so the audit helper is expected to prefer the `rbenv` Ruby and Bundler when they match repo requirements

## Step 2, install only missing OS packages

On the first reference host, the missing OS-level pieces were:

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

Install them with:

```bash
apt-get update && apt-get install -y --no-install-recommends \
  build-essential pkg-config libpq-dev postgresql-client redis-server \
  libyaml-dev libvips libvips-dev libxml2-dev libxslt1-dev zlib1g-dev
```

Then clean package metadata if image size matters:

```bash
apt-get clean && rm -rf /var/lib/apt/lists/*
```

After this step on the reference host:

- `psql` became available
- `redis-server` became available
- native build tooling became available
- Ruby and Bundler were still missing, so Rails work was still blocked on the next step
- disk-space gate still passed after installation, which is required before moving on

Important note: `libvips-dev` pulls a large transitive dependency set on Debian Bookworm. Keep it because Sure's devcontainer references it, but treat it as the heaviest part of this OS-package step.

## Step 1, baseline audit

Use the helper script first:

```bash
python3 .openclaw/skills/sure-openclaw-build-bootstrap/scripts/audit_sure_build_env.py /path/to/sure
```

Optional JSON output:

```bash
python3 .openclaw/skills/sure-openclaw-build-bootstrap/scripts/audit_sure_build_env.py /path/to/sure --json
```

The script checks:

- whether the host appears virtualized or containerized
- whether core tools are present
- which Ruby and Bundler versions the repo expects
- whether the current Node version drifts from the devcontainer reference
- available disk space and current repo size
- whether hard disk-space gates pass before continuing
- whether the environment should prefer a lean in-place bootstrap or a devcontainer-first approach

If you need to debug or extend it manually, these are the underlying checks:

```bash
ruby -v
bundle -v
node -v
npm -v
psql --version
redis-server --version
df -h / /root /tmp
du -sh /path/to/sure
cat .ruby-version
grep -n '^BUNDLED WITH$' -A1 Gemfile.lock
grep -n '^ruby ' Gemfile
```

## Current known baseline from the first audit

On the first reference host, the baseline was:

- Ruby: missing
- Bundler: missing
- Node: `v24.14.1`
- npm: `11.11.0`
- `psql`: missing
- `redis-server`: missing
- Sure checkout size: `138M`
- free space on `/`: about `6.8G`
- free space on `/root`: about `6.0G`
- repo requires Ruby `3.4.7`
- `Gemfile.lock` expects Bundler `2.6.7`
- devcontainer reference uses Node `20.x`, PostgreSQL client, and Redis

This tells you the environment cannot run Rails tests yet, but it has enough free space to proceed with a lean bootstrap.

## Decision rules

- If the audit says the host is not virtualized, strongly consider the repo devcontainer as the default setup path.
- If the audit says the host is already virtualized or containerized, prefer a lean in-place bootstrap unless there is a strong reason to nest containers.
- If Ruby is absent, install the repo-required version first.
- If Bundler is absent, install the exact lockfile-compatible version.
- If Node is present but newer than the repo reference, note the drift rather than changing it immediately.
- If `psql` is absent, install client tooling only unless the task explicitly requires local Postgres.
- If Redis is absent, install and run it locally.
- Do not assume devcontainer contents should be mirrored exactly. Use it as reference, not runtime.

## Step 4, runtime services and database bootstrap

After Ruby, Bundler, and gems are in place, validate the runtime services.

Redis on this host does not auto-start through system services, so a lightweight local start is acceptable:

```bash
redis-server --daemonize yes
redis-cli ping
```

For PostgreSQL, prefer client-only by default, but once `rails db:prepare` is the next blocker, install the minimal local server path:

```bash
apt-get update && apt-get install -y --no-install-recommends postgresql
pg_ctlcluster --skip-systemctl-redirect 15 main start
pg_isready -h 127.0.0.1 -p 5432
```

For this bootstrap host, local development auth was relaxed to `trust` on loopback so Rails could prepare the database without extra secret wiring:

```bash
PG_HBA_CONF=/etc/postgresql/15/main/pg_hba.conf
sed -i 's/^local\s\+all\s\+all\s\+peer$/local   all             all                                     trust/' "$PG_HBA_CONF"
sed -i 's/^host\s\+all\s\+all\s\+127.0.0.1\/32\s\+scram-sha-256$/host    all             all             127.0.0.1\/32            trust/' "$PG_HBA_CONF"
sed -i 's/^host\s\+all\s\+all\s\+::1\/128\s\+scram-sha-256$/host    all             all             ::1\/128                 trust/' "$PG_HBA_CONF"
pg_ctlcluster --skip-systemctl-redirect 15 main reload
```

Then create the expected local role and databases:

```bash
runuser -l postgres -c "createuser -s root" 2>/dev/null || true
runuser -l postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='sure_development'\" | grep -q 1 || createdb sure_development"
runuser -l postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='sure_test'\" | grep -q 1 || createdb sure_test"
```

Finally run the Rails bootstrap check:

```bash
export RBENV_ROOT=/root/.rbenv
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init -)"
POSTGRES_USER=root POSTGRES_DB=sure_development bundle exec rails db:prepare
```

If this succeeds, the environment has crossed from package bootstrap into a working local Rails dev runtime.

## Resources

- `scripts/audit_sure_build_env.py` for a repeatable baseline audit, disk-space gate, and strategy recommendation.
- `scripts/install_repo_ruby_and_bundler.sh` for repo-driven Ruby and Bundler setup.
- `references/baseline-environment-audit.md` for the captured step-by-step findings and rationale.
