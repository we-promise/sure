#!/bin/bash
set -e

# Start PostgreSQL
echo "Starting PostgreSQL..."
sudo pg_ctlcluster 15 main start || sudo pg_ctlcluster 16 main start || sudo pg_ctlcluster 17 main start

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
  if pg_isready -h localhost -U postgres > /dev/null 2>&1; then
    echo "PostgreSQL is ready"
    break
  fi
  sleep 1
done

# Create database user and database if they don't exist
echo "Setting up database..."
psql -h localhost -U postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='rails'" | grep -q 1 || \
  psql -h localhost -U postgres -c "CREATE USER rails WITH SUPERUSER PASSWORD 'rails';"

psql -h localhost -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='sure_development'" | grep -q 1 || \
  psql -h localhost -U postgres -c "CREATE DATABASE sure_development OWNER rails;"

# Set DATABASE_URL if not already set
export DATABASE_URL="${DATABASE_URL:-postgres://rails:rails@localhost:5432/sure_development}"

# Generate SECRET_KEY_BASE if not set
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -hex 64)}"

# Run database migrations
echo "Running database migrations..."
./bin/rails db:prepare

# Execute the main command
echo "Starting Rails server..."
exec "$@"
