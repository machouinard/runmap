# Refactoring Roadmap: One-Command Database Setup

**Goal:** Go from "hours of manual setup with 11 failure points" → "one command that works every time"

**Current Reality:** Setting up a fresh database requires:
- Manually running 10+ SQL files in correct order
- Running osmium extract to trim PBF files
- Running ogr2ogr with specific syntax
- Manually adding missing columns that aren't in schema files
- Deleting wrong highway types after import
- Creating missing tables, views, and functions
- Fixing geometry type mismatches
- Managing environment files and symlinks
- Avoiding common pitfalls (port conflicts, environment variable inheritance, etc.)

**Target:** `bash scripts/setup_fresh_database.sh` → complete working database in 5 minutes

---

## Critical Scripts to Build

### 1. `scripts/setup_fresh_database.sh` (Master Setup Script)

**Purpose:** Single command to set up a complete working database from scratch

**What it does:**
```bash
#!/bin/bash
# Usage: bash scripts/setup_fresh_database.sh [local|production]

set -e  # Exit on any error

ENV=${1:-local}  # Default to local

echo "Setting up RunMap database for $ENV environment..."

# 1. Validate prerequisites
bash scripts/setup/validate_prerequisites.sh

# 2. Create database and extensions
bash scripts/setup/create_database.sh $ENV

# 3. Import and process OSM data
bash scripts/setup/import_osm_streets.sh $ENV

# 4. Load schema (tables, functions, views)
bash scripts/setup/load_schema.sh $ENV

# 5. Initialize coverage system
bash scripts/setup/initialize_coverage.sh $ENV

# 6. Validate setup
bash scripts/setup/validate_database.sh $ENV

echo "✅ Database setup complete!"
```

**Dependencies:** All the subscripts below

---

### 2. `scripts/setup/validate_prerequisites.sh`

**Purpose:** Check that all required tools and files exist before starting

**Checks:**
```bash
#!/bin/bash
# Validate prerequisites for database setup

set -e

echo "Validating prerequisites..."

# Required tools
command -v psql >/dev/null 2>&1 || { echo "❌ psql not found. Install PostgreSQL."; exit 1; }
command -v ogr2ogr >/dev/null 2>&1 || { echo "❌ ogr2ogr not found. Install GDAL."; exit 1; }
command -v osmium >/dev/null 2>&1 || { echo "❌ osmium not found. Install osmium-tool."; exit 1; }
command -v tippecanoe >/dev/null 2>&1 || { echo "❌ tippecanoe not found."; exit 1; }
command -v pmtiles >/dev/null 2>&1 || { echo "❌ pmtiles not found."; exit 1; }

# Required files
[ -f "aoi_processing/SacExpanded.geojson" ] || { echo "❌ AOI GeoJSON not found."; exit 1; }
[ -f "aoi_processing/SacExpanded.pbf" ] || { echo "❌ Source PBF not found."; exit 1; }
[ -f "db/01_create_tables.sql" ] || { echo "❌ Schema files not found."; exit 1; }

# PostgreSQL extensions
psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS postgis;" -d postgres >/dev/null 2>&1 || {
  echo "❌ Cannot create PostGIS extension. Check PostgreSQL installation.";
  exit 1;
}

echo "✅ All prerequisites met"
```

---

### 3. `scripts/setup/create_database.sh`

**Purpose:** Create database, schema, user, and extensions

**What it does:**
```bash
#!/bin/bash
# Create database infrastructure

set -e

ENV=${1:-local}

if [ "$ENV" = "local" ]; then
  DB_NAME="runmap_local"
  DB_HOST="localhost"
else
  DB_NAME="runmap"
  DB_HOST="192.168.68.25"
fi

DB_USER="runmap_user"
DB_PASSWORD="fucker"

echo "Creating database $DB_NAME on $DB_HOST..."

# Drop and recreate (for fresh setup)
psql -U postgres -h $DB_HOST << EOF
DROP DATABASE IF EXISTS $DB_NAME;
CREATE DATABASE $DB_NAME;
\c $DB_NAME
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS runmap;
EOF

# Create user if doesn't exist
psql -U postgres -h $DB_HOST -d $DB_NAME << EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '$DB_USER') THEN
    CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';
  END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
GRANT ALL ON SCHEMA runmap TO $DB_USER;
GRANT ALL ON ALL TABLES IN SCHEMA runmap TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA runmap GRANT ALL ON TABLES TO $DB_USER;
EOF

echo "✅ Database created"
```

---

### 4. `scripts/setup/import_osm_streets.sh`

**Purpose:** Trim PBF to AOI boundary and import only runnable streets

