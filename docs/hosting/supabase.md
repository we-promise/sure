# Using Supabase with Sure

This guide explains how to use [Supabase](https://supabase.com) (or any hosted PostgreSQL) instead of the bundled Docker PostgreSQL container.

> **Important**: External database support requires building Sure locally. The prebuilt Docker image from ghcr.io does not include the necessary configuration for external databases.

## Prerequisites

- A Supabase account (free tier works)
- Docker and Docker Compose installed
- Sure source code cloned locally

## Step 1: Create a Supabase Project

1. Go to [supabase.com](https://supabase.com) and create a new project
2. Wait for the project to be provisioned (~2 minutes)

## Step 2: Get Session Pooler Connection Details

Supabase's free tier doesn't include IPv4 for direct connections. Use the **Session Pooler** instead:

1. Go to **Project Settings → Database**
2. Click **"Session pooler"** (not "Direct connection")
3. Note your connection details:
   - Host: `aws-0-<region>.pooler.supabase.com`
   - Port: `5432`
   - User: `postgres.<project-ref>` (includes project reference!)
   - Database: `postgres`

## Step 3: Configure Environment Variables

Create or update your `.env` file:

```bash
# Supabase Session Pooler Configuration
DB_HOST=aws-1-ap-south-1.pooler.supabase.com
DB_PORT=5432
POSTGRES_USER=postgres.your-project-ref
POSTGRES_PASSWORD=your_database_password
POSTGRES_DB=postgres
DB_SSLMODE=require
DB_PREPARED_STATEMENTS=false

# Required for Rails (generate with: openssl rand -hex 64)
SECRET_KEY_BASE=your_generated_secret_here
```

## Step 4: Update Docker Compose

Modify your `compose.yml` to build locally instead of using the prebuilt image:

```yaml
services:
  web:
    build: .                                    # Build locally
    # image: ghcr.io/we-promise/sure:latest    # Don't use prebuilt image
    # ... rest of config

  worker:
    build: .                                    # Build locally
    # image: ghcr.io/we-promise/sure:latest    # Don't use prebuilt image
    # ... rest of config
```

## Step 5: Build and Run

After changing to `build: .` in the previous step:

```bash
# Build the images locally (required for external DB support)
docker compose build

# Run the application
docker compose up
```

The application will connect to Supabase using the `DB_HOST` from your `.env` file.

## Step 6: Verify Connection

```bash
# Check logs
docker compose logs -f web

# You should see Rails booting successfully
```

## Common Issues

### "Circuit breaker open: Too many authentication errors"

Supabase temporarily blocks connections after multiple failed attempts. Wait 5-10 minutes before retrying.

### "Network is unreachable" (IPv6 error)

You're using Direct Connection instead of Session Pooler. Switch to the Session Pooler in Supabase dashboard.

### "password authentication failed for user postgres"

Make sure your `POSTGRES_USER` includes the project reference:
- Wrong: `postgres`
- Correct: `postgres.your-project-ref`

## Migrating Existing Data

If you have an existing Sure installation:

```bash
# Export from local PostgreSQL
docker compose exec db pg_dump -U postgres postgres > backup.sql

# Import to Supabase (via psql or Supabase SQL Editor)
psql "postgresql://postgres.ref:password@aws-0-region.pooler.supabase.com:5432/postgres" < backup.sql
```
