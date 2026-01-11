# Database Mirror

Sure supports mirroring all database writes to an external hosted PostgreSQL database (such as Supabase). This feature is useful for:

- **Data durability** - Keep a backup copy of all data in a cloud-hosted database
- **Disaster recovery** - Quickly restore from the mirror if your local database is lost
- **Multi-region availability** - Host your mirror in a different region for redundancy

## How It Works

The database mirror feature uses ActiveRecord callbacks to automatically enqueue background jobs whenever a record is created, updated, or deleted. These jobs run in Sidekiq and replicate the changes to your external PostgreSQL database.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Model Save │ ──▶ │ after_commit│ ──▶ │ Sidekiq Job │ ──▶ │ External DB │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
```

**Key features:**

- **Non-blocking**: Mirror operations run as background jobs and don't slow down your application
- **Retry logic**: Jobs retry with exponential backoff if the connection fails (up to 10 attempts)
- **Schema detection**: The mirror database schema is automatically initialized if the database is empty
- **Append-only mode**: If the mirror database already contains data, it only appends/updates records

## Configuration

### Environment Variables

Add these to your `.env` file:

```bash
# Enable database mirroring
DATABASE_MIRROR_ENABLED=true

# External PostgreSQL connection details
MIRROR_DB_HOST=db.xxxxx.supabase.co
MIRROR_DB_PORT=5432
MIRROR_DB_NAME=postgres
MIRROR_DB_USER=postgres
MIRROR_DB_PASSWORD=your_password

# Optional configuration
MIRROR_DB_POOL=3          # Connection pool size (default: 3)
MIRROR_DB_SSLMODE=require # SSL mode: disable, prefer, require, verify-ca, verify-full
```

### Docker Compose

If using Docker Compose, add the environment variables to your `x-rails-env` section:

```yaml
x-rails-env: &rails_env
  # ... other variables ...
  DATABASE_MIRROR_ENABLED: ${DATABASE_MIRROR_ENABLED:-false}
  MIRROR_DB_HOST: ${MIRROR_DB_HOST:-}
  MIRROR_DB_PORT: ${MIRROR_DB_PORT:-5432}
  MIRROR_DB_NAME: ${MIRROR_DB_NAME:-}
  MIRROR_DB_USER: ${MIRROR_DB_USER:-}
  MIRROR_DB_PASSWORD: ${MIRROR_DB_PASSWORD:-}
  MIRROR_DB_SSLMODE: ${MIRROR_DB_SSLMODE:-require}
```

## Setting Up Supabase

1. Create a free account at [supabase.com](https://supabase.com)
2. Create a new project
3. Go to **Project Settings** → **Database** → **Connection string**
4. Copy the connection details:
   - Host: `db.xxxxx.supabase.co` (or use the pooler URL for better performance)
   - Port: `5432` (or `6543` for pooled connections)
   - Database: `postgres`
   - User: `postgres`
   - Password: Your database password

5. Add these to your `.env` file as shown above
6. Restart your application

The schema will be automatically created in your Supabase database on first connection if it's empty.

## Excluding Models

To exclude specific models from being mirrored (e.g., for security-sensitive data), add `exclude_from_mirror` to the model:

```ruby
class ApiKey < ApplicationRecord
  exclude_from_mirror
  # ...
end
```

## Monitoring

Mirror job activity appears in your Sidekiq dashboard. Look for `DatabaseMirrorJob` in the job queue:

- **high_priority** queue: Mirror jobs run on the high priority queue
- **Retries**: Failed jobs will retry with exponential backoff

Check your Rails logs for mirror status:

```
[DatabaseMirror] Database mirroring is enabled
[DatabaseMirror] Mirror DB: db.xxxxx.supabase.co:5432/postgres
[MirrorRecord] Successfully connected to mirror database
[DatabaseMirrorService] Created User#abc123 in mirror
```

## Troubleshooting

### Connection failures

- Verify your connection credentials
- Check that your IP is allowed in Supabase's database settings
- Try setting `MIRROR_DB_SSLMODE=require` for Supabase

### Foreign key violations

These are normal when jobs execute out of order. The retry logic will handle them - parent records will be created first on subsequent retries.

### Schema not created

If the mirror database already has tables, the schema won't be re-created. To reset:
1. Drop all tables in your Supabase database
2. Restart your application

## Architecture

The mirroring feature consists of:

- **`Mirrorable` concern** (`app/models/concerns/mirrorable.rb`): Hooks into ActiveRecord callbacks
- **`DatabaseMirrorJob`** (`app/jobs/database_mirror_job.rb`): Background job with retry logic
- **`DatabaseMirrorService`** (`app/services/database_mirror_service.rb`): Handles external DB connection and SQL operations
- **Initializer** (`config/initializers/database_mirror.rb`): Validates configuration on startup