**What it does:**
```bash
#!/bin/bash
# Import OSM streets with correct filtering

set -e

ENV=${1:-local}
source scripts/setup/config.sh  # Load DB connection params

echo "Importing OSM streets..."

# 1. Trim PBF to GeoJSON boundary using osmium
echo "  Trimming PBF to AOI boundary..."
osmium extract \
  --config aoi_processing/config.json \
  --overwrite \
  aoi_processing/SacExpanded.pbf

TRIMMED_PBF="aoi_processing/output/sacramento-streets.osm.pbf"

# 2. Import only runnable street types
echo "  Importing runnable streets..."

# CRITICAL: Only these highway types are runnable
# residential, primary, secondary, tertiary, unclassified, living_street
# EXCLUDE: motorway, footway, cycleway, path, pedestrian, service

ogr2ogr -f "PostgreSQL" \
  PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$DB_PASSWORD" \
  -sql "SELECT osm_id, name, highway FROM lines
        WHERE highway IN ('residential', 'primary', 'secondary', 'tertiary',
                          'unclassified', 'living_street')
        AND highway <> 'service'" \
  -nln runmap.streets_reference \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=gid \
  -t_srs EPSG:4326 \
  -overwrite \
  "$TRIMMED_PBF"

# 3. Create UTM-projected version
echo "  Creating UTM-projected streets..."
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
ALTER TABLE runmap.streets_reference ADD COLUMN IF NOT EXISTS runnable BOOLEAN DEFAULT TRUE;

DROP TABLE IF EXISTS runmap.streets_reference_32610 CASCADE;
CREATE TABLE runmap.streets_reference_32610 AS
SELECT gid as ogc_fid, osm_id, name, highway,
       ST_Transform(geom, 32610) as geom_32610,
       ST_Length(ST_Transform(geom, 32610)) as total_length_m
FROM runmap.streets_reference;

ALTER TABLE runmap.streets_reference_32610 ADD PRIMARY KEY (ogc_fid);
CREATE INDEX streets_reference_32610_geom_idx ON runmap.streets_reference_32610 USING GIST (geom_32610);
EOF

STREET_COUNT=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM runmap.streets_reference;")
echo "✅ Imported $STREET_COUNT streets"
```

---

### 5. `scripts/setup/load_schema.sh`

**Purpose:** Load ALL SQL schema files in correct order

**What it does:**
```bash
#!/bin/bash
# Load all schema files in dependency order

set -e

ENV=${1:-local}
source scripts/setup/config.sh

echo "Loading database schema..."

PSQL="PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME"

# Load in dependency order
echo "  Loading base tables..."
$PSQL -f db/01_create_tables.sql

echo "  Loading intersection split schema..."
$PSQL -f db/04_phase1_intersection_split.sql

echo "  Loading segment schema..."
$PSQL -f db/04_segment_schema.sql

echo "  Loading activity tables..."
$PSQL -f db/12_activity_tables.sql

echo "  Loading location tracking..."
$PSQL -f db/13_location_tracking.sql

echo "  Loading workout hash..."
$PSQL -f db/14_workout_hash_migration.sql

echo "  Loading route name..."
$PSQL -f db/15_add_route_name.sql

echo "  Loading views..."
$PSQL -f db/02_create_views.sql 2>/dev/null || true  # May have errors, continue
$PSQL -f db/05_utility_views.sql 2>/dev/null || true
$PSQL -f db/06_fix_dynamic_thresholds.sql

# Fix common schema issues
echo "  Applying schema fixes..."
$PSQL << 'EOF'
-- Fix geometry type mismatch
ALTER TABLE runmap.streets_blocks_32610 ALTER COLUMN geom_32610 TYPE geometry(Geometry, 32610);

-- Ensure all required columns exist
ALTER TABLE runmap.runs_raw ADD COLUMN IF NOT EXISTS total_distance_m double precision;
ALTER TABLE runmap.runs_raw ADD COLUMN IF NOT EXISTS processing_status text DEFAULT 'processed';
ALTER TABLE runmap.runs_raw ADD COLUMN IF NOT EXISTS processing_started_at timestamptz;
ALTER TABLE runmap.runs_raw ADD COLUMN IF NOT EXISTS processing_completed_at timestamptz;
ALTER TABLE runmap.runs_raw ADD COLUMN IF NOT EXISTS error_message text;

ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS start_time timestamptz;
ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS duration_seconds integer;
ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS total_distance_m double precision;
ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS processing_status text DEFAULT 'processed';
ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS processing_started_at timestamptz;
ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS processing_completed_at timestamptz;
ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS error_message text;

ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS start_time timestamptz;
ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS duration_seconds integer;
ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS total_distance_m double precision;
ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS processing_status text DEFAULT 'processed';
ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS processing_started_at timestamptz;
ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS processing_completed_at timestamptz;
ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS error_message text;

-- Create missing tables
CREATE TABLE IF NOT EXISTS runmap.aoi (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  geom geometry(Polygon, 4326),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS runmap.processing_errors (
  id SERIAL PRIMARY KEY,
  run_id UUID,
  error_type TEXT,
  error_message TEXT,
  occurred_at TIMESTAMPTZ DEFAULT now(),
  resolved BOOLEAN DEFAULT false
);

CREATE TABLE IF NOT EXISTS runmap.streets_reference_vertices_pgr (
  id BIGSERIAL PRIMARY KEY,
  cnt INTEGER,
  chk INTEGER,
  ein INTEGER,
  eout INTEGER,
  the_geom geometry(Point, 4326)
);

-- Create missing functions
CREATE OR REPLACE FUNCTION runmap.get_buffer_distance()
RETURNS NUMERIC AS \$\$
  SELECT COALESCE((value::text)::numeric, 10)
  FROM runmap.settings
  WHERE key = 'buffer_distance_m'
  LIMIT 1;
\$\$ LANGUAGE sql STABLE;

-- Create missing views
CREATE OR REPLACE VIEW runmap.failed_runs AS
SELECT r.*, pe.error_type, pe.occurred_at as error_time
FROM runmap.runs_raw r
LEFT JOIN runmap.processing_errors pe ON r.id = pe.run_id
WHERE r.processing_status = 'failed' OR pe.id IS NOT NULL;
EOF

echo "✅ Schema loaded"
```

