# Development with mise

Use mise 2026.10.17 or newer on Linux with glibc or macOS. Install Git, curl and
a C/C++ build toolchain first; native Ruby gems still compile locally. Native
Windows and musl Linux are not covered by this workflow; use the devcontainer.

From the checkout, run `mise trust`, `mise install`, then `mise run install`.
Tool installation is separate from application setup so a failed setup cannot
be hidden by a post-install hook warning. Ruby's prebuilt artifact attestation
and package checksum verification remain enabled. PostgreSQL, Redis and libvips
come from conda-forge through mise; no separate conda installation is needed.

`mise run install` installs gems into ignored `vendor/bundle`, uses frozen
Bundler resolution and `npm ci`, creates `.env.local` only if absent, preserves existing environment files,
starts services, prepares **both** development and test databases, and builds
Tailwind. It does not regenerate tracked token CSS or dump the schema.
The test helper supplies test defaults. `.env.test.example` contains optional
provider overrides; only copy and configure it deliberately, rather than as an
automatic setup step.

After an intentional token change use `npm run tokens:build`; after an intentional
migration use the normal Rails database commands and review the schema diff.

## Running and checking

- `mise run services`: start PostgreSQL and Redis if this checkout's services are
  stopped; repeated runs verify readiness without resetting data.
- `mise run dev`: start services, then Rails, Sidekiq and Tailwind. The watcher
  stays alive with closed stdin. Ctrl-C stops these application processes.
- `mise run check`: with the app running, check database access, libvips loading,
  a Sidekiq worker heartbeat, health response, and the registration form.
- `mise exec -- bin/rails test`: run the behavioral suite. Browser tests also need
  Chrome/Selenium as described in the development guide.

Database/Redis state and logs live under `storage/development-services`, which is
ignored and survives Rails `tmp:clear`. The default PostgreSQL role is `sure`.
PostgreSQL binds only to 127.0.0.1, uses trust authentication, and disables Unix
sockets. Redis also binds only to 127.0.0.1. This is local development data only.
The service task refuses to adopt another server already using its ports.

To stop services created by this checkout:

```sh
mise exec -- bash -c 'pg_ctl -D "$SURE_SERVICE_DIR/postgres" -m fast -w stop'
mise exec -- bash -c 'redis-cli -u "$REDIS_URL" shutdown'
```

Only use these stop commands for the managed local services, not an external
service configuration. Data is retained; rerun `mise run services` to restart.

## Configuration

Use environment variables or an ignored `mise.local.toml` for overrides:

```toml
[env]
DB_PORT = "55433"
SURE_REDIS_PORT = "56380"
REDIS_URL = "redis://127.0.0.1:56380/1"
PORT = "3001"
```

For existing services, set `SURE_MANAGED_SERVICES=0`, `DB_HOST`, `DB_PORT`,
`POSTGRES_USER`, and `REDIS_URL`, plus any needed credentials. The task checks
connectivity but does not start those services. Rails still reads `.env.local`
and `.env.test`, but mise's exported values take precedence. Put service/port
overrides in the shell or `mise.local.toml` so Rails and the service task agree.
Never commit credentials.

`SKIP_DB_SETUP=1 mise run install` skips service startup and database preparation.
Use it when installing dependencies without a database or when you need to
prepare nonstandard database names explicitly. Automatic preparation rejects
`DATABASE_URL` and `POSTGRES_DB` because they can point development and test at
the same database. Do not run development setup against production data.

Changing PostgreSQL's major version requires an explicit data migration; do not
point a new major version at an existing cluster. Stop the old services before
moving or deleting a checkout.

## Cloud environments

The cloud setup only needs to install mise, use writable mise/XDG cache and data
directories, and run the same repository commands above. There is no separate
`sure-tools/install.sh` or cloud-only dependency/service implementation. Keep
these directories in the environment snapshot; running processes must restart
in each task. Use the existing checkout rather than creating a worktree.

When the home directory is read-only, set `MISE_DATA_DIR`, `MISE_CACHE_DIR`,
`MISE_STATE_DIR`, `MISE_CONFIG_DIR`, and `XDG_CACHE_HOME` to writable locations
before installing tools. `XDG_CACHE_HOME` is also needed by Ruby's attestation
verifier. Do not disable verification to work around an unwritable cache.

Use internal HTTP requests for readiness in cloud onboarding; do not publish
localhost preview links. No bank, AI, email, or cloud-storage credentials are
required for this local workflow. Those integrations and browser automation
require their own configuration.
