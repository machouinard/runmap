#!/bin/bash
# Common environment configuration for all scripts
# Source this at the top of each script: source "$(dirname "${BASH_SOURCE[0]}")/common/env.sh"
#
# Environment Setup:
#   Mac Studio (local dev):   ln -sf .env.local .env
#   Ubuntu Server (prod):     deploy.sh copies .env.production → .env

# Get the project root directory
if [ -z "$PROJECT_ROOT" ]; then
  # This file is in scripts/common/, so go up two levels to get project root
  ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export PROJECT_ROOT="$(cd "$ENV_SCRIPT_DIR/../.." && pwd)"
fi

# Load environment variables from .env file
ENV_FILE="$PROJECT_ROOT/.env"
if [ -f "$ENV_FILE" ]; then
  set -a  # Export all variables automatically
  source "$ENV_FILE"
  set +a
else
  echo "ERROR: .env file not found at $ENV_FILE"
  echo ""
  echo "Setup instructions:"
  echo "  Local dev (Mac Studio):  ln -sf .env.local .env"
  echo "  Production (Ubuntu):     deploy.sh handles this automatically"
  echo ""
  exit 1
fi

# Validate required variables
if [ -z "$PGPASSWORD" ]; then
  echo "ERROR: PGPASSWORD not set in .env file"
  exit 1
fi

# Set defaults for optional variables
export DB_HOST=${DB_HOST:-localhost}
export DB_USER=${DB_USER:-runmap_user}
export DB_NAME=${DB_NAME:-runmap_local}
export TILES_DIR=${TILES_DIR:-$PROJECT_ROOT/tiles}
export TMP_DIR=${TMP_DIR:-/tmp/runmap}

# Export PostgreSQL environment variables for psql/pg_dump/etc
# IMPORTANT: PGHOST must be set explicitly to override local socket connection
export PGPASSWORD
export PGHOST=$DB_HOST
export PGUSER=$DB_USER
export PGDATABASE=$DB_NAME

# Export DATABASE_* variables for Python scripts (used by ingest_gpx.sh)
export DATABASE_HOST=$DB_HOST
export DATABASE_NAME=$DB_NAME
export DATABASE_USER=$DB_USER
export DATABASE_PASSWORD=$PGPASSWORD
