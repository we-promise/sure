# Self Hosting Sure with Docker

This guide will help you setup, update, and maintain your self-hosted Sure application with Docker Compose. Docker Compose is the most popular and recommended way to self-host the Sure app.

## Setup Guide

Follow the guide below to get a **new installation** running.

> [!WARNING]
> **Already running Sure?** Do not download over your existing `compose.yml` or
> `.env`, or generate replacement keys using the setup steps below. Preserve your
> configuration and effective keys first; follow
> [Upgrading an existing install](#upgrading-an-install-that-is-already-running-keep-your-secret_key_base)
> and [Encrypting sensitive data](#encrypting-sensitive-data).

### Step 1: Install Docker

Complete the following steps:

1. Install Docker Engine by following [the official guide](https://docs.docker.com/engine/install/)
2. Start the Docker service on your machine
3. Verify that Docker is installed correctly and is running by opening up a terminal and running the following command:

```bash
# If Docker is setup correctly, this command will succeed
docker run hello-world
```

### Step 2: Configure your Docker Compose file and environment

#### Create a directory for your app to run

Open your terminal and choose a new directory that does not already contain a Sure installation or configuration. Below is an example command with a recommended directory:

```bash
# Create a directory on your computer for Docker files (name it whatever you like)
mkdir -p ~/docker-apps/sure

# Once created, navigate your current working directory to the new folder
cd ~/docker-apps/sure
```

#### Copy our sample Docker Compose file

Make sure you are in the directory you just created and run the following command:

```bash
# Download the sample compose.yml file from the GitHub repository
curl --fail --location --silent --show-error --output compose.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.yml
```

This command will do the following:

1. Fetch the sample docker compose file from our public Github repository
2. Creates a file in your current directory called `compose.yml` with the contents of the example file

At this point, you should have `compose.yml` in your directory. It includes an optional `backup` service; see [Backups, upgrades and rollbacks](#backups-upgrades-and-rollbacks).

### Step 3 (required): Configure your environment

`compose.yml` requires a `SECRET_KEY_BASE` you provide yourself — there is no built-in default. This isn't just a Rails formality: `SECRET_KEY_BASE` also seeds the automatic generation of your Active Record encryption keys (used to encrypt provider API tokens/keys and other sensitive data at rest) when neither a complete set of `ACTIVE_RECORD_ENCRYPTION_*` variables nor Rails credentials supply them. A shared or guessable value would mean session cookies can be forged **and** your encryption keys can be computed by anyone. Explicit Active Record keys do not protect sessions or `Setting`-stored values from a public `SECRET_KEY_BASE`. Follow the steps below even for a disposable local test.

> **Upgrading an existing install?** Keep the `SECRET_KEY_BASE` it already runs with; generating a new one makes already-encrypted data unreadable. See [Upgrading an install that is already running](#upgrading-an-install-that-is-already-running-keep-your-secret_key_base).

#### Create your environment file

In order to configure the app, you will need to create a file called `.env`, which is where Docker will read environment variables from.

To do this, you should get our .env.example as a starting point:

```bash
curl --fail --location --silent --show-error --output .env https://raw.githubusercontent.com/we-promise/sure/main/.env.example
```

Optional linked-account balance anchoring is documented separately; see [Linked-account balance anchoring](balance-anchors.md) before enabling `BALANCE_REUSE_EXPLAINED_ANCHOR`.

#### Generate the app secret key

The app requires an environment variable called `SECRET_KEY_BASE` to run.

We will first need to generate this in the terminal. If you have `openssl` installed on your computer, you can generate it with the following command:

```bash
openssl rand -hex 64
```

_Alternatively_, you can generate a key without openssl or any external dependencies by pasting the following bash command in your terminal and running it:

```bash
head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' && echo
```

Once you have generated a key, save it and move on to the next step.

#### Fill in your environment file

Open the file named `.env` that we created in a prior step using your favorite text editor.

Fill in this file with the following variables:

```txt
SECRET_KEY_BASE="replacemewiththegeneratedstringfromthepriorstep"
POSTGRES_PASSWORD="replacemewithyourdesireddatabasepassword"
```

Separate Active Record keys are optional for a new self-hosted instance using derived keys. If you choose your own keys, set them before the first start; see [Encrypting sensitive data](#encrypting-sensitive-data), then finish the remaining configuration before [Step 4](#step-4-run-the-app).

#### Restricting who can reach your instance

These optional variables tighten things once your instance is reachable from
the internet. All are unset by default, and leaving them unset keeps the app
answering to any `Host`. Cross-origin browser requests are refused unless an
origin is listed.

| Variable | Purpose |
|---|---|
| `ALLOWED_ORIGINS` | Comma-separated list of browser origins allowed to call the app cross-origin, including the scheme, for example `https://app.example.com,https://staging.example.com`. Without it the app answers cross-origin requests the way any site does by default: it does not. Native mobile clients are unaffected, since they send no `Origin` header. |
| `APP_DOMAIN` | The single host your instance is served on. Used as the fallback for `ALLOWED_ORIGINS`, and added to the `Host` allow-list once `ALLOWED_HOSTS` is set. On its own it does not turn the `Host` check on. |
| `ALLOWED_HOSTS` | Comma-separated hostnames the app answers to. Setting it turns the `Host` check on, with `APP_DOMAIN` added to the list. One host per entry: a leading dot is refused rather than read as a wildcard, and IPv6 goes in brackets, `[::1]`. |

Prefer `ALLOWED_ORIGINS` when a reverse proxy terminates TLS for you. The
`APP_DOMAIN` fallback has to guess the scheme from `RAILS_FORCE_SSL` and
`RAILS_ASSUME_SSL`, so with both off, a common setting behind Traefik, NGINX or
a Cloudflare Tunnel, it builds an `http://` origin while the browser sends
`https://` and the request is refused.

Setting `ALLOWED_HOSTS` turns on DNS-rebinding protection: any request whose
`Host` header is neither in `ALLOWED_HOSTS` nor `APP_DOMAIN` is refused with a
403. List every name you reach the app by, such as a LAN address, a Tailscale
name or `localhost`, or those requests stop working. The `/up` health endpoint
is always exempt, so container probes keep passing. With
`compose.example.ai.yml`, Pipelock forwards MCP requests to the app with the
`Host` header `web:3000`, so add `web` to `ALLOWED_HOSTS` or every MCP call
through it is refused.

Without `ALLOWED_HOSTS`, the app answers to any `Host`, whether or not
`APP_DOMAIN` is set, and logs a `[SECURITY]` warning when the web server
starts.

Like the SMTP settings below, these reach the app only when `compose.yml` lists
them in the `x-rails-env` anchor, for example `ALLOWED_HOSTS: ${ALLOWED_HOSTS}`.
Setting them in `.env` alone does nothing; see **Passing the settings to the
containers** under [Sending email (SMTP)](#sending-email-smtp).

#### Using HTTPS

Assuming you want to access your instance from the internet, you should have secured your URL address with an SSL certificate.  
The Docker instance runs in plain HTTP and you need to tell it that you are redirecting your HTTPS stream to the HTTP one.  
To do this, edit the `compose.yml` file and find the line stating:  

```yaml
RAILS_ASSUME_SSL: "false"
```

and change it to `true`

```yaml
RAILS_ASSUME_SSL: "true"
```

#### Sending email (SMTP)

Sure sends email through an SMTP server that you provide. Email is sent by the background worker (the `worker` service), not by `web`, so the worker must have these settings.

On a self-hosted instance, Sure sends these emails:

- Password reset links, when password sign-in is enabled.
- A confirmation link when a user changes their email address, but only when **Require email confirmation** is on under Settings > Self-Hosting. When it is off, the new address is saved straight away and nothing is sent.
- Rule notifications, from rules with a "Send email notification" action.
- The follow-up email after a PDF import is processed.
- A daily summary to every super admin after the demo family is refreshed, but only when **Enable daily demo family refresh** is on under Settings > Self-Hosting and a demo family has been selected for it. It is off by default.

Invitations are never emailed on a self-hosted instance, even with SMTP set up. After you add a member, copy the invitation link from Settings > Profile Info and send it to them yourself.

| Variable | What it does | Default when not set |
|----------|--------------|----------------------|
| `SMTP_ADDRESS` | Host name of your SMTP server, for example `smtp.example.com`. | None. Required to send email. |
| `SMTP_PORT` | Port of your SMTP server. | `25` |
| `SMTP_USERNAME` | User name for logging in to the SMTP server. | None (no login) |
| `SMTP_PASSWORD` | Password for logging in to the SMTP server. | None |
| `SMTP_TLS_ENABLED` | `true` uses TLS from the start of the connection (SMTPS, usually port 465). Any other value connects in plain text and switches to TLS with STARTTLS when the server offers it (usually port 587). | Off |
| `SMTP_TLS_SKIP_VERIFY` | `true` turns off verification of the SMTP server's certificate. | Off (the certificate is verified) |
| `SSL_CA_FILE` | Path inside the container to a CA certificate (PEM) for verifying a server with a self-signed or internal certificate. The file must be mounted into the containers; see **Using a custom CA certificate** below. | None |
| `EMAIL_SENDER` | Address that emails are sent from, for example `sure@example.com`. | `sender@sure.local` |
| `APP_DOMAIN` | Host name your instance is reached at, for example `sure.example.com`. Used to build links in emails. It does not restrict which `Host` the app answers to unless `ALLOWED_HOSTS` is also set; see [Restricting who can reach your instance](#restricting-who-can-reach-your-instance). | None |

A few things to watch:

- `SMTP_TLS_ENABLED` and `SMTP_TLS_SKIP_VERIFY` are on only when the value is exactly the string `true`. `True`, `1` or `yes` all count as off.
- If `EMAIL_SENDER` is not set, email goes out from `sender@sure.local`, which many mail servers reject. Set it to an address your SMTP server is allowed to send from.

**Passing the settings to the containers**

Docker Compose uses `.env` to fill in the `${...}` values in `compose.yml`. It does not pass `.env` to the containers as a whole. A variable set only in `.env` does not reach the app unless `compose.yml` lists it.

Both `web` and `worker` merge the shared `x-rails-env` anchor, so add the keys there once and both services get them. If you run the AI setup from `compose.ai.yml` (see [Using the AI compose file](#using-the-ai-compose-file) below), that file has its own `x-rails-env` anchor with no SMTP keys, so add the same keys there instead:

```yaml
x-rails-env: &rails_env
  # ...existing keys...
  APP_DOMAIN: ${APP_DOMAIN}
  EMAIL_SENDER: ${EMAIL_SENDER}
  SMTP_ADDRESS: ${SMTP_ADDRESS}
  SMTP_PORT: ${SMTP_PORT:-465}
  SMTP_USERNAME: ${SMTP_USERNAME}
  SMTP_PASSWORD: ${SMTP_PASSWORD}
  SMTP_TLS_ENABLED: ${SMTP_TLS_ENABLED:-true}
+  # Only when an otherwise valid certificate uses an untrusted CA:
  # SMTP_TLS_SKIP_VERIFY: ${SMTP_TLS_SKIP_VERIFY:-false}
```

Any other variable from the table reaches the app only if you add it to the anchor the same way. `SMTP_TLS_SKIP_VERIFY` is shown commented out because turning off certificate checks is a last resort; prefer `SSL_CA_FILE` (see **Using a custom CA certificate** below).

The table above lists the app's own defaults. This snippet sets different ones for Compose: port 465 with TLS from the start of the connection (SMTPS), the same values `.env.example` ships with. For a server that uses STARTTLS on port 587, set `SMTP_PORT` and `SMTP_TLS_ENABLED` in `.env` as shown below.

Then set the values in `.env`:

```txt
APP_DOMAIN="sure.example.com"
EMAIL_SENDER="sure@example.com"
SMTP_ADDRESS="smtp.example.com"
SMTP_USERNAME="replacemewithyoursmtpusername"
SMTP_PASSWORD="replacemewithyoursmtppassword"
# For STARTTLS on port 587 instead of SMTPS on 465:
# SMTP_PORT="587"
# SMTP_TLS_ENABLED="false"
```

+Set each key you list in the anchor that has no default in the plain `${VAR}` form. Docker Compose passes such a key that has no value in `.env` as an empty value, not as unset. An empty `EMAIL_SENDER` replaces the `sender@sure.local` fallback with an empty address, and an empty `SMTP_USERNAME` still makes the app try to log in. If your server needs no login, leave the `SMTP_USERNAME` and `SMTP_PASSWORD` lines out of the anchor. Keys written as `${VAR:-default}`, such as `SMTP_PORT` and `SMTP_TLS_ENABLED` above, are different: Compose uses the default when the `.env` value is unset or empty.

**Using a custom CA certificate**

If your SMTP server's certificate is signed by an internal CA or is self-signed, mount the CA certificate into the containers and point `SSL_CA_FILE` at it. Add `SSL_CA_FILE` to the anchor, and the volume to both `web` and `worker`, since both merge the anchor:

```yaml
x-rails-env: &rails_env
  # ...existing keys...
  SSL_CA_FILE: /certs/my-ca.crt

services:
  web:
    volumes:
      - app-storage:/rails/storage
      - ./my-ca.crt:/certs/my-ca.crt:ro
  worker:
    volumes:
      - app-storage:/rails/storage
      - ./my-ca.crt:/certs/my-ca.crt:ro
```

The worker is the service that sends email, so it is the one that must have the file. The same setting is also used for other outbound HTTPS connections; see [Self-signed certificate support](oidc.md#self-signed-certificate-support) for the certificate format and troubleshooting.

Pull request [#2811](https://github.com/we-promise/sure/pull/2811), which is still open, would pass `.env` to both services directly. If it is merged, listing the keys in the anchor is no longer needed.

**Applying changes**

Run `docker compose up -d` after changing `compose.yml` or `.env`. It recreates the containers whose settings changed. `docker compose restart` keeps the old environment, so new settings do not take effect.

During a restore or encryption-key change, use the
[recovery startup sequence](#verify-recovery-before-resuming-services) instead;
do not use this all-services command before recovery verification.

To check what the worker sees, without printing the password:

```bash
docker compose exec worker bin/rails runner 'p ActionMailer::Base.smtp_settings.slice(:address, :port, :user_name, :tls)'
docker compose exec worker printenv EMAIL_SENDER APP_DOMAIN
```

#### WebAuthn MFA (passkeys and security keys)

If you enable passkeys, Touch ID, Windows Hello, or hardware security keys as MFA credentials, pin the WebAuthn relying party settings in your `.env` file:

```txt
WEBAUTHN_RP_ID="example.com"
WEBAUTHN_ALLOWED_ORIGINS="https://sure.example.com"
```

`WEBAUTHN_RP_ID` should usually be your registrable domain, not a full URL. See [WebAuthn MFA Configuration](webauthn.md) before changing hostnames or reverse proxy settings for an instance with registered passkeys.

#### Privacy policy and terms links (optional)

To link your own privacy policy and terms of service from the login, signup and onboarding pages, set their full URLs in your `.env` file:

```txt
LEGAL_PRIVACY_URL="https://example.com/privacy"
LEGAL_TERMS_URL="https://example.com/terms"
```

`compose.example.yml` passes both to the app through its `x-rails-env` anchor. If your `compose.yml` was copied before they were added, add them there yourself:

```yaml
x-rails-env: &rails_env
  # ...existing keys...
  LEGAL_PRIVACY_URL: ${LEGAL_PRIVACY_URL:-}
  LEGAL_TERMS_URL: ${LEGAL_TERMS_URL:-}
```

`/privacy` and `/terms` then redirect to these URLs. Each footer link appears only when its URL is set, so an instance without them shows neither link. Restart the app after changing them; the redirects are read at boot.

#### Binding to IPv6 (optional)

By default Sure listens on `0.0.0.0:3000` (IPv4 wildcard) inside the container and Docker publishes the port on the host's IPv4 interface only. If you want the app reachable over IPv6 as well, two things need to change:

1. **Tell the app to bind to `[::]`** by setting `BINDING=::` in the container environment. `BINDING` is Rails' native env var for the server bind address. On any kernel with `net.ipv6.bindv6only=0` (the default on Linux and macOS) a single `[::]` bind is **dual-stack**: it accepts both IPv6 and IPv4 clients from the same socket. You do not need two binds and you do not need two ports.
2. **Tell Docker to publish the host port on IPv6** by adding a bracketed-host `ports:` entry alongside the existing IPv4 one.

In `compose.yml`:

```yaml
services:
  web:
    ports:
      - ${PORT:-3000}:3000
      - "[::]:${PORT:-3000}:3000"
    environment:
      <<: *rails_env
      BINDING: "::"
```

With both changes in place, `http://127.0.0.1:3000/` and `http://[::1]:3000/` both work against the same container.

**Note:** Docker's default userland proxy already bridges host-side IPv6 publishes to the container's internal IPv4 address, so in many setups just adding the `[::]:` port entry is enough. Setting `BINDING=::` inside the container only becomes load-bearing when the Docker daemon has `"ipv6": true` + `"ip6tables": true` configured (uncommon for self-hosters) and forwards raw IPv6 packets into the container via netfilter instead of the proxy. Setting both is harmless and future-proof.

If you are running behind a reverse proxy that terminates TLS, nothing else changes — `proxy_pass http://[::1]:3000` and `proxy_pass http://127.0.0.1:3000` both work because the `[::]` bind is dual-stack.

#### Local development bind

For `bin/dev` on your own machine, the server now defaults to Rails' native `localhost` bind (`127.0.0.1` + `[::1]`) — only reachable from the same machine. If you need external access (phone on the same WiFi, devcontainer port forwarding, LAN testing), set the Rails-native env var:

```bash
BINDING=0.0.0.0 bin/dev   # reachable from LAN
BINDING=::       bin/dev  # IPv6 dual-stack
```

The bundled devcontainer at `.devcontainer/docker-compose.yml` already pins `BINDING: "0.0.0.0"` so Docker port forwarding reaches the app — no manual override needed when using the devcontainer.

### Step 4: Run the app

You are now ready to run the app. Start with the following command to make sure everything is working:

```bash
docker compose up
```

This will pull our official Docker image and start the app. You will see logs in your terminal.

Open your browser, and navigate to `http://localhost:3000`.

If everything is working, you will see the Sure login screen.

### Step 5: Create your account

The first time you run the app, you will need to register a new account by hitting "create your account" on the login page.

1. Enter your email
2. Enter a password

### Step 5a: Restrict future signups (optional)

After creating your initial admin account, you can control how other people join your self-hosted instance from **Settings > Self-Hosting > Onboarding**.

- **Open**: Anyone can create an account from the registration page.
- **Invite-only**: New account creation stays enabled. Signups require a valid invite code unless you configure a default family for invite-only onboarding.
- **Closed**: The registration page is disabled for new signups.

If you do not want additional self-service registrations, switch the instance to **Closed** after the initial setup.

### Step 6: Run the app in the background

Most self-hosting users will want the Sure app to run in the background on their computer so they can access it at all times. To do this, hit `Ctrl+C` to stop the running process, and then run the following command:

```bash
docker compose up -d
```

The `-d` flag will run Docker Compose in "detached" mode. To verify it is running, you can run the following command:

```
docker compose ls
```

### Step 7: Enjoy!

Your app is now set up. You can visit it at `http://localhost:3000` in your browser.

If you find bugs or have a feature request, be sure to read through our [contributing guide here](https://github.com/we-promise/sure/wiki/How-to-Contribute-Effectively-to-Sure).

## AI features, external assistant, and Pipelock

Sure ships with a separate compose file for AI-related features: `compose.example.ai.yml`. It adds:

- **Pipelock** (always on): AI agent security proxy for outbound tunnel controls and inbound MCP scanning
- **Ollama + Open WebUI** (optional `--profile local-ai`): local LLM inference

### Using the AI compose file

```bash
# Download both compose files
curl --fail --location --silent --show-error --output compose.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.yml
curl --fail --location --silent --show-error --output compose.ai.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.ai.yml
curl --fail --location --silent --show-error --output pipelock.example.yaml https://raw.githubusercontent.com/we-promise/sure/main/pipelock.example.yaml

# Run with Pipelock (no local LLM)
docker compose -f compose.ai.yml up -d

# Run with Pipelock + Ollama
docker compose -f compose.ai.yml --profile local-ai up -d
```

### Setting up the external AI assistant

The external assistant delegates chat to a remote AI agent instead of calling LLMs directly. The agent calls back to Sure's `/mcp` endpoint for financial data (accounts, transactions, balance sheet).

1. Set the MCP endpoint credentials in your `.env`:
   ```bash
   MCP_API_TOKEN=generate-a-random-token-here
   MCP_USER_EMAIL=your@email.com   # must match an existing Sure user
   ```

2. Set the external assistant connection:
   ```bash
   EXTERNAL_ASSISTANT_URL=https://your-agent/v1/chat/completions
   EXTERNAL_ASSISTANT_TOKEN=your-agent-api-token
   ```

3. Choose how to activate:
   - **Per-family (UI):** Go to Settings > Self-Hosting > AI Assistant, select "External"
   - **Global (env):** Set `ASSISTANT_TYPE=external` to force all families to use external

To use the bundled OpenClaw service instead of a separately hosted agent, start the `external-assistant` profile. This profile starts OpenClaw without the local Ollama or Open WebUI services:

```bash
docker compose -f compose.ai.yml --profile external-assistant up -d
```

See [docs/hosting/ai.md](ai.md) for full configuration details including agent ID, session keys, and email allowlisting.

### Pipelock security proxy

Pipelock sits between Sure and external services. The default Compose file provides:

- MCP request and response scanning for DLP, prompt injection, and tool poisoning
- HTTPS tunnel controls for destination, SSRF, rate, budget, CONNECT headers, and optional signed receipts

The example doesn't enable TLS interception, so Pipelock can't read encrypted HTTPS request or response bodies. Docker Compose also doesn't prevent a client from bypassing the proxy.

When using `compose.example.ai.yml`, Pipelock is always running. External AI agents should connect to port 8889 (MCP reverse proxy) instead of directly to Sure's `/mcp` on port 3000.

For full Pipelock configuration, see [docs/hosting/pipelock.md](pipelock.md).

## Running Sure on small (512 MB) hosts

Sure runs comfortably on hosts or containers limited to 512 MB of RAM, which makes it a good fit for the smallest tiers on platforms like Render, Fly.io, or a cheap VPS. This section summarizes what fits, what does not, and how to handle the jobs that do not.

### What fits in 512 MB

Measured on a production deploy of the official image with the tuning below:

- Boot, first-run onboarding, and everyday use (dashboard, transactions, budgets, reports)
- Small bank syncs and CSV imports
- Scheduled (cron) jobs such as exchange-rate refreshes

Steady-state memory sits around **352 MB**, leaving comfortable headroom under a 512 MB limit.

### What does not fit in 512 MB

- **The demo-data generator** ("Load sample/demo data"): this is the one operation that deterministically exceeds 512 MB. On a 512 MB container it climbs to the limit and gets OOM-killed mid-generation (observed flat at ~680 MB on a 2 GB container, ~5 minutes). Because the generation runs in the worker, the symptom is a sample-data load that never completes, sometimes with all rows silently rolled back.
- **Very large first-time imports or historical syncs** (tens of thousands of rows) can also exceed the limit. Import your history in smaller batches, or temporarily raise the memory limit for the initial import and lower it afterwards.
- **AI features**: the assistant flavors need extra headroom. If you enable AI, run at least 1 GB.

### Tuning already in the image

The official image ships with the memory tuning that makes 512 MB viable, so no extra configuration is needed:

- **jemalloc** preloaded to reduce memory fragmentation
- **YJIT** (Ruby's JIT) enabled
- **Puma constrained to 1 worker x 3 threads** (`WEB_CONCURRENCY=1`, `RAILS_MAX_THREADS=3`)

If you run your own process supervisor instead of the official image, set those same values.

The worker splits `RAILS_MAX_THREADS` between its default and AI lanes (`RAILS_AI_MAX_THREADS`, default `1`), so keep the worker's value at `2` or more; see [Where AI jobs run](ai.md#where-ai-jobs-run-sidekiq-lanes).

### Operational note for the sample-data button

If you want to load sample/demo data on a small host:

1. Raise the **worker's** memory limit (the generator runs in the worker process, not the web process). On Render, bump the worker service's plan; on Docker Compose, raise the worker container's memory limit.
2. Apply the change with a **fresh deploy/restart of the worker**. Note for Render specifically: plan changes only take effect on the next deploy - they do **not** apply on a plain restart.
3. Load the sample data, then optionally drop the worker back to the small plan with another fresh deploy.

## Daily market data import

Sure imports security prices once a day, Monday to Friday. By default the import runs at 22:00 UTC, about an hour after the New York close. To change the time or turn the import off, open **Settings > Self-Hosting** and use the market data import options under the sync settings. The time you save there is interpreted in your browser's timezone.

You can also set the defaults in your `.env` file. A value saved on the settings page always takes precedence over these variables:

```txt
MARKET_DATA_SYNC_ENABLED=1        # 1 = on, anything else = off
MARKET_DATA_SYNC_TIME=22:00       # HH:MM, 24-hour clock
MARKET_DATA_SYNC_TIMEZONE=UTC     # IANA name such as Europe/Berlin; unknown names fall back to UTC
```

**Upgrading from an earlier version:** the import used to be a fixed entry in `config/schedule.yml`. It is now created by the worker when it starts, from the settings above. Without any change on your side it keeps running at 22:00 UTC, Monday to Friday. If prices stop updating after an upgrade, open `/sidekiq` (see [Inspecting background jobs](#inspecting-background-jobs-sidekiq)), check that the **Cron** tab lists `import_market_data`, and look for `[MarketDataScheduler]` lines in the worker log (`docker compose logs worker`). Saving the import time once on the settings page recreates the job.

### Hosts that sleep (laptops, NAS)

Scheduled jobs such as the daily account sync and the market data import only run if the worker is awake within 10 minutes of their scheduled time. A run missed by more than that is skipped until the next day. If your host sleeps overnight, either schedule the jobs for a time it is awake, or let missed runs catch up by raising the grace period in your `.env` file:

```txt
SIDEKIQ_CRON_GRACE_PERIOD_SECONDS=86400   # default 600 (10 minutes)
```

When the worker wakes, each job then runs once for its most recent missed time, but only if that time is within the grace period; otherwise it waits for its next scheduled time (older missed runs are not replayed). For example, a Friday 22:00 import missed until Monday morning needs `259200` (3 days) to catch up; with `86400` it waits until Monday 22:00.

The value only reaches the worker if your compose file passes it: the current `compose.example.yml` and `compose.example.ai.yml` forward it in the `x-rails-env` block. If your `compose.yml` was copied from an older example, add `SIDEKIQ_CRON_GRACE_PERIOD_SECONDS: ${SIDEKIQ_CRON_GRACE_PERIOD_SECONDS:-}` under `x-rails-env`. After changing it, run `docker compose up -d worker` (`docker compose -f compose.ai.yml up -d worker` for the AI compose file) to recreate the worker; `docker compose restart` keeps the old value.

## How to update your app

The mechanism that updates your self-hosted Sure app is the GHCR (Github Container Registry) Docker image that you see in the `compose.yml` file:

```yml
image: ghcr.io/we-promise/sure:${SURE_IMAGE_TAG:-stable}
```

We recommend using one of the following images, but you can pin your app to whatever version you'd like (see [packages](https://github.com/we-promise/sure/pkgs/container/sure)):

- `ghcr.io/we-promise/sure:latest` (latest `alpha`)
- `ghcr.io/we-promise/sure:stable` (latest release)

Release candidates require an explicit version tag such as `2026.11.30-rc.1`;
they do not update either `latest` or `stable`.

By default, your app _will NOT_ automatically update. Take a backup first (see below), then run:

```bash
cd ~/docker-apps/sure # Navigate to whatever directory you configured the app in
docker compose run --rm backup create # Back up the current version (optional, recommended)
docker compose pull web worker # Pull the newest image for your tag
docker compose up -d # Restart on the new version; database migrations run automatically
```

### Upgrading an install that is already running: keep your `SECRET_KEY_BASE`

Older example compose files shipped a built-in `SECRET_KEY_BASE` default. Current ones don't, so after refreshing `compose.yml` from the example, `docker compose up` stops with "Set SECRET_KEY_BASE in your .env file". **Do not generate a new value for an existing install.** Put the value your install already runs with into `.env` first (if you never set one, it is the `SECRET_KEY_BASE` default in your previous `compose.yml`).

Why: when neither the three `ACTIVE_RECORD_ENCRYPTION_*` variables nor Rails credentials supply the Active Record keys, those keys are derived from `SECRET_KEY_BASE`. Changing it makes everything already encrypted under the old keys (provider tokens, API keys in settings, user emails and other encrypted fields) impossible to decrypt, which breaks logins and syncs. It also signs everyone out.

If the value you have been running with is a known public default or placeholder, the app logs a `[SECURITY]` warning at boot. To recover the effective values from the original configuration or container, see [Find the values in use](encryption.md#before-you-start-find-the-values-in-use).

Use an image containing these rotation tasks, with its database migrations already applied; do not combine
the rotation with a version update. This includes the required [Plaid instance
credentials migration](encryption.md#upgrading-plaid-instance-credentials), which
must run with the existing `SECRET_KEY_BASE` before any secret rotation. Follow the command and key-preservation
precautions in [Encrypting sensitive data](#encrypting-sensitive-data).

> [!WARNING]
> Before stopping `web` or changing `SECRET_KEY_BASE`, record the removed SSO
> identities on the instance users page and review
> [What a new `SECRET_KEY_BASE` invalidates](encryption.md#what-a-new-secret_key_base-invalidates).
> Legacy digest-only blocks without an encrypted identity or a preserved digest
> key can stop matching after the secret changes. Keep affected users denied at
> the identity provider, or restrict SSO access during recovery, until their
> blocks have been verified or re-established. If the secret already changed,
> apply that restriction before allowing SSO access again. A successful backfill
> alone does not prove that these legacy blocks still work.

Choose a supported [backup method](#backup-and-restore-prerequisites) first. Stop
all writers before taking a named backup, and keep them stopped until the
rotation is verified:

```bash
docker compose stop web worker
docker compose run --rm --no-deps backup create
```

Confirm the backup succeeded and retain its folder name, original configuration,
and any external keys. Keep the database and Redis running. If the current
`backup` service is missing or is the v0.7.5 database-only service, use the
[standalone backup method or upgrade guidance](#backup-and-restore-prerequisites)
before continuing; a database-only dump does not include configuration or uploads.

Choose the path based on the keys that actually encrypted the data:

- **Keys from environment variables or Rails credentials:** if the containers receive
  all three `ACTIVE_RECORD_ENCRYPTION_*` values, or Rails credentials supply the
  keys, keep those effective keys unchanged. Complete environment keys take
  precedence over credentials. Preserve the credentials file and its decryption
  key too. Skip steps 1 and 2 below and proceed to the settings rotation: changing
  `SECRET_KEY_BASE` does not change these independently configured Active Record
  keys. To rotate them as well, follow [Encryption key rotation](encryption.md)
  with the correct previous keys.
- **Keys derived from `SECRET_KEY_BASE`:** follow steps 1 and 2 below before
  changing that secret. Values present only in `.env` may never have reached older
  Compose containers; check [Generate the keys](#generate-the-keys) before assuming
  they were active.

If the configured keys no longer decrypt existing data, or rows use multiple key
sets, stop and establish the required current and previous keys using
[Encryption key rotation](encryption.md). Do not select a path from the current
`.env` contents alone or discard either key set.

1. Generate new keys with `docker compose run --rm --no-deps web bin/rails db:encryption:init` and put the three values into `.env` as `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` and `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`. For an older Compose file, follow the [key-forwarding instructions](#generate-the-keys) so both `web` and `worker` receive them. Keep `SECRET_KEY_BASE` unchanged for now.
2. Stop the app and re-encrypt everything under the new keys. `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE` holds the `SECRET_KEY_BASE` your data was encrypted with; it makes the keys derived from it a `previous` scheme ([key rotation](https://guides.rubyonrails.org/active_record_encryption.html#key-rotation)), so existing data still decrypts:

```bash
docker compose stop web worker
read -rs ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE && export ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE   # paste the SECRET_KEY_BASE the data was encrypted with
docker compose run --rm --no-deps -e ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE web bin/rails "security:backfill_encryption[100,1]"  # dry run
```

Continue only if the dry run lists every table with `"failed_count":0`. Then write the changes:

```bash
docker compose run --rm --no-deps -e ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE web bin/rails "security:backfill_encryption[100,0]"  # writes
```

Continue only if the JSON report on the last line of the write shows `"ok":true`
and `"failed_count":0`. Otherwise keep writers stopped, fix the listed failures
and repeat with the same current and previous keys, or follow
[Restoring after an interrupted rotation](#restoring-after-an-interrupted-rotation)
with the named backup. Retain the previous value for retries until that check
succeeds. Then remove it from the recovery shell:

```bash
unset ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE
```

Keep writers stopped for the `SECRET_KEY_BASE` change and settings rotation below.

Pass the variable only to these commands, never put it into `.env` or `compose.yml`: while it is set, Rails writes deterministically encrypted values (emails, tokens, API keys) with the old key. Only after that is it safe to change `SECRET_KEY_BASE`. Generating a fresh value right away is only safe for a new install.

If you already changed `SECRET_KEY_BASE` and logins or syncs broke, keep writers
stopped and preserve both values. If the Active Record keys were derived, supply
the original secret as `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE` during
the conversion above. If they came from environment variables or Rails credentials,
keep those keys unchanged and recover the settings below. Do not start the web
service for manual settings recovery until Active Record data can be decrypted.

#### Rotate settings after changing `SECRET_KEY_BASE`

Settings use separate encryption: API keys and tokens saved on the self-hosting
settings page are encrypted with a key derived from `SECRET_KEY_BASE`, not the
Active Record keys. An Active Record `previous` scheme does not cover them. If a
stored setting cannot be decrypted, its getter returns the stored value unchanged;
for ciphertext, that means the provider receives an unusable key.

Before changing the secret, confirm that the SSO restrictions and records above
are in place. The change also invalidates sessions, previously issued reset and
confirmation links, calendar subscription links, and in-progress connection flows;
see [What a new `SECRET_KEY_BASE` invalidates](encryption.md#what-a-new-secret_key_base-invalidates).
After completing any required Active Record conversion above, set a new, unique
`SECRET_KEY_BASE` in `.env`. If you already changed it, retain that new value rather
than generating another one. Keep the current secret stable throughout settings
recovery. With writers still stopped, preview the settings conversion using the
old secret only for this one-off command:

```bash
read -rs OLD_SECRET_KEY_BASE && export OLD_SECRET_KEY_BASE   # paste the previous value; keeps it out of your shell history
docker compose run --rm --no-deps -e OLD_SECRET_KEY_BASE web bin/rails "security:rotate_setting_secrets[1]"
```

Inspect the report before writing:

- **`"ok":true` and `"dry_run":true`:** `would_reencrypt` entries can be converted
  with the write command below; `current` entries already use the current secret.
  Any `not_decryptable` entries still need manual recovery, even when `ok` is true.
- **`old_secret_key_base_did_not_match`:** first verify the supplied old secret.
  If it is wrong, correct it and repeat the preview. If it is correct, the remaining
  settings may be plaintext or encrypted with another secret; repeatedly changing
  the supplied secret will not fix them. No settings were converted by the preview.
  Skip the write pass and use [Manual settings recovery](#manual-settings-recovery).
- **Other errors:** keep writers stopped and resolve the reported cause before
  proceeding. For example, `old_secret_key_base_missing` requires the old value,
  and `secret_key_base_unchanged` means the current and old values are still equal.

After a successful preview, convert the settings that the old secret decrypts:

```bash
docker compose run --rm --no-deps -e OLD_SECRET_KEY_BASE web bin/rails "security:rotate_setting_secrets[0]"
```

A successful write report shows `"dry_run":false`; converted entries read `reencrypted`.
Inspect both `ok` and `not_decryptable`. If any settings remain undecryptable, follow
the manual path below before starting workers. The same recovery path applies if a
repeat command reports `old_secret_key_base_did_not_match` after decryptable settings
were already converted. For other failures, keep writers stopped and investigate;
preserve the current secret, original secret, backup, and effective Active Record
keys. Retain `OLD_SECRET_KEY_BASE` in this recovery shell for retries and the
final verification required by both recovery paths; do not put it in `.env` or
the service configuration.

**Choose the startup path before starting services:** if the Active Record
conversion has succeeded (or its independent keys were preserved), and the settings
write reports `"ok":true` with an empty `not_decryptable` list, keep `web` and
workers stopped and complete
[Final settings verification](#final-settings-verification). A successful write
does not replace that final dry run. If settings need re-entry, use the manual
path below first, then complete the same final verification. Do not unset
`OLD_SECRET_KEY_BASE` or start all services before verification succeeds.

#### Manual settings recovery

Use this path only after the Active Record data is readable with the current keys
and any required Active Record conversion succeeded. It handles settings recovery,
not unreadable user records, lost Active Record keys, or a failed backfill.

Keep `worker` and other writers stopped. Before starting `web`, apply the
administrator-only access restrictions in
[Verify recovery before resuming services](#verify-recovery-before-resuming-services)
and avoid normal app use until the settings are verified. Keep the database and
Redis running. Start only `web`, without starting dependencies:

```bash
docker compose up -d --no-deps web
```

Sign in as an administrator with access to the self-hosting settings. Re-enter each
setting listed in `not_decryptable` using its original plaintext API key or token,
or clear it if the integration is no longer used. Obtain replacement credentials
from the provider if the original value is unavailable; do not paste stored
ciphertext back into the form. Save through the settings UI so the values are
encrypted with the current `SECRET_KEY_BASE`.

After saving or clearing the affected settings, keep `web` restricted and workers
stopped and complete [Final settings verification](#final-settings-verification).
Retain `OLD_SECRET_KEY_BASE` until that verification succeeds.

#### Final settings verification

Both automatic settings conversion and manual settings recovery must pass this
check before clearing the old secret or proceeding to service verification.
Keep workers and other writers stopped; only the administrator-only `web` session
needed for manual recovery may be running. Keep the current `SECRET_KEY_BASE`
unchanged. Use the same `OLD_SECRET_KEY_BASE` retained for recovery. If resuming
in a new shell, repeat the hidden-input `read`/`export` command above with the
original secret first.

Run the final dry run after the write pass or manual re-entry:

```bash
docker compose run --rm --no-deps -e OLD_SECRET_KEY_BASE web bin/rails "security:rotate_setting_secrets[1]"
```

Require a successful command exit and a JSON report with `"ok":true`, `"dry_run":true`, an empty
`not_decryptable` list, and only `current` or `not_stored` entries in `results`.
`"ok":true` alone is insufficient: a dry run can still report `would_reencrypt`
or unresolved settings.

- If any `would_reencrypt` entries remain, stop the recovery `web` session if it
  is running, return to the settings conversion with the same current and old
  secrets, and repeat this final dry run afterwards.
- If settings remain `not_decryptable`, including when the task reports
  `old_secret_key_base_did_not_match`, verify the old value first. If it was wrong,
  correct it and repeat this check. Use
  [Manual settings recovery](#manual-settings-recovery) for settings it cannot
  decrypt, then return here for the same final check.
- For a failed command or any other unresolved result, keep workers stopped and
  investigate. Retain the old secret for retries and do not change the current
  secret again to bypass the failure.

Only after all of the final dry-run requirements are met, unset the temporary
variable:

```bash
unset OLD_SECRET_KEY_BASE
```

Keep workers stopped and any running recovery `web` session restricted, then complete
[Verify recovery before resuming services](#verify-recovery-before-resuming-services).
If recovery cannot be completed, keep writers stopped and use
[Restoring after an interrupted rotation](#restoring-after-an-interrupted-rotation).

#### Verify recovery before resuming services

Use this sequence after a restore, encryption conversion, key switch or settings
recovery. Do not run an all-services `docker compose up -d` or a script's printed
startup chain to resume a recovering instance.

1. Keep `worker` and all other writers stopped. Before starting `web`, complete
   any database and local/external-upload restore. Confirm the image,
   configuration and effective keys match the data now in the target. After a
   successful conversion, retain the converted keys; do not restore the
   pre-conversion configuration onto converted data. Require the successful
   conversion reports specified by the procedure you followed. If settings still need re-entry, use
   [Manual settings recovery](#manual-settings-recovery) under the restrictions
   below, then return here after its final verification. A readable rollback with
   unchanged secrets does not need a settings-secret rotation.
2. **Apply access restrictions before starting `web`.** Allow only the recovery
   administrator through the reverse proxy/firewall or a private tunnel, and
   block other routes to the published Docker port, including IPv6 if enabled.
   `ALLOWED_HOSTS` and CORS settings are not administrator authentication. Keep
   affected SSO identities denied at the identity provider until their blocks
   are verified or re-established. Confirm these restrictions cover the recovered
   target, not just the original instance.
3. Keep the database and Redis running, and start only the web service. The
   `--no-deps` option prevents custom Compose dependencies from starting workers:

   ```bash
   docker compose up -d --no-deps web
   ```

4. With normal access still restricted, check sign-in, configured MFA, provider
   connections and the recorded SSO blocks. Confirm the app can read the restored
   data without decryption errors. If a check fails, keep workers stopped and
   access restricted; stop `web` before retrying a conversion or restore. Do not
   change secrets again to bypass an error.
5. Only after those checks succeed, resume workers and any other writers you
   stopped, then restore normal access. For a separate restored copy, leave its
   worker stopped while the original instance can still run workers or scheduled
   jobs. Before promoting the copy to the active instance, stop the original
   `web`, workers, scheduled jobs and any other writers. For the instance you
   have verified and chosen to resume:

   ```bash
   docker compose up -d --no-deps worker
   ```

Do not remove identity-provider restrictions for any SSO block that remains
unverified. If verification cannot be completed, keep the recovery restrictions
and writers stopped rather than continuing with startup.

#### Restoring after an interrupted rotation

Stop `web`, `worker`, and every other writer before restoring, including any
web-only recovery session. Choose the backup by its recorded folder name, not
`latest`: restoring replaces the database and local uploaded files, discarding
changes made since that backup. External uploads need the separate provider
restore described in the [backup prerequisites](#backup-and-restore-prerequisites).
Use the [supported restore method](#backup-and-restore-prerequisites)
and restore the matching image and configuration, including credentials files and
keys stored outside `.env`. An in-place restore does not replace your live
configuration automatically.

Choose keys for the data **inside that backup**, not just for the current `.env`:

| Backup state | Keys and next step |
| --- | --- |
| Taken while data was readable, before any key change | Restore its original effective Active Record keys and `SECRET_KEY_BASE`. |
| Taken after Active Record conversion completed, but before `SECRET_KEY_BASE` changed | Keep the converted Active Record keys and restore the old `SECRET_KEY_BASE` that still encrypted the settings. |
| Taken after `SECRET_KEY_BASE` changed or while a conversion was incomplete | It may contain old-key and new-key data, or settings that were already unreadable. Preserve both secrets and all Active Record keys; restoring this snapshot does not undo that broken or mixed state. |

For the last case, prefer a known-readable backup from before the failing change
if losing the intervening writes is acceptable. Otherwise keep writers stopped
and resume recovery on the restored data: first make Active Record data readable
with the appropriate current/previous keys, then rotate settings with the secret
that actually encrypted them. Use [Manual settings recovery](#manual-settings-recovery)
for settings that neither secret decrypts. Do not blindly replace the current
secret with the old one: that can make new-key rows unreadable. Missing Active
Record keys cannot be recovered by restoring the same unreadable data.

Keep previous-key variables and `OLD_SECRET_KEY_BASE` limited to the one-off
conversion commands. If the restored snapshot still needs recovery, require the
successful conversions and settings verification above before starting workers.
For a known-readable rollback with all matching keys restored, follow
[Verify recovery before resuming services](#verify-recovery-before-resuming-services),
then resume workers and normal access only after its checks succeed. Do not run settings-secret
rotation when the old and current secrets are the same; a readable rollback does
not require another secret change.

### Re-encrypting data after an encryption-related update

If a release note mentions a fix to Active Record encryption configuration, data written before you updated may still be stored as plaintext. Convert it as described in [Encrypting data stored without encryption](#encrypting-data-stored-without-encryption).

`web` and `worker` read whether the conversion has finished only when they start. The procedure stops both before converting and starts them again afterwards, so they pick up the result.

### Upgrade note: instance-wide settings need a super admin

Provider credentials (such as Plaid), the shared AI connection settings (LLM provider, endpoints, API keys and models), sync settings, and the external assistant connection are stored once for the whole instance and apply to every family. On an instance with more than one family, only a `super_admin` can change them. When there is a single family, its admins keep access. Family-scoped choices, such as which assistant a family uses, stay with that family's admins.

Installs created before the first user was automatically made `super_admin` may have no super admin at all. If your instance has more than one family (for example, because someone else signed up), these instance-wide settings are hidden after the update and saving them returns "not authorized". Promote your own user once:

```bash
docker compose exec web bin/rails runner 'User.find_by!(email: "you@example.com").update!(role: :super_admin)'
```

After that, you can promote other users at `/admin/users`. See section 3.5 of the [OIDC guide](oidc.md) for the console variant.

## How to change which updates your app receives

Set `SURE_IMAGE_TAG` in your `.env` file to a channel (`stable`, `latest`) or a specific version (for example `0.7.4`):

```bash
SURE_IMAGE_TAG=0.7.4
```

After doing this, pull and restart the app:

```bash
docker compose pull web worker
docker compose up -d
```

## Backups, upgrades and rollbacks

The `backup` service in `compose.example.yml` takes full backups of your instance. It runs the same Sure image as `web` and `worker`, so there is nothing to install or download. Run these commands from the directory that holds `compose.yml`.

**Take a backup now** (do this before every upgrade):

```bash
docker compose run --rm backup create
```

**Take a backup every day** at 02:00 UTC, keeping the last 7 days of daily backups:

```bash
docker compose --profile backup up -d backup
```

**See your backups:**

```bash
docker compose run --rm backup list
```

### What a backup contains

Each backup is a folder under `backups/<version>/<date>-<manual|scheduled>/` with everything needed to bring the same version back up, on this machine or a new one:

| File | Contents |
|---|---|
| `db.dump` | The whole database: accounts, transactions, budgets, rules, users and settings |
| `storage.tar.gz` | Uploaded files: transaction attachments, account statements and documents, imports and exports, profile pictures and account logos |
| `config/.env`, `config/compose.yml` | Your configuration, including `SECRET_KEY_BASE` |
| `manifest.json` | Sure version and image, database schema version, when it was taken |
| `restore.sh` | Restores the backup into a new folder (see below) |
| `SHA256SUMS` | Checksums, verified before every restore |

`db.dump` is written with the PostgreSQL tools in the Sure image (version 17), which older tools can't read. Restore it with `sure-backup` (`restore`, `recover` or `restore.sh`), not with `pg_restore` from the `db` container.

Uploaded files are backed up from the `app-storage` volume. If you store them in S3, Cloudflare R2, Google Cloud Storage or another bucket (`ACTIVE_STORAGE_SERVICE`), they are not in the backup; use your provider's versioning or replication for those.

The version comes from the running app: every time `web` starts it records its version, and a backup is refused if the database schema no longer matches it.

> [!WARNING]
> `config/.env` contains `SECRET_KEY_BASE`, your API keys and, if you set them,
> your [encryption keys](#encrypting-sensitive-data). Preserve the exact effective
> keys used for the backed-up data: `SECRET_KEY_BASE` alone cannot replace explicit
> Active Record keys, and derived keys need the original `SECRET_KEY_BASE`.
> Keys or Rails credentials stored outside `.env`, including the key needed to
> decrypt those credentials, need their own secure backup. Keep the backup folder
> private, and encrypt off-site copies (for example with
> [rclone crypt](https://rclone.org/crypt/)).

### Settings

Set these in `.env`:

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_DIR` | `./backups` | Host folder for backups |
| `BACKUP_SCHEDULE` | `0 2 * * *` | Daily time for scheduled backups, as `minute hour * * *` in UTC |
| `BACKUP_KEEP_DAYS` | `7` | Scheduled backups older than this are deleted; backups you take with `create` are kept |

### Off-site copies

The optional `backup-offsite` service copies the backup folder to any [rclone](https://rclone.org/) remote (S3, Cloudflare R2, Backblaze B2, SFTP, Google Drive, ...) every hour, under `<BACKUP_DESTINATION>/<INSTANCE_ID>/`, and removes scheduled backups there after `BACKUP_KEEP_DAYS`. Set `BACKUP_DESTINATION` and the `RCLONE_CONFIG_*` variables in `.env` (see `.env.example`), then:

```bash
docker compose --profile backup-offsite up -d backup-offsite
```

### Roll back an upgrade

Stop all writers, including any separate web-only recovery session or custom
writer services. Keep the database and Redis running for the restore:

```bash
docker compose stop web worker
docker compose run --rm --no-deps backup restore 0.7.4/2026-10-01_080524-manual   # or "latest"
# Set SURE_IMAGE_TAG=0.7.4 in .env
```

`restore` replaces the database and local uploaded files; external uploads need
their matching provider restore. It refuses while other clients are connected to the database, and asks you to type `restore` to confirm (pass `--yes` to skip in scripts).
Stop on a restore error. After a successful restore, restore the matching image,
configuration and keys, then follow
[Verify recovery before resuming services](#verify-recovery-before-resuming-services).
For an interrupted key rotation, choose the named backup and keys using
[Restoring after an interrupted rotation](#restoring-after-an-interrupted-rotation)
instead of choosing `latest`.

### Restore into a new folder or onto a new machine

Every backup contains `restore.sh`. Before running it, follow
[Preparing a separate recovery environment](#preparing-a-separate-recovery-environment),
including preserving any configuration outside the bundle:

```bash
(
  unset COMPOSE_ENV_FILES COMPOSE_DISABLE_ENV_FILE COMPOSE_PATH_SEPARATOR
  unset COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_DIR
  sh 2026-10-01_080524-manual/restore.sh --without-worker --no-start
)
```

It verifies the backup and asks for a folder for the restored instance (new or empty; its name becomes the Compose project name). Then it:

- refuses if Docker already has containers or volumes for that project name, or if the copied compose files use storage outside the new folder (external volumes or networks, absolute host paths), so it can't overwrite another instance;
- warns if other Sure instances are running on the machine, and offers to start the restored one without its `worker` (see below);
- picks the next free port if the backup's `PORT` is taken;
- stops with a list of files to copy over if your compose files mount local files that are not part of the backup (custom certificates, for example);
- copies the configuration and the backup in, pins `web` and `worker` to the backed-up version in `compose.restore.yml`, and sets `COMPOSE_FILE` in `.env` so plain `docker compose` commands use it;
- unless `--no-start` is set, restores the database and files, starts the app and prints its address.

The example above only prepares the folder. Inspect its configuration and finish
the restore using [Preparing a separate recovery environment](#preparing-a-separate-recovery-environment)
before starting services. Do not paste the printed startup chain: its final
command starts `web` before the verification access restrictions are applied.
Options such as `--target ~/sure-restored --port 3001`
supply answers non-interactively; `--yes` skips confirmation prompts.

> [!WARNING]
> Don't run a restored copy with its `worker` while the original instance is still running. Both would sync the same bank connections (some providers rotate access tokens on every sync, so the copy can disconnect the original) and run scheduled jobs such as recurring transactions and emails twice. Signing in to both on `localhost` also signs you out of the other, because browsers share cookies across ports.

### Without the backup service (any version, including 0.7.5 and older)

You can also run backups with the script on its own, without the `backup` service and without editing `compose.yml`. That's the way to back up and restore Sure 0.7.5 and older, whose images don't include the script, and it suits anyone who prefers to keep the script outside the image. Download it once next to `compose.yml`:

```bash
curl --fail --location --silent --show-error --output sure-backup https://raw.githubusercontent.com/we-promise/sure/main/bin/sure-backup
```

Then, from that folder, [select the same Compose project and configuration](#selecting-the-standalone-backup-target)
that you use to manage the installation:

```bash
sh sure-backup create                   # Take a backup now
sh sure-backup list                     # List backups
sh sure-backup restore latest           # Roll back in place (stop web and worker first)
```

For `recover` into a new folder, use the separate environment below instead of
the source installation's exported Compose selection.

The script finds your `web` container and runs itself once in a container from that exact image, with your uploaded-files volume, network and database settings. It reads the version from the image and checks it against the database, so no `--version` is needed. Backups go to `./backups`, or `BACKUP_DIR` from `.env`. `restore` refuses while `web` or `worker` is running.
After a successful in-place restore, use
[Verify recovery before resuming services](#verify-recovery-before-resuming-services)
with the matching image, configuration and keys; stop on any restore error.

To take a backup every day without the service, add a cron job on the host, for example `0 2 * * * cd /opt/sure && sh sure-backup scheduled`. That takes a backup and removes scheduled backups older than `BACKUP_KEEP_DAYS`.

#### Selecting the standalone backup target

The script calls `docker compose` internally; it does not accept Compose's `-p`,
`-f`, or `--env-file` options. Before stopping writers or running the script,
set the equivalent [Compose environment variables](https://docs.docker.com/compose/how-tos/environment-variables/envvars/)
in the same shell. For example, replace these example values with those from
your existing deployment; do not introduce a new project name:

```bash
export COMPOSE_PROJECT_NAME="sure-production"                  # Same as -p
export COMPOSE_FILE="compose.yml:compose.production.yml"      # Same files/order as -f
export COMPOSE_ENV_FILES=".env.production"                    # Same as --env-file
docker compose config --quiet
docker compose ps -aq web
```

Set only the overrides your deployment needs, and preserve any exported values
and profiles it already uses. Multiple environment files in `COMPOSE_ENV_FILES`
are comma-separated, in the same order as your `--env-file` options. Multiple
Compose files use `:` on macOS/Linux (`;` on Windows, unless
`COMPOSE_PATH_SEPARATOR` overrides it). Run from the original configuration
directory and preserve the same Docker context. Confirm that `docker compose
ps -aq web` returns the same container ID as your usual command with its explicit
options. Also compare the **resolved configuration**, not just the ID: the same
project can resolve relative paths differently while still finding that container.

These exports do not reproduce a custom `--project-directory`. If the original
command requires a project directory different from the first Compose file's
directory, this standalone method is not supported for that deployment. Do not
run its backup or rotation commands. Use the current backup service with the
original CLI options if available, or establish and verify a supported backup
procedure first; do not drop `--project-directory` or move configuration files
to make the check pass.

For a supported layout, compare configuration using the same shell and working
directory as the script. Adapt the first command below to your **usual explicit
options** and the exports above to match them. The temporary files contain secrets,
so keep them private and do not paste their contents into logs or issue comments:

```bash
(
  set -eu
  umask 077
  compare_dir=$(mktemp -d)
  trap 'rm -rf "$compare_dir"' EXIT
  docker compose -p sure-production -f compose.yml -f compose.production.yml \
    --env-file .env.production config --format json > "$compare_dir/usual.json"
  docker compose config --format json > "$compare_dir/standalone.json"
  if ! cmp -s "$compare_dir/usual.json" "$compare_dir/standalone.json"; then
    echo "Compose configurations differ; stop and correct the selection." >&2
    exit 1
  fi
)
```

Proceed only when both configuration commands and the comparison succeed and the
existing container IDs match. If either configuration is invalid or differs, or
the ID is missing or differs, stop and correct the selection before any backup,
restore or rotation. Do not recreate containers just to make these checks pass.

Keep these settings for stopping writers, creating the backup, in-place restore,
and subsequent rotation commands. A new shell or cron job needs the same setup;
the cron example above assumes the default configuration.

Selecting a custom environment file does **not** make the backup script archive
it. The script copies `.env` and the standard Compose/override filenames from the
project directory; separately preserve custom Compose files, `env_file` files,
included files, shell-supplied configuration and external keys with the named
backup. Its host-side `BACKUP_DIR`, `BACKUP_KEEP_DAYS`, and `INSTANCE_ID` settings
also come from that directory's `.env`, not `COMPOSE_ENV_FILES`. Confirm the actual
backup location rather than assuming the custom env file selected it. Before
restarting a restored installation, restore the matching configuration and keys;
in-place restore does not replace live configuration, and `recover`/`restore.sh`
cannot automatically reconstruct configuration that was not archived.

#### Preparing a separate recovery environment

`restore` rolls back the existing project and needs its original selection.
`recover` (also called by a bundle's `restore.sh`) creates a different project;
it must read the restored configuration instead of the source's custom env file.
Use a fresh recovery shell without exported application overrides such as
`SECRET_KEY_BASE`, `ACTIVE_RECORD_ENCRYPTION_*`, database or storage settings.
Preserve the Docker connection/context needed to access the intended daemon.

Clear the Compose overrides in a subshell so the original recovery shell remains
available for in-place operations. For example, from the folder containing the
script, replace the example backup path and target with your own:

```bash
(
  unset COMPOSE_ENV_FILES COMPOSE_DISABLE_ENV_FILE COMPOSE_PATH_SEPARATOR
  unset COMPOSE_PROJECT_NAME COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_DIR
  sh sure-backup recover backups/0.7.6/2026-10-27_111135-manual \
    --target "$HOME/sure-restored" --without-worker --no-start
)
```

For a bundle's `restore.sh`, use the same subshell/unsets and replace the `sh`
command with `sh /path/to/backup/restore.sh --target "$HOME/sure-restored"
--without-worker --no-start`. This prepares files only; it does not restore data
or start services. Custom Compose/includes/`env_file` files omitted from the
bundle must be securely copied and wired into the target configuration. If
preparation fails because one is missing, preserve the partially prepared folder,
inspect the error and complete its configuration; do not rerun `recover` against
that now non-empty folder or continue with startup commands after an error.

In the target directory, use a clean shell with the same Compose overrides
cleared. Inspect the restored `.env` and custom files for source-specific paths
and overrides, adapt the target copies and supply any missing files first. Keep
the original backup unchanged. Validate the target's resolved configuration,
including the `sure-backup` profile, and verify that its database,
volumes, mounts, networks and external uploads cannot overwrite the source instance.
Use a separate Redis/queue endpoint as well; a restored copy must not enqueue or
consume jobs in the source instance's queue.
Do not execute the printed startup chain. Omit its final `docker compose up -d web`
command (or `web worker` if the preparation was run without `--without-worker`);
use the separate restore and verification steps below instead. If you added
custom Compose files, update the target's `COMPOSE_FILE` selection as well;
keep `compose.restore.yml` last to retain the pinned image and restore service.
Do not overwrite the reviewed selection with an earlier, incomplete file list.

The same steps apply after successful preparation and after correcting a
configuration-validation failure: the prepared target contains
`compose.restore.yml`, `bin/sure-backup` and the copied backup. With the target
configuration valid and the isolation checks above complete, continue from that
target with the Compose overrides cleared. Keep `web`, `worker` and any other
writers stopped; these commands start only the data services and restore data.
`--no-deps` prevents custom dependencies from starting other services; `--wait`
waits for the database and Redis health checks before the restore. Retain working
health checks for both services in a customized Compose file.
Replace the backup ID below with the copied backup's actual version/name:

```bash
docker compose --profile sure-backup config --quiet &&
  docker compose up -d --no-deps --wait db redis &&
  docker compose run --rm --no-deps -e SURE_RECOVER=1 sure-backup restore 0.7.6/2026-10-27_111135-manual --yes
```

Stop on any error. After a successful restore, complete any matching
[external-upload restore](#backup-and-restore-prerequisites) and confirm the keys
before following [Verify recovery before resuming services](#verify-recovery-before-resuming-services).
That sequence applies access restrictions before starting `web` and keeps
workers stopped until verification succeeds. Do not use new-folder recovery
as a substitute for the [interrupted-rotation recovery checks](#restoring-after-an-interrupted-rotation).

### Upgrading from the database-only backup service (v0.7.5)

Sure v0.7.5 shipped a `backup` service that ran `bin/db-backup.sh` and uploaded database dumps with rclone. It keeps working until you change it, but it does not back up uploaded files or configuration and cannot restore. To switch:

1. Replace the `backup` service in your `compose.yml` with the `backup` and `backup-offsite` services from the current [`compose.example.yml`](https://github.com/we-promise/sure/blob/main/compose.example.yml).
2. In `.env`, remove `BACKUP_OVERWRITE`; backups are now kept per version and date. `BACKUP_SCHEDULE` must be a daily time (`minute hour * * *`). `BACKUP_DESTINATION`, `INSTANCE_ID` and the `RCLONE_CONFIG_*` variables now belong to `backup-offsite`.
3. Start them: `docker compose --profile backup --profile backup-offsite up -d backup backup-offsite`.

Off-site backups now go to `<BACKUP_DESTINATION>/<INSTANCE_ID>/<version>/<date>-<trigger>/` and include `.env`, so use an encrypted remote. Earlier `backup_*.sql.gz` files are left in place and are no longer pruned; delete them once you no longer need them. To restore one of them, stop `web` and `worker` and load it with `gunzip -c backup_<timestamp>.sql.gz | docker compose exec -T db psql -U <POSTGRES_USER> -d <POSTGRES_DB>` into an empty database.

If you download the new `bin/db-backup.sh` without updating the compose file, the backup service stops with an error that points here.

## Encrypting sensitive data

Sure encrypts sensitive fields in the database, such as bank and provider credentials, MFA secrets, email addresses and names. On images containing the encryption gating fix in [#3189](https://github.com/we-promise/sure/pull/3189), a self-hosted instance uses these key sources in order:

- Your own keys, set with the three `ACTIVE_RECORD_ENCRYPTION_*` variables. Set all three or none: the app refuses to start when only some of them are set.
- Rails credentials, if configured and not overridden by a complete set of environment keys.
- Otherwise, keys that Sure derives from `SECRET_KEY_BASE`. Changing `SECRET_KEY_BASE` then changes the keys as well.

> [!WARNING]
> Encrypted data can only be read with the keys it was encrypted with. On an instance with data, don't change the three keys or `SECRET_KEY_BASE` except as described below, and keep `config/.env` (which backups include) private.

Your own keys are recommended, because they don't depend on `SECRET_KEY_BASE`. If the boot log warns that `SECRET_KEY_BASE` is a publicly known value, the derived keys are public; see [Encryption key rotation](encryption.md).

For an existing installation, run backfill and rotation commands from its configuration directory.
Retain the same Compose project, files, environment, and app image throughout a
backfill or rotation. Include your usual `-f`, `-p`, `--project-directory`, and `--env-file` options on
**every** command so it targets the same services and volumes. Stop any other
writers as well as `web` and `worker`; keep the database and Redis running for the
one-off commands. Preserve the original configuration and any keys outside `.env`
alongside a verified backup. Missing old keys must be recovered before proceeding;
a backfill cannot recover lost keys.

### Backup and restore prerequisites

The existing-install encryption procedures below and the [secret-rotation procedure](#upgrading-an-install-that-is-already-running-keep-your-secret_key_base)
use the current `backup` service. If it is missing, or your Compose file still
uses the v0.7.5 database-only service, use
[Without the backup service](#without-the-backup-service-any-version-including-075-and-older)
to create and restore a complete backup without replacing your deployment
configuration. See [Upgrading the old backup service](#upgrading-from-the-database-only-backup-service-v075)
if you also want to update that service; do not combine a service upgrade with an
in-progress key rotation.

With the standalone method, substitute `sh sure-backup create` for the service's
`backup create` command, and `sh sure-backup restore` followed by the recorded
backup folder name for `backup restore`. Keep writers stopped and use the same
Compose project and configuration for both methods; follow
[Selecting the standalone backup target](#selecting-the-standalone-backup-target)
when using the script, including for in-place restore.

Confirm that the backup contains the database and configuration, with any custom
configuration files and external keys preserved separately. For local uploads,
verify that `storage.tar.gz` includes the installation's uploaded files. For S3,
R2, GCS, or another external store, verify a separate, restorable provider backup
of the objects referenced by the database snapshot while writers remain stopped.
A local storage archive does not prove that external uploads are backed up, and
enabling versioning or replication alone does not verify a usable restore point.
Record the provider snapshot or object versions with the named database backup
and restore the matching objects when rolling back. Keep access credentials and
any required storage encryption keys securely available. Do not proceed on a
failed backup or a database-only dump without the corresponding configuration,
keys, and upload backups.

### Generate the keys

Run this three times and keep the three values:

```bash
openssl rand -hex 32
```

Compose files from before this section existed don't pass the keys to the containers. If the `x-rails-env` block of your `compose.yml` has no `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` line, copy the three `ACTIVE_RECORD_ENCRYPTION_*` lines from [`compose.example.yml`](../../compose.example.yml) into it. Until you do, keys in `.env` have no effect.

> [!IMPORTANT]
> If `.env` already holds the keys but your `compose.yml` didn't pass them on, they were never active. Passing them on changes the keys of your instance, so remove the three lines from `.env` before you update `compose.yml`, and add them back only as described in [Switching an existing instance to your own keys](#switching-an-existing-instance-to-your-own-keys).

### On a new instance

Add the keys to `.env` before the first `docker compose up`:

```txt
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="first value"
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="second value"
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="third value"
```

### Encrypting data stored without encryption

Older versions of Sure stored this data unencrypted when no keys were set. After an update, Sure still reads those rows and encrypts whatever it writes, but rows it hasn't written since stay unencrypted until you convert them. The conversion uses the keys the instance already has and doesn't change them.

Update Sure to a version that includes this guide first and let it start once, so its database migrations have run. Older versions convert only some of the tables. Then:

1. Stop `web`, `worker`, and any other writers. Keep them stopped until the conversion succeeds:

   ```bash
   docker compose stop web worker
   ```

2. Take a backup using the [supported backup method](#backup-and-restore-prerequisites), confirm it succeeded, and note the folder name it prints (for example `0.7.6/2026-10-27_111135-manual`):

   ```bash
   docker compose run --rm --no-deps backup create
   ```

3. Preview the conversion. The `1` makes it a dry run that changes nothing. Its report must show `"dry_run":true`, list every table with `"failed_count":0` and include a `session_ip_digests` entry:

   ```bash
   docker compose run --rm --no-deps web bin/rails "security:backfill_encryption[100,1]"
   ```

   If rows fail, inspect `failed_samples`; undecryptable ciphertext can mean the instance no longer has the keys, for example after `SECRET_KEY_BASE` was changed. Keep writers stopped and resolve the failures before converting. Restore the effective keys or use [Encryption key rotation](encryption.md) with the correct previous keys; do not substitute newly generated keys.

4. Convert the data:

   ```bash
   docker compose run --rm --no-deps web bin/rails "security:backfill_encryption[100,0]"
   ```

   The command must finish without an error, and the JSON report on its last line must show `"ok":true` and `"failed_count":0`. If it does not, keep writers stopped and investigate the per-table `failed_samples`. After fixing the cause, repeat the command. If you must restore, use the named backup from step 2 and the [backup-state-specific recovery guidance](#restoring-after-an-interrupted-rotation).

5. Follow [Verify recovery before resuming services](#verify-recovery-before-resuming-services): apply administrator-only access restrictions, start only `web`, check that your connections load in **Settings > Bank Sync**, and complete the remaining checks before starting workers.

A clean write pass records the current backfill version. On the next boot, the
initializer uses that record to disable legacy plaintext reads and query fallback.
A dry run does not mark completion; a failed write leaves completion unset. Use the
successful write report and the staged startup in step 5 to apply the result to
both services. Successful
sign-in alone, or setting `ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA=false`,
is not proof of completion. The manifest in
[`lib/active_record_encryption_config.rb`](../../lib/active_record_encryption_config.rb)
tracks the encrypted columns; the task also handles sessions and IP digests.
`Setting` secrets use separate encryption and a separate rotation task, described
in [Upgrading an existing install](#upgrading-an-install-that-is-already-running-keep-your-secret_key_base).

### Switching an existing instance to your own keys

Data an instance has already encrypted with the derived keys can't be read with new keys. The steps below first check whether the instance holds any such data. If it doesn't, for example because it was updated straight from a version that stored everything unencrypted, they convert it to your keys directly. If it does, step 4 moves it to your keys with the derived keys as previous keys.

> [!NOTE]
> Already added keys without these steps? Stop writers and preserve both the old and new key material before changing anything else. The data may now contain rows encrypted with either set. Removing the new keys alone makes rows written with them unreadable. Use the same new keys as the current keys and supply the correct old keys during the rotation below; do not restart until the write pass succeeds.

Update Sure to a version that includes this guide first and let it start once, so its database migrations have run. Don't combine the switch with a version update. Then:

1. Stop `web`, `worker`, and any other writers. Keep them stopped until the conversion succeeds:

   ```bash
   docker compose stop web worker
   ```

2. Take a backup using the [supported backup method](#backup-and-restore-prerequisites), confirm it succeeded, and note the folder name it prints (for example `0.7.6/2026-10-27_111135-manual`):

   ```bash
   docker compose run --rm --no-deps backup create
   ```

3. Add the three keys to `.env` (and the three lines to `compose.yml` if they are missing; see above).

4. Preview the conversion with the new keys. The `1` makes it a dry run that changes nothing; its report must show `"dry_run":true`:

   ```bash
   docker compose run --rm --no-deps web bin/rails "security:backfill_encryption[100,1]"
   ```

   If every table shows `"failed_count":0` and the report includes `session_ip_digests`, proceed to step 5. Otherwise inspect `failed_samples`: if the failures are undecryptable ciphertext written with the derived keys, preview again with the `SECRET_KEY_BASE` that encrypted those rows as previous keys:

   ```bash
   read -rs ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE && export ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE   # paste the SECRET_KEY_BASE from .env
   docker compose run --rm --no-deps -e ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE web bin/rails "security:backfill_encryption[100,1]"
   ```

   If every table now shows `"failed_count":0`, add the same `-e ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE` to the command in step 5, and retain the previous value for retries until step 5 finishes successfully with `"ok":true` and `"failed_count":0`. Only then run `unset ACTIVE_RECORD_ENCRYPTION_PREVIOUS_SECRET_KEY_BASE` before restarting services. Pass the variable only to these commands, never put it into `.env` or `compose.yml`: while it is set, Rails writes deterministically encrypted values (emails, tokens, API keys) with the old keys. If rows still fail, keep writers stopped and resolve the failures. If the previous keys were explicit rather than derived, use the `ACTIVE_RECORD_ENCRYPTION_PREVIOUS_*` values described in [Encryption key rotation](encryption.md). Do not assume all failed rows use derived keys or restart with a configuration that cannot decrypt them.

5. Convert the data:

   ```bash
   docker compose run --rm --no-deps web bin/rails "security:backfill_encryption[100,0]"
   ```

   The command must finish without an error, and the JSON report on its last line must show `"ok":true` and `"failed_count":0`. If it does not, keep writers stopped and inspect the per-table `failed_samples`. Fix the cause before repeating the command with the same current and previous keys. If the conversion cannot be completed, undo the change as described below.

6. Follow [Verify recovery before resuming services](#verify-recovery-before-resuming-services): apply administrator-only access restrictions, start only `web`, check that your connections load in **Settings > Bank Sync**, and complete the remaining checks before starting workers.

To undo the switch, stop `web` and `worker` and use the backup from step 2 by its name (not `latest`, which may be a newer scheduled backup taken with the keys). Follow [Restoring after an interrupted rotation](#restoring-after-an-interrupted-rotation) to pair it with the correct image, configuration, and keys. A backup taken after an accidental key change may already contain mixed-key data and still require recovery; do not restart until it is readable. Remove the three explicit keys only if the backed-up data does not require them. With the current backup service:

```bash
docker compose stop web worker
docker compose run --rm --no-deps backup restore 0.7.6/2026-10-27_111135-manual
```

## Troubleshooting

### ActiveRecord::DatabaseConnectionError

If you are trying to get Sure started for the **first time** and run into database connection issues, it is likely because Docker has already initialized the Postgres database with a _different_ default role (usually from a previous attempt to start the app).

If you run into this issue, you can optionally **reset the database**.

**PLEASE NOTE: this will delete any existing data that you have in your Sure database, so proceed with caution.**  For first-time users of the app just trying to get started, you're generally safe to run the commands below.

By running the commands below, you will delete your existing Sure database and "reset" it.

```
docker compose down
docker volume rm sure_postgres-data # this is the name of the volume the DB is mounted to
docker compose up
docker compose exec db psql -U sure_user -d sure_development -c "SELECT 1;" # This will verify that the issue is fixed
```

### Slow `.csv` import (processing rows taking longer than expected)

Importing comma-separated-value file(s) requires the `sure-worker` container to communicate with Redis. Check your worker logs for any unexpected errors, such as connection timeouts or Redis communication failures.

### Inspecting background jobs (`/sidekiq`)

Sure ships the Sidekiq Web dashboard at `/sidekiq`. The route only exists for a signed-in **super admin** — the first user created on your instance. Anyone else (including logged-out visitors) gets a 404, so there is nothing to configure to keep it safe. If you want a second layer of protection anyway, set both `SIDEKIQ_WEB_USERNAME` and `SIDEKIQ_WEB_PASSWORD` in your environment file to additionally require basic-auth credentials; there are no default credentials.

For day-to-day triage of stuck syncs, imports, and exports, prefer **Settings → Background jobs** — it maps queue state onto the actual records and offers safe recovery actions. The Sidekiq dashboard is a break-glass tool; two warnings when using it directly:

- Never manually retry `SimplefinConnectionUpdateJob` — it consumes a single-use setup token, and a retry permanently breaks that connection attempt.
- Deleting or retrying jobs does **not** update the corresponding Sure record (a deleted `ImportJob` leaves its import stuck in `importing`) — use Settings → Background jobs for record-level recovery.

