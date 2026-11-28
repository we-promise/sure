---
name: sure-self-host
description: >-
  Self-host the Sure personal finance app with Docker Compose: the
  compose.example.yml and .env files, SECRET_KEY_BASE and encryption keys,
  host and origin restrictions, first account and signup mode, the AI
  compose file with Pipelock, and applying config changes. Use when
  installing, upgrading or hardening a Sure instance.
---

# Self-hosting Sure

References: `docs/hosting/docker.md`, `docs/hosting/encryption.md`,
`docs/hosting/ai.md`, `docs/hosting/pipelock.md`.

## Install

```bash
mkdir -p ~/docker-apps/sure && cd ~/docker-apps/sure
curl --fail -sSL -o compose.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.yml
curl --fail -sSL -o .env https://raw.githubusercontent.com/we-promise/sure/main/.env.example
openssl rand -hex 64          # -> SECRET_KEY_BASE
```

In `.env`:

```txt
SECRET_KEY_BASE="<generated>"
POSTGRES_PASSWORD="<choose one>"
```

`SECRET_KEY_BASE` has no default and also seeds the Active Record
encryption keys unless `ACTIVE_RECORD_ENCRYPTION_*` are set. On an
existing install, never change it: encrypted data becomes unreadable.

```bash
docker compose up        # first run, then Ctrl+C
docker compose up -d     # background
docker compose ls
```

Open `http://localhost:3000`, create the first account, then set
**Settings > Self-Hosting > Onboarding** to Invite-only or Closed if
nobody else should sign up.

## Exposing it

| Variable | Effect |
|----------|--------|
| `ALLOWED_HOSTS` | Turns on the Host check (DNS-rebinding protection); list every name you use, including `localhost` or LAN/Tailscale names |
| `APP_DOMAIN` | Your public host; added to the allow-list, fallback for origins |
| `ALLOWED_ORIGINS` | Browser origins allowed cross-origin (include the scheme) |

These, like SMTP settings, only reach the app when `compose.yml` lists
them under the `x-rails-env` anchor; `.env` alone is not enough. Behind a
TLS-terminating proxy prefer `ALLOWED_ORIGINS`.

## Applying changes

Run `docker compose up -d` after editing `compose.yml` or `.env`.
`docker compose restart` keeps the old environment.

## AI features

`compose.example.ai.yml` adds Pipelock (always on, scans inbound MCP and
controls outbound traffic) and optional Ollama + Open WebUI:

```bash
docker compose -f compose.ai.yml up -d
docker compose -f compose.ai.yml --profile local-ai up -d
```

With Pipelock and `ALLOWED_HOSTS` set, add `web` to `ALLOWED_HOSTS` or
MCP calls forwarded with `Host: web:3000` are refused.
