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

References:
[docs/hosting/docker.md](https://github.com/we-promise/sure/blob/main/docs/hosting/docker.md),
[docs/hosting/encryption.md](https://github.com/we-promise/sure/blob/main/docs/hosting/encryption.md),
[docs/hosting/ai.md](https://github.com/we-promise/sure/blob/main/docs/hosting/ai.md),
[docs/hosting/pipelock.md](https://github.com/we-promise/sure/blob/main/docs/hosting/pipelock.md).

## Install

Use a new empty directory (do not overwrite an existing `.env` —
losing `SECRET_KEY_BASE` can make encrypted data unreadable):

```bash
mkdir -p ~/docker-apps/sure && cd ~/docker-apps/sure
# Refuse if this directory already has compose or env files
[ ! -e compose.yml ] && [ ! -e .env ] || { echo "Directory already has Sure files; use a new path or stop."; exit 1; }
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
If you run the AI stack from `compose.ai.yml`, use
`docker compose -f compose.ai.yml up -d` instead — plain
`docker compose up -d` reads `compose.yml` and can drop Pipelock.
When the `local-ai` profile is active, add `--profile local-ai` so
Compose recreates those services (e.g. Open WebUI after a
`WEBUI_AUTH` change). When `external-assistant` is active, add
`--profile external-assistant` so OpenClaw picks up
`EXTERNAL_ASSISTANT_TOKEN` changes with Sure; omit inactive
profiles.
`docker compose restart` keeps the old environment.

## AI features

`compose.example.ai.yml` adds Pipelock (always on). Outbound control
applies only to clients that honor the proxy settings, and the default
setup cannot inspect encrypted HTTPS bodies. Pipelock scans inbound MCP
on port 8889 only; port 3000 reaches `/mcp` directly and bypasses that
scanning. Clients that need Pipelock scanning must connect to port 8889.
Optional Ollama + Open WebUI are also included:

```bash
# Download only missing files; never overwrite. Clean up and stop on failure.
[ -e compose.ai.yml ] || curl --fail -sSL -o compose.ai.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.ai.yml || { rm -f compose.ai.yml; exit 1; }
[ -e pipelock.example.yaml ] || curl --fail -sSL -o pipelock.example.yaml https://raw.githubusercontent.com/we-promise/sure/main/pipelock.example.yaml || { rm -f pipelock.example.yaml; exit 1; }
```

Before `up -d`, carry over customized `x-rails-env` entries from
`compose.yml` into `compose.ai.yml` (`.env` alone is not enough) —
`ALLOWED_HOSTS`, `APP_DOMAIN`, `ALLOWED_ORIGINS`, plus others you set
such as `RAILS_FORCE_SSL` or SMTP. Do not copy `HTTP_PROXY` or
`HTTPS_PROXY`; the AI stack sets those. Keep the AI stack's
`NO_PROXY` list, and append any internal provider hostnames you
need (or allow them in Pipelock `trusted_domains`) — Pipelock
blocks private destinations by default. Do not copy the Ollama
`OPENAI_URI_BASE`, `OPENAI_MODEL` and `OPENAI_ACCESS_TOKEN`
defaults; for another OpenAI-compatible provider, replace those
in `compose.ai.yml` first. Preserve other `OPENAI_*` you set
(e.g. `OPENAI_EXTRA_HEADERS`); add any missing ones under
`x-rails-env` — the example does not forward them. Include `web`
in `ALLOWED_HOSTS` or MCP calls forwarded with `Host: web:3000`
are refused.

`compose.ai.yml` also switches document search: it sets
`VECTOR_STORE_PROVIDER: pgvector` and `EMBEDDING_URI_BASE` to
Ollama. Ollama starts only with the `local-ai` profile; without
it, embeddings have no reachable endpoint and document search
fails. The pgvector store is separate from the previous one, so
previously indexed documents are not available through it. If you
need document search, either keep your current vector-store and
embedding settings in `compose.ai.yml`, or start the `local-ai`
profile and complete the pgvector migration in
[docs/hosting/ai.md](https://github.com/we-promise/sure/blob/main/docs/hosting/ai.md).

```bash
docker compose -f compose.ai.yml up -d
```

The `local-ai` profile publishes Open WebUI on port 8080 with
`WEBUI_AUTH=False`, and Ollama on port 11434 with no authentication.
Restrict or firewall both ports (or leave them unpublished) before
starting on a network-reachable host:

```bash
docker compose -f compose.ai.yml --profile local-ai up -d
```
