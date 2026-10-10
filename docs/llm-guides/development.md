# Development and verification

## Environment and commands

Use the Ruby version in [`.ruby-version`](../../.ruby-version) and dependencies in
[`Gemfile`](../../Gemfile) / [`package.json`](../../package.json).
[CONTRIBUTING.md](../../CONTRIBUTING.md) describes local and devcontainer setup.
Start environment configuration from [`.env.local.example`](../../.env.local.example)
and [`.env.test.example`](../../.env.test.example); never commit secrets or local credentials.

These are command references, not permission to start servers, restart the app,
edit credentials or automatically migrate a database. Run setup/database operations
only when that environment work has been explicitly requested. In particular,
`bin/setup` prepares the database and restarts the app; it is not a read-only check.

| Task | Command |
| --- | --- |
| Initial setup | `cp .env.local.example .env.local` (only if the file does not exist), then `bin/setup` |
| Development processes | `bin/dev` (Rails, Sidekiq, Tailwind watcher) |
| Rails console | `bin/rails console` |
| Database preparation / migration | `bin/rails db:prepare` / `bin/rails db:migrate` |
| Database rollback / seed | `bin/rails db:rollback` / `bin/rails db:seed` |
| Rails tests (excluding system tests) | `bin/rails test` |
| One file / test at a line | `bin/rails test test/models/account_test.rb` / `bin/rails test test/models/account_test.rb:42` |
| Reset test database and test | `bin/rails test:db` (database-changing task) |
| System tests | `PARALLEL_WORKERS=2 bin/rails test:system` |
| Ruby lint | `bin/rubocop` |
| Safe Ruby autocorrection | `bin/rubocop -a` (`-A` also enables unsafe corrections) |
| JavaScript/TypeScript lint / fix | `npm run lint` / `npm run lint:fix` |
| Biome formatting check / fix | `npm run format:check` / `npm run format` |
| Security analysis | `bin/brakeman --no-pager` |

Lookbook is mounted at `/design-system` outside production; see
[`config/routes.rb`](../../config/routes.rb). Letter Opener supports development
email previews. Use Docker/devcontainers where useful for consistent environments.

## Before opening a pull request

Run these checks locally before **every** PR. All required checks must pass before
PR creation; the full suite is also required to be green before pushing.

1. `bin/rails test` — the full Minitest suite is always required.
2. `PARALLEL_WORKERS=2 bin/rails test:system` — required when system tests
   are applicable to the change; keep system-test additions focused on critical flows.
3. `bin/rubocop -f github -a` — Ruby lint with safe autocorrection.
4. `bundle exec erb_lint ./app/**/*.erb -a` — ERB lint with autocorrection.
5. `npm run lint` — keep Biome clean. Use `npm run format:check` for formatting
   changes and `npm run format` when corrections are needed.
6. `bin/brakeman --no-pager` — security analysis for every PR.

Inspect autocorrections before committing; keep the diff focused. Record checks
and any failures accurately. Focused tests help during development but do not
replace the required full pre-PR suite.

CI has its own executable definition in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)
and callers. Its unit and system jobs are separate; CI runs system tests even though
the local checklist makes them conditional on applicability. Local ERB lint is an
existing additional requirement. Passing local checks does not replace the
[contributor requirement](../../CONTRIBUTING.md#making-a-pull-request) for green
GitHub checks and an up-to-date branch before requesting review.

## System tests in a devcontainer

The [devcontainer configuration](../../.devcontainer/docker-compose.yml) includes
Selenium Chromium and sets `SELENIUM_REMOTE_URL`; no local Chrome is needed there.
Run `PARALLEL_WORKERS=2 bin/rails test:system`. Watch the browser at
`http://localhost:7900` or `http://localhost:4444` (development password: `secret`).

Rails isolates each process in its own test database and browser session. The
recommended two workers leave CPU headroom for Rails and browser rendering. The
devcontainer's Selenium service supports up to four sessions; never exceed that
limit. Lower the worker count on machines with fewer CPUs or less available RAM.
Use `PARALLEL_WORKERS=1` for a serial run when investigating a failure; the existing
`DISABLE_PARALLELIZATION=true` override also remains supported. Remote parallel
runs need a distinct server port per worker, so leave `CAPYBARA_SERVER_PORT` unset.

For timing investigations, use `--seed=12345` for repeatable test selection/order
and `--verbose` for individual test durations. Record worker counts and compare
full suites on the same machine with the same `COVERAGE` setting. Time Rails tests,
browser tests and setup separately: CI runs the two test jobs concurrently, while
running the local commands one after another adds their durations.