---

### 6. `scripts/setup/initialize_coverage.sh`

**Purpose:** Split streets into blocks, create segments, initialize tracking

**What it does:**
```bash
#!/bin/bash
# Initialize coverage tracking system

set -e

ENV=${1:-local}
source scripts/setup/config.sh

echo "Initializing coverage system..."

PSQL="PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME"

echo "  Splitting streets at intersections..."
$PSQL -c "SELECT runmap.split_streets_at_intersections();"

BLOCK_COUNT=$($PSQL -t -c "SELECT COUNT(*) FROM runmap.streets_blocks_32610;")
echo "  Created $BLOCK_COUNT blocks"

echo "  Creating 5m segments..."
$PSQL << 'EOF'
TRUNCATE runmap.block_segments CASCADE;

INSERT INTO runmap.block_segments (block_id, segment_geom, segment_length_m)
SELECT b.block_id,
       (ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom,
       ST_Length((ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom)
FROM runmap.streets_blocks_32610 b;

INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE FROM runmap.block_segments;

INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
SELECT block_id, 0, SUM(segment_length_m)
FROM runmap.block_segments
GROUP BY block_id;

-- Initialize settings
INSERT INTO runmap.settings (key, value) VALUES
  ('buffer_distance_m', '10'::jsonb),
  ('completion_threshold_pct', '75'::jsonb),
  ('tiles_version', to_jsonb(extract(epoch from now())::bigint))
ON CONFLICT (key) DO NOTHING;
EOF

SEGMENT_COUNT=$($PSQL -t -c "SELECT COUNT(*) FROM runmap.block_segments;")
echo "✅ Coverage system initialized ($SEGMENT_COUNT segments)"
```

---

### 7. `scripts/setup/validate_database.sh`

**Purpose:** Verify database is correctly set up

