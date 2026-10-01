# Self Hosting Sure with Docker

This guide will help you setup, update, and maintain your self-hosted Sure application with Docker Compose. Docker Compose is the most popular and recommended way to self-host the Sure app.

## Setup Guide

Follow the guide below to get your app running.

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

Open your terminal and create a directory where your app will run. Below is an example command with a recommended directory:

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

# (Optional) If you plan to use backups (recommended before upgrades):
mkdir -p bin
curl --fail --location --silent --show-error --output bin/sure-backup https://raw.githubusercontent.com/we-promise/sure/main/bin/sure-backup
chmod +x bin/sure-backup
```

This command will do the following:

1. Fetch the sample docker compose file from our public Github repository
2. Creates a file in your current directory called `compose.yml` with the contents of the example file
3. (Optionally) Fetches the backup script to `bin/sure-backup` and makes it executable. See [Backups, upgrades and rollbacks](#backups-upgrades-and-rollbacks).

At this point, you should have `compose.yml` in your directory (and optionally `bin/sure-backup` alongside `compose.yml` when using backups).

### Step 3 (optional): Configure your environment

By default, our `compose.example.yml` file runs without any configuration.  
That said, if you would like extra security (important if you're running outside of a local network), you can follow the steps below to set things up.

If you're running the app locally and don't care much about security, you can skip this step.

#### Create your environment file

In order to configure the app, you will need to create a file called `.env`, which is where Docker will read environment variables from.

To do this, you should get our .env.example as a starting point:

```bash
curl --fail --location --silent --show-error --output .env https://raw.githubusercontent.com/we-promise/sure/main/.env.example
```

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

#### WebAuthn MFA (passkeys and security keys)

If you enable passkeys, Touch ID, Windows Hello, or hardware security keys as MFA credentials, pin the WebAuthn relying party settings in your `.env` file:

```txt
WEBAUTHN_RP_ID="example.com"
WEBAUTHN_ALLOWED_ORIGINS="https://sure.example.com"
```

`WEBAUTHN_RP_ID` should usually be your registrable domain, not a full URL. See [WebAuthn MFA Configuration](webauthn.md) before changing hostnames or reverse proxy settings for an instance with registered passkeys.

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

### Operational note for the sample-data button

If you want to load sample/demo data on a small host:

1. Raise the **worker's** memory limit (the generator runs in the worker process, not the web process). On Render, bump the worker service's plan; on Docker Compose, raise the worker container's memory limit.
2. Apply the change with a **fresh deploy/restart of the worker**. Note for Render specifically: plan changes only take effect on the next deploy - they do **not** apply on a plain restart.
3. Load the sample data, then optionally drop the worker back to the small plan with another fresh deploy.

## How to update your app

The mechanism that updates your self-hosted Sure app is the GHCR (Github Container Registry) Docker image that you see in the `compose.yml` file:

```yml
image: ghcr.io/we-promise/sure:${SURE_IMAGE_TAG:-stable}
```

We recommend using one of the following images, but you can pin your app to whatever version you'd like (see [packages](https://github.com/we-promise/sure/pkgs/container/sure)):

- `ghcr.io/we-promise/sure:latest` (latest `alpha`)
- `ghcr.io/we-promise/sure:stable` (latest release)

By default, your app _will NOT_ automatically update. Take a backup first (see below), then run:

```bash
cd ~/docker-apps/sure # Navigate to whatever directory you configured the app in
docker compose run --rm backup create # Back up the current version (optional, recommended)
docker compose pull web worker # Pull the newest image for your tag
docker compose up -d # Restart on the new version; database migrations run automatically
```

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

The optional `backup` service in `compose.example.yml` runs `bin/sure-backup`. Each backup is a self-contained bundle with everything needed to bring the same version back up, on this machine or a new one:

```text
backups/
  0.7.4/
    2026-10-01_080524-manual/
      manifest.json      # version, commit, image, schema version, ...
      db.dump            # PostgreSQL dump (pg_dump custom format)
      storage.tar.gz     # uploaded files (the app-storage volume)
      config/            # .env, compose file(s) and bin/sure-backup
      restore.sh         # restores this bundle into a new folder
      SHA256SUMS
