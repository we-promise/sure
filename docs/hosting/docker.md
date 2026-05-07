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
curl -o compose.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.yml
```

This command will do the following:

1. Fetch the sample docker compose file from our public Github repository
2. Creates a file in your current directory called `compose.yml` with the contents of the example file

At this point, the only file in your current working directory should be `compose.yml`.

### Step 3 (optional): Configure your environment

By default, our `compose.example.yml` file runs without any configuration.  
That said, if you would like extra security (important if you're running outside of a local network), you can follow the steps below to set things up.

If you're running the app locally and don't care much about security, you can skip this step.

#### Create your environment file

In order to configure the app, you will need to create a file called `.env`, which is where Docker will read environment variables from.

To do this, you should get our .env.example as a starting point:

```bash
curl -o .env https://raw.githubusercontent.com/we-promise/sure/main/.env.example
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

- **Pipelock** (always on): AI agent security proxy that scans outbound LLM calls and inbound MCP traffic
- **Ollama + Open WebUI** (optional `--profile ai`): local LLM inference

### Using the AI compose file

```bash
# Download both compose files
curl -o compose.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.yml
curl -o compose.ai.yml https://raw.githubusercontent.com/we-promise/sure/main/compose.example.ai.yml
curl -o pipelock.example.yaml https://raw.githubusercontent.com/we-promise/sure/main/pipelock.example.yaml

# Run with Pipelock (no local LLM)
docker compose -f compose.ai.yml up -d

# Run with Pipelock + Ollama
docker compose -f compose.ai.yml --profile ai up -d
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

See [docs/hosting/ai.md](ai.md) for full configuration details including agent ID, session keys, and email allowlisting.

### Pipelock security proxy

Pipelock sits between Sure and external services, scanning AI traffic for:

- **Secret exfiltration** (DLP): catches API keys, tokens, or personal data leaking in prompts
- **Prompt injection**: detects attempts to override system instructions
- **Tool poisoning**: validates MCP tool calls against known-safe patterns

When using `compose.example.ai.yml`, Pipelock is always running. External AI agents should connect to port 8889 (MCP reverse proxy) instead of directly to Sure's `/mcp` on port 3000.

For full Pipelock configuration, see [docs/hosting/pipelock.md](pipelock.md).

## How to update your app

The mechanism that updates your self-hosted Sure app is the GHCR (Github Container Registry) Docker image that you see in the `compose.yml` file:

```yml
image: ghcr.io/we-promise/sure:latest
```

We recommend using one of the following images, but you can pin your app to whatever version you'd like (see [packages](https://github.com/we-promise/sure/pkgs/container/sure)):

- `ghcr.io/we-promise/sure:latest` (latest `alpha`)
- `ghcr.io/we-promise/sure:stable` (latest release)

By default, your app _will NOT_ automatically update. To update your self-hosted app, run the following commands in your terminal:

```bash
cd ~/docker-apps/sure # Navigate to whatever directory you configured the app in
docker compose pull # This pulls the "latest" published image from GHCR
docker compose build # This rebuilds the app with updates
docker compose up --no-deps -d web worker # This restarts the app using the newest version
```

## How to change which updates your app receives

If you'd like to pin the app to a specific version or tag, all you need to do is edit the `compose.yml` file:

```yml
image: ghcr.io/we-promise/sure:stable
```

After doing this, make sure and restart the app:

```bash
docker compose pull # This pulls the "latest" published image from GHCR
docker compose build # This rebuilds the app with updates
docker compose up --no-deps -d web worker # This restarts the app using the newest version
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
