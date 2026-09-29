# Deploying Sure on Hostim.dev

[Hostim.dev](https://hostim.dev) is a managed container-hosting platform that runs
Sure with a managed PostgreSQL database, managed Redis, persistent storage, and
automatic HTTPS — no server to provision or maintain.

## One-click template

Sure is available as a one-click template. It provisions the Rails web server, the
Sidekiq background worker, PostgreSQL, and Redis for you, and generates
`SECRET_KEY_BASE` automatically.

1. Open the [Sure template](https://console.hostim.dev/dashboard?preview=1&modal=1&template=sure).
2. Choose a resource plan.
3. Click **Deploy**.
4. Open the generated domain and create your first account.

A full walkthrough is in the [Hostim.dev Sure guide](https://hostim.dev/docs/templates/sure).

## Manual setup

To configure the app yourself, create an app from the `ghcr.io/we-promise/sure:stable`
image and set the following environment variables:

| Variable | Value |
| --- | --- |
| `SECRET_KEY_BASE` | a long random hex string (keep it stable across restarts) |
| `DB_HOST` / `DB_PORT` | your PostgreSQL host and port |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | database credentials |
| `REDIS_URL` | `redis://<host>:<port>/1` |
| `SELF_HOSTED` | `true` |

Run the web server and a Sidekiq worker from the same image, both sharing the same
`SECRET_KEY_BASE`. Run `bin/rails db:prepare` before the web server starts so
migrations are applied — for example with a start command like
`sh -c "./bin/rails db:prepare && (bundle exec sidekiq &) && exec ./bin/rails server -b 0.0.0.0"`.

Mount a persistent volume at `/rails/storage`. Sure stores uploaded files (such as
imported statements) there via Active Storage's local disk service by default;
without a persistent volume they are lost when the container is replaced, while the
database still references them.