```

The version comes from the running app: on every boot the web container records its version in the storage volume, and a backup is refused if the database schema no longer matches it.

> [!WARNING]
> `config/.env` contains `SECRET_KEY_BASE` and your API keys. Without `SECRET_KEY_BASE`, encrypted data in the database cannot be read. Keep the backup folder private and use an encrypted remote (for example [rclone crypt](https://rclone.org/crypt/)) for off-site copies.

### Commands

Run these from the directory that holds `compose.yml`:

```bash
docker compose run --rm backup create   # Take a backup now ("manual"; never pruned)
docker compose run --rm backup list     # List backups, newest first
docker compose run --rm backup restore 0.7.4/2026-10-01_080524-manual   # or "latest"
docker compose run --rm backup prune    # Remove scheduled backups older than BACKUP_KEEP_DAYS
```

Backups are written to `./backups`; set `BACKUP_DIR` in `.env` to use another host folder.

### Scheduled and off-site backups

Start the service in the background to take a backup every day (`BACKUP_SCHEDULE`, cron syntax, default `0 2 * * *`):

```bash
docker compose --profile backup up -d backup
```

Scheduled backups older than `BACKUP_KEEP_DAYS` (default 7) are pruned; manual ones are kept until you delete them. Set `BACKUP_DESTINATION` (an [rclone](https://rclone.org/) remote such as `s3:my-bucket/sure`) and the matching `RCLONE_CONFIG_*` variables to also copy each scheduled backup off-site, under `<BACKUP_DESTINATION>/<INSTANCE_ID>/<version>/`. See `.env.example`.

### Roll back an upgrade

```bash
docker compose stop web worker
docker compose run --rm backup restore 0.7.4/2026-10-01_080524-manual
# Set SURE_IMAGE_TAG=0.7.4 in .env (the restore prints the exact value)
docker compose up -d
```

`restore` replaces the database and all uploaded files. It refuses while other clients are connected to the database, and asks you to type `restore` to confirm (pass `--yes` to skip in scripts).

### Restore into a new folder or onto a new machine

Every bundle contains `restore.sh`, so you don't need this repository to restore one. Copy the bundle folder to the machine (Docker with the Compose plugin is the only requirement), then run:

```bash
sh 2026-10-01_080524-manual/restore.sh
```

It verifies the bundle and asks for a folder for the restored instance; that folder must be new or empty, and its name becomes the Compose project name. It then:

- refuses if Docker already has containers or volumes for that project name, so it can never overwrite another instance;
- warns if other Sure instances are running on the machine, and lets you start the restored one without its `worker` (see below);
- picks the next free port if the backup's `PORT` is taken;
- copies the configuration and the bundle in, writes `compose.restore.yml` to pin `web` and `worker` to the backed-up version, and sets `COMPOSE_FILE` in `.env` so plain `docker compose` commands use it;
- restores the database and files and starts the app.

For scripts, pass the answers as options: `sh restore.sh --target ~/sure-restored --port 3001 --without-worker --yes`. Add `--no-start` to only prepare the folder.

> [!WARNING]
> Don't run a restored copy with its `worker` while the original instance is still running. Both would sync the same bank connections (some providers rotate access tokens on every sync, so the copy can disconnect the original) and run scheduled jobs such as recurring transactions and emails twice. Signing in to both on `localhost` also signs you out of the other, because browsers share cookies across ports.

Bundles taken before `restore.sh` existed can be restored the same way with a current copy of the script: `sh bin/sure-backup recover <bundle folder>`.

### Apps started before version stamping

If your app has not been restarted since upgrading to a version that records its version, `create` asks for it explicitly:

```bash
docker compose run --rm backup create --version 0.7.4
```

### Upgrading from the database-only backup service (v0.7.5)

Sure v0.7.5 shipped a `backup` service that ran `bin/db-backup.sh` and uploaded database dumps with rclone. It keeps working until you change it, but it does not back up uploaded files or config and cannot restore. To switch:

1. Download `bin/sure-backup` (see [Step 2](#step-2-configure-your-docker-compose-file-and-environment)).
2. Replace the `backup` service in your `compose.yml` with the one from the current [`compose.example.yml`](https://github.com/we-promise/sure/blob/main/compose.example.yml).
3. Remove `BACKUP_OVERWRITE` from `.env`; backups are now always kept per version and date. `BACKUP_SCHEDULE`, `BACKUP_KEEP_DAYS`, `BACKUP_DESTINATION`, `INSTANCE_ID` and the `RCLONE_CONFIG_*` variables work as before.
4. Restart it: `docker compose --profile backup up -d backup`.

Off-site backups now go to `<BACKUP_DESTINATION>/<INSTANCE_ID>/<version>/<timestamp>-scheduled/` and include `.env`, so use an encrypted remote. Earlier `backup_*.sql.gz` files are left in place and are no longer pruned; delete them once you no longer need them. To restore one of them, stop `web` and `worker` and load it with `gunzip -c backup_<timestamp>.sql.gz | docker compose exec -T db psql -U <POSTGRES_USER> -d <POSTGRES_DB>` into an empty database.

If you download the new `bin/db-backup.sh` without updating the compose file, the backup service stops with an error that points here.

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