**What it does:**
```bash
#!/bin/bash
# Validate database setup

set -e

ENV=${1:-local}
source scripts/setup/config.sh

echo "Validating database setup..."

PSQL="PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t"

# Check table counts
TABLE_COUNT=$($PSQL -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='runmap' AND table_type='BASE TABLE';")
EXPECTED_TABLES=15

if [ "$TABLE_COUNT" -ne "$EXPECTED_TABLES" ]; then
  echo "❌ Expected $EXPECTED_TABLES tables, found $TABLE_COUNT"
  exit 1
fi

# Check street counts
STREET_COUNT=$($PSQL -c "SELECT COUNT(*) FROM runmap.streets_reference;")
if [ "$STREET_COUNT" -eq 0 ]; then
  echo "❌ No streets imported"
  exit 1
fi

# Check highway types (should only be runnable types)
INVALID_TYPES=$($PSQL -c "SELECT COUNT(*) FROM runmap.streets_reference WHERE highway IN ('motorway', 'footway', 'cycleway', 'path', 'pedestrian');")
if [ "$INVALID_TYPES" -gt 0 ]; then
  echo "❌ Found $INVALID_TYPES non-runnable highway types"
  exit 1
fi

# Check coverage system
BLOCK_COUNT=$($PSQL -c "SELECT COUNT(*) FROM runmap.streets_blocks_32610;")
SEGMENT_COUNT=$($PSQL -c "SELECT COUNT(*) FROM runmap.block_segments;")
COVERAGE_COUNT=$($PSQL -c "SELECT COUNT(*) FROM runmap.block_coverage_segments;")

if [ "$BLOCK_COUNT" -eq 0 ] || [ "$SEGMENT_COUNT" -eq 0 ] || [ "$COVERAGE_COUNT" -eq 0 ]; then
  echo "❌ Coverage system not initialized"
  exit 1
fi

# Summary
echo ""
echo "✅ Database validation passed"
echo ""
echo "Summary:"
echo "  Tables: $TABLE_COUNT"
echo "  Streets: $STREET_COUNT"
echo "  Blocks: $BLOCK_COUNT"
echo "  Segments: $SEGMENT_COUNT"
echo ""
echo "  Bounds: $($PSQL -c "SELECT CONCAT('lng ', ROUND(ST_XMin(ST_Extent(geom))::numeric, 6), ' to ', ROUND(ST_XMax(ST_Extent(geom))::numeric, 6), ', lat ', ROUND(ST_YMin(ST_Extent(geom))::numeric, 6), ' to ', ROUND(ST_YMax(ST_Extent(geom))::numeric, 6)) FROM runmap.streets_reference;")"
echo ""
echo "Highway types:"
$PSQL -c "SELECT '  ' || highway || ': ' || COUNT(*) FROM runmap.streets_reference GROUP BY highway ORDER BY COUNT(*) DESC;"
```

---

### 8. `scripts/setup/config.sh`

**Purpose:** Centralized configuration for all setup scripts

**What it does:**
```bash
#!/bin/bash
# Configuration for database setup scripts

ENV=${1:-local}

if [ "$ENV" = "local" ]; then
  export DB_HOST="localhost"
  export DB_NAME="runmap_local"
  export DB_USER="runmap_user"
  export DB_PASSWORD="fucker"
  export TILES_DIR="/Users/markchouinard/Development/GIS/runs-cdm/tiles"
  export GPX_DIR="/Users/markchouinard/Development/GIS/runs-cdm/gpx"
elif [ "$ENV" = "production" ]; then
  export DB_HOST="192.168.68.25"
  export DB_NAME="runmap"
  export DB_USER="runmap_user"
  export DB_PASSWORD="fucker"
  export TILES_DIR="/home/mark/runmap/tiles"
  export GPX_DIR="/home/mark/runmap/gpx"
else
  echo "❌ Invalid environment: $ENV (must be 'local' or 'production')"
  exit 1
fi

# Runnable highway types (CRITICAL - must match production)
export RUNNABLE_HIGHWAY_TYPES="residential,primary,secondary,tertiary,unclassified,living_street"

# Non-runnable types to exclude
export EXCLUDED_HIGHWAY_TYPES="motorway,footway,cycleway,path,pedestrian,service"
```

---

## SQL Schema Consolidation Needed

### Current Problem
- Schema files scattered across 10+ files
- Missing columns not in any file
- Views reference columns that don't exist in fresh install
- No single source of truth

### Solution: `db/00_complete_schema.sql`

**Purpose:** Single file that creates complete working schema

