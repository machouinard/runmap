#!/bin/bash
# Helper script to run psql commands against staging database
# Usage: bash scripts/staging-psql.sh -c "SELECT COUNT(*) FROM runmap.runs_raw;"
# Usage: bash scripts/staging-psql.sh -f db/01_create_tables.sql

set -e

# Load staging environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$PROJECT_ROOT/.env.staging" ]; then
    echo "ERROR: .env.staging not found!"
    exit 1
fi

# Export staging variables (filter out comments and inline comments)
export $(grep -v '^#' "$PROJECT_ROOT/.env.staging" | sed 's/#.*//' | xargs)

# Set PostgreSQL environment variables
export PGHOST=$DB_HOST
export PGDATABASE=$DB_NAME
export PGUSER=$DB_USER
# PGPASSWORD already set from .env.staging

# Run psql with provided arguments
psql "$@"
