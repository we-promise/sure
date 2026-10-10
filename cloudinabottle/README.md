# Sure on Cloud in a Bottle

This directory packages [Sure](https://github.com/we-promise/sure) as a
single [Cloud in a Bottle](https://cloudinabottle.org) app. The manifest is
`cloudinabottle.toml` at the repo root (the only location Cloud in a Bottle
reads); everything else lives here so the stock Docker/Compose self-hosting
path is untouched.

## What's in the box

Cloud in a Bottle runs one container per app, so `Dockerfile` builds an
all-in-one image on top of the official `ghcr.io/we-promise/sure:stable`
release and adds:

| Process | Runs as | Purpose |
|---|---|---|
| PostgreSQL 16 (+ pgvector) | `postgres` | primary database, cluster in the permanent data dir |
| Redis (AOF) | `redis` | Sidekiq queue, loopback-only |
| Rails web (Puma :3000) | `rails` | the app the zone routes to |
| Sidekiq worker | `rails` | background jobs (bank syncs, rules, etc.) |
| one-shot provision step | `postgres` | creates the `sure` role + `sure_production` DB |

`supervisord` is PID 1. The wrappers still call `bin/docker-entrypoint`, so
jemalloc and `db:prepare` behavior matches the stock self-hosted image, and
migrations run automatically on every boot (including upgrades).

## Deploy

From the zone dashboard: **Deploy New App** and give it this repo's URL, or
with the CLI:

```bash
bottle app deploy https://github.com/we-promise/sure --name sure --wait
```

First boot takes a few minutes (cluster init + full migrations). Watch with
`bottle app logs sure --follow` until the health check (`/up`) goes green,
then open `https://sure.<your-zone-domain>/` and create your account.

To update later:

```bash
bottle app reload sure --update --wait
```

## Data, secrets and backups

Everything that matters lives in the app's permanent data directory
(`BOTTLE_APP_DATA_DIR`, mounted under `/data/app_data/sure`):

- `postgres/` - the database cluster (all financial data)
- `redis/` - the queue's AOF
- `storage/` - uploaded files (imports, attachments), symlinked from
  `/rails/storage`
- `secrets.env` - `SECRET_KEY_BASE` and the database password, generated on
  first boot (mode 0600). Never committed, never in the image.

The instance's bundled backup app includes permanent app data, so all of the
above is covered. Two caveats: the database copy is crash-consistent
(PostgreSQL recovers on restore, but for a clean point-in-time dump run
`pg_dump` over `bottle instance ssh`), and restoring is only meaningful with
the matching `secrets.env` - which the same backup includes.

## Configuration

- **OpenAI / AI features**: no env wiring needed - set the key in the app
  under **Settings → Self-Hosting**. This keeps the token out of the repo,
  the image, and the manifest. AI features are off until you add a key.
- **`APP_DOMAIN`** (email links, WebAuthn/passkeys) is derived automatically
  from the app's subdomain and zone domain on every boot, so renames just
  work.
- **Public access**: the manifest deliberately sets no `public_paths` -
  every request passes the zone's owner login first, then Sure's own auth.
  To use the Sure API from the mobile app or to receive bank-sync webhooks,
  add `public_paths = ["/api/", "/webhooks/"]` to `cloudinabottle.toml`.
  Sure's own auth still protects those routes; the tradeoff is that they
  become reachable (and attackable) without the zone session.

## Resources

The manifest requests 2 GB RAM / 1 CPU - the smallest size known to run the
full stack comfortably (512 Mi reliably OOMs generating demo data). Disk
usage is your data plus ~2 GB of image. Raise `memory_mb` if you import
large histories or run many families.

## Limitations (by design, for now)

- **Single container**: no independent scaling of web/worker, and a
  PostgreSQL major upgrade is a manual `pg_dump`/restore exercise.
- **One Sure instance per app**; deploy the app twice under two names if you
  need isolation.
- Built from the `:stable` release image. To package unreleased source,
  build the repo-root `Dockerfile` yourself and pass
  `--build-arg SURE_IMAGE=...` - the manifest build path stays the same.