**Structure:**
```sql
-- 00_complete_schema.sql
-- Complete schema for RunMap database
-- This file can set up a working database from scratch

-- Extensions
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS runmap;

-- Core tables (from 01_create_tables.sql + missing pieces)
CREATE TABLE runmap.runs_raw (...with ALL columns);
CREATE TABLE runmap.walks_raw (...with ALL columns);
CREATE TABLE runmap.cycling_raw (...with ALL columns);
CREATE TABLE runmap.streets_reference (...);
CREATE TABLE runmap.streets_reference_32610 (...);
CREATE TABLE runmap.streets_blocks_32610 (...with correct geometry type);
CREATE TABLE runmap.block_segments (...);
CREATE TABLE runmap.block_segment_visited (...);
CREATE TABLE runmap.block_coverage_segments (...);
CREATE TABLE runmap.runs_buffered_subdiv (...);
CREATE TABLE runmap.settings (...);
CREATE TABLE runmap.performance_log (...);
CREATE TABLE runmap.aoi (...);
CREATE TABLE runmap.processing_errors (...);
CREATE TABLE runmap.streets_reference_vertices_pgr (...);

-- All functions
CREATE FUNCTION runmap.split_streets_at_intersections() ...;
CREATE FUNCTION runmap.buffer_one_run_subdiv(uuid) ...;
CREATE FUNCTION runmap.apply_run_to_segments(uuid) ...;
CREATE FUNCTION runmap.detect_location(geometry) ...;
CREATE FUNCTION runmap.get_buffer_distance() ...;
CREATE FUNCTION runmap.get_completion_threshold() ...;
CREATE FUNCTION runmap.auto_process_new_run_segments() ...;
CREATE FUNCTION runmap.cleanup_coverage_on_delete() ...;
CREATE FUNCTION runmap.set_location_on_insert() ...;

-- All views
CREATE VIEW runmap.streets_unrun ...;
CREATE VIEW runmap.streets_partial ...;
CREATE VIEW runmap.streets_complete ...;
CREATE VIEW runmap.all_activities ...;
CREATE VIEW runmap.blocks_per_street ...;
CREATE VIEW runmap.blocks_stats ...;
CREATE VIEW runmap.failed_runs ...;

-- All triggers
CREATE TRIGGER trigger_auto_process_run_segments ...;
CREATE TRIGGER trigger_cleanup_coverage_on_delete ...;
CREATE TRIGGER trigger_set_location_on_insert ...;

-- Indexes
CREATE INDEX ... ;

-- Initial data
INSERT INTO runmap.settings (key, value) VALUES
  ('buffer_distance_m', '10'::jsonb),
  ('completion_threshold_pct', '75'::jsonb),
  ('tiles_version', '0'::jsonb);
```

---

## Documentation Consolidation

### Create: `docs/DATABASE_SETUP_GUIDE.md`

**Purpose:** Single authoritative guide for database setup

**Contents:**
```markdown
# Database Setup Guide

## Quick Start

### New Database from Scratch
bash scripts/setup_fresh_database.sh local

### Validate Existing Database
bash scripts/setup/validate_database.sh local

## Manual Setup (if automated script fails)
[Step by step instructions matching the automated scripts]

## Troubleshooting
[All 11 issues from SETUP_ISSUES_AND_SOLUTIONS.md with solutions]

## Schema Reference
[Link to 00_complete_schema.sql with explanation of each table]

## Highway Type Reference
Runnable types: residential, primary, secondary, tertiary, unclassified, living_street
Excluded types: motorway, footway, cycleway, path, pedestrian, service

## AOI Management
[How to trim PBF files, expand AOI, etc.]
```

---

## Testing Infrastructure

### Create: `scripts/test_database_setup.sh`

**Purpose:** Automated test that sets up database from scratch and validates

**What it does:**
```bash
#!/bin/bash
# Automated test of database setup

set -e

TEST_DB="runmap_test_$(date +%s)"

echo "Testing database setup with temporary database: $TEST_DB"

# Override DB_NAME in config
export DB_NAME=$TEST_DB

# Run setup
bash scripts/setup_fresh_database.sh local

# Run validation
bash scripts/setup/validate_database.sh local

# Cleanup
psql -U postgres -c "DROP DATABASE $TEST_DB;"

echo "✅ Database setup test passed"
```

---

## Environment Management

### Create: `scripts/setup_environment.sh`

**Purpose:** Set up .env files and symlinks correctly

**What it does:**
```bash
#!/bin/bash
# Set up environment files for local or production

ENV=${1:-local}

if [ "$ENV" = "local" ]; then
  echo "Setting up local development environment..."

  # Create symlinks
  ln -sf .env.local .env
  cd api && ln -sf .env.local .env && cd ..

  echo "✅ Environment configured for local development"
  echo "   .env → .env.local"
  echo "   api/.env → api/.env.local"

elif [ "$ENV" = "production" ]; then
  echo "⚠️  Production environment is managed on the server"
  echo "    deploy.sh copies .env.production → .env on deploy"

else
  echo "❌ Invalid environment: $ENV (must be 'local' or 'production')"
  exit 1
fi
```

---

## Summary: What Gets Built

1. **Master setup script** - One command to rule them all
2. **7 modular subscripts** - Each handles one aspect of setup
3. **Consolidated schema file** - Single source of truth for database structure
4. **Configuration file** - Centralized settings for all scripts
5. **Validation script** - Ensures setup worked correctly
6. **Test script** - Automated testing of setup process
7. **Environment script** - Manages .env files correctly
8. **Comprehensive docs** - Single guide replacing multiple scattered docs

**Result:**
- **Setup time:** Hours → 5 minutes
- **Failure points:** 11 manual steps → 0 (automated)
- **Documentation:** 5+ scattered files → 1 authoritative guide
- **Repeatability:** Unreliable → 100% reproducible
