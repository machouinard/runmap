# Local Development Setup (Mac Studio)

This guide explains how to set up the RunMap application for local development on your Mac Studio.

## Prerequisites

- PostgreSQL 16 with PostGIS 3 installed locally
- Node.js and npm (for React frontend)
- Python 3.x with venv (for Flask API)
- GDAL/OGR tools (for geospatial processing)
- Tippecanoe (for tile generation)
- PMTiles CLI

## Environment Configuration

The application uses environment-specific `.env` files to manage configuration for local development vs. production deployment.

### Environment Files Structure

```
runs-cdm/
├── .env                    # Symlink → .env.local (Mac) or copied from .env.production (Ubuntu)
├── .env.local              # Local development config (Mac Studio)
├── .env.production         # Production config (deployed to Ubuntu server)
├── .env.example            # Template (not used directly)
└── api/
    ├── .env                # Symlink or copy of api/.env.local or api/.env.production
    ├── .env.local          # Flask local development config
    ├── .env.production     # Flask production config
    └── .env.example        # Template (not used directly)
```

### Setup Environment Files

**On Mac Studio (local development):**

```bash
cd /Users/markchouinard/Development/GIS/runs-cdm

# Create symlink for root .env
ln -sf .env.local .env

# Create symlink for API .env
cd api
ln -sf .env.local .env
cd ..
```

**On Ubuntu Server (production):**

The `scripts/deploy.sh` script automatically handles this by copying:
- `.env.production` → `.env`
- `api/.env.production` → `api/.env`

### Environment File Contents

**.env.local** (Mac Studio local development):
- `DB_HOST=localhost`
- `DB_NAME=runmap_local`
- `DB_USER=runmap_user`
- `PGPASSWORD=fucker`
- Mac paths: `/Users/markchouinard/Development/GIS/runs-cdm`

**.env.production** (Ubuntu server):
- `DB_HOST=localhost` (PostgreSQL on same machine)
- `DB_NAME=runmap`
- `DB_USER=runmap_user`
- `PGPASSWORD=fucker`
- Server paths: `/home/mark/runmap`

**Important:** Never commit actual `.env` files to git! Only commit `.env.local`, `.env.production`, and `.env.example` templates.

## Database Setup

You have two options for setting up your local database:

### Option A: Import from Production (Recommended - Fastest)

This is the easiest way to get a fully populated local database with all your run data and street coverage.

**Step 1: Export from Production**

SSH into your production server and create a database dump:

```bash
# On production server
pg_dump -U runmap_user -d runmap -h localhost -Fc -f /tmp/runmap_backup.dump

# Check the file size
ls -lh /tmp/runmap_backup.dump
```

**Step 2: Download to Mac**

```bash
# On your Mac
scp mark@your-production-server:/tmp/runmap_backup.dump ~/Downloads/runmap_backup.dump

# Or if you have the dump elsewhere, move it to a convenient location
```

**Step 3: Create Local Database**

```bash
# Create database
psql -U postgres -h localhost -c "CREATE DATABASE runmap_local OWNER runmap_user;"

# Enable PostGIS extension (required before restore)
psql -U postgres -d runmap_local -h localhost -c "CREATE EXTENSION IF NOT EXISTS postgis;"

# Create user if needed (may already exist)
psql -U postgres -h localhost -c "CREATE USER runmap_user WITH PASSWORD 'fucker';" 2>/dev/null || true
```

**Step 4: Restore Production Dump**

```bash
# Restore the dump
pg_restore -U postgres -d runmap_local -h localhost --no-owner --role=runmap_user ~/Downloads/runmap_backup.dump

# You may see some permission warnings - these are safe to ignore:
# - "permission denied to create extension pgrouting" (not needed)
# - "permission denied for table spatial_ref_sys" (already exists)
# - "permission denied to change default privileges" (not critical for local dev)
```

**Step 5: Verify Import**

```bash
# Check that data was imported
psql -U runmap_user -d runmap_local -h localhost << 'EOF'
SELECT
  'runs_raw' as table_name,
  COUNT(*) as row_count
FROM runmap.runs_raw
UNION ALL
SELECT
  'streets_blocks_32610',
  COUNT(*)
FROM runmap.streets_blocks_32610
UNION ALL
SELECT
  'block_segments',
  COUNT(*)
FROM runmap.block_segments;
EOF

# Check coverage stats
psql -U runmap_user -d runmap_local -h localhost -c "SELECT * FROM runmap.coverage_stats_blocks;"
```

You should see hundreds of runs and thousands of street blocks. If tables are empty, the restore may have failed.

**Step 6: Generate Tiles Locally**

```bash
cd /Users/markchouinard/Development/GIS/runs-cdm

# Generate tiles from your local database
bash scripts/export_tiles_blocks.sh

# Tiles will be created in tiles/*.pmtiles
ls -lh tiles/*.pmtiles
```

The tiles may take 30-60 seconds to appear in the frontend after generation due to browser caching.

### Option B: Build from Scratch (Advanced)

Only use this if you want a fresh database or can't access production.

**Step 1: Create Local Database**

```bash
# Create database
createdb -U postgres runmap_local

# Enable PostGIS extension
psql -U postgres -d runmap_local -c "CREATE EXTENSION IF NOT EXISTS postgis;"
psql -U postgres -d runmap_local -c "CREATE SCHEMA IF NOT EXISTS runmap;"

# Create user (if needed)
psql -U postgres -d runmap_local -c "CREATE USER runmap_user WITH PASSWORD 'fucker';"
psql -U postgres -d runmap_local -c "GRANT ALL PRIVILEGES ON DATABASE runmap_local TO runmap_user;"
psql -U postgres -d runmap_local -c "GRANT ALL ON SCHEMA runmap TO runmap_user;"
```

**Step 2: Load Database Schema**

**IMPORTANT:** SQL files must be run in the correct order due to dependencies.

```bash
cd /Users/markchouinard/Development/GIS/runs-cdm

# Step 1: Core tables
psql -U runmap_user -d runmap_local -h localhost -f db/01_create_tables.sql

# Step 2: Import street data from OSM (required before next steps)
# You need OSM data loaded into runmap.streets_reference first
# See CLAUDE.md for OSM import instructions

# Step 3: Create streets_blocks_32610 (REQUIRED before segment schema!)
psql -U runmap_user -d runmap_local -h localhost -f db/04_phase1_intersection_split.sql

# Step 4: Segment-visited schema (depends on streets_blocks_32610)
psql -U runmap_user -d runmap_local -h localhost -f db/04_segment_schema.sql

# Step 5: Additional activity tables (walks, cycling)
psql -U runmap_user -d runmap_local -h localhost -f db/12_activity_tables.sql

# Step 6: Location tracking
psql -U runmap_user -d runmap_local -h localhost -f db/13_location_tracking.sql

# Step 7: Workout hash deduplication
psql -U runmap_user -d runmap_local -h localhost -f db/14_workout_hash_migration.sql

# Step 8: Route naming
psql -U runmap_user -d runmap_local -h localhost -f db/15_add_route_name.sql

# Step 9: Create views
psql -U runmap_user -d runmap_local -h localhost -f db/02_create_views.sql

# Step 10: Utility views
psql -U runmap_user -d runmap_local -h localhost -f db/05_utility_views.sql
```

**Step 3: Initialize Coverage Tracking**

After importing OSM streets, you need to initialize the segment-visited coverage system:

```bash
# Generate street blocks (split streets at intersections)
psql -U runmap_user -d runmap_local -h localhost << 'EOF'
SELECT runmap.split_streets_at_intersections();
EOF

# Generate 5m segments for coverage tracking
psql -U runmap_user -d runmap_local -h localhost << 'EOF'
-- Create 5m segments for all blocks
INSERT INTO runmap.block_segments (block_id, segment_geom, segment_length_m)
SELECT
  b.block_id,
  (ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom AS segment_geom,
  ST_Length((ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom) AS segment_length_m
FROM runmap.streets_blocks_32610 b;

-- Initialize visited flags (all FALSE initially)
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE
FROM runmap.block_segments;

-- Initialize aggregate coverage (all 0% initially)
INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
SELECT
  block_id,
  0,
  SUM(segment_length_m)
FROM runmap.block_segments
GROUP BY block_id;
EOF
```

## Common Import Issues

### DataGrip Export/Import

**Don't use DataGrip's "Export to Files" → "Run SQL Script" method!** This creates a text representation of the data rather than actually populating tables. You'll end up with a table named something like `runmapremote_2025_12_23_17_29_33_dump` with all your data as text.

**Always use `pg_dump` and `pg_restore`** for database migration. These are the standard PostgreSQL tools and handle all data types, indexes, and constraints correctly.

### Permission Errors During Restore

When running `pg_restore`, you may see these errors - **all are safe to ignore**:

- `ERROR: must be owner of extension postgis` - Just a comment, doesn't affect functionality
- `ERROR: permission denied to create extension "pgrouting"` - Not needed by the app
- `ERROR: permission denied for table spatial_ref_sys` - Already populated by PostGIS
- `ERROR: permission denied to change default privileges` - Not critical for local dev
- `ERROR: constraint "X" already exists` - Harmless, constraint was created earlier

As long as you see data in the tables (check with the verify command above), the import succeeded.

## Flask API Setup

```bash
cd api

# Create virtual environment
python3 -m venv venv

# Activate virtual environment
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Ensure .env symlink exists
ln -sf .env.local .env

# Run development server
flask run --debug
```

The Flask app will automatically use the local database (`runmap_local`) based on `api/.env.local`.

## React Frontend Setup

```bash
cd web

# Install dependencies
npm install

# Run development server (with hot reload)
npm run dev

# Build for production
npm run build
```

## Testing Scripts Locally

All scripts in `scripts/` will automatically use your local database when run on the Mac Studio:

```bash
# Process a GPX file locally
bash scripts/ingest_gpx.sh /path/to/run.gpx

# Export tiles locally
bash scripts/export_tiles_blocks.sh
```

The scripts use `scripts/common/env.sh` which loads from `.env` (symlinked to `.env.local`), so they automatically use:
- `DB_HOST=localhost`
- `DB_NAME=runmap_local`
- Local Mac paths

## Deployment to Production

When you're ready to deploy to the Ubuntu server:

```bash
# Deploy everything (rebuilds React, copies files, restarts services)
bash scripts/deploy.sh

# Deploy with tiles (if you generated them locally)
bash scripts/deploy.sh --tiles

# Deploy with updated dependencies
bash scripts/deploy.sh --deps

# Deploy everything including tiles and deps
bash scripts/deploy.sh --all
```

The deploy script automatically:
1. Copies `.env.production` → `.env` on the server
2. Copies `api/.env.production` → `api/.env` on the server
3. Deploys code, builds, scripts
4. Restarts services

## Troubleshooting

### Tiles not appearing in the frontend

After running `scripts/export_tiles_blocks.sh`, tiles may take 30-60 seconds to appear due to:

1. **Browser cache** - The frontend aggressively caches tiles
2. **MapLibre loading** - Tile layers load asynchronously
3. **Tile version polling** - Frontend polls `/api/tiles/version` every few seconds

**Solutions:**
- Wait 30-60 seconds and refresh the page
- Hard refresh: Cmd+Shift+R (Chrome/Firefox) or Cmd+Option+E then Cmd+R (Safari)
- Open DevTools → Network → Check "Disable cache" and refresh
- Check that tiles were actually generated: `ls -lh tiles/*.pmtiles`
- Verify tile modification times match when you ran the export script

If tiles still don't appear, check the browser console for errors and verify the Flask API is serving tile requests.

### Scripts fail with "DB not found"

Make sure you created the symlink:
```bash
ln -sf .env.local .env
```

### "relation does not exist" errors in SQL

You're running SQL files out of order. See "Option B: Build from Scratch" section above for the correct order.

### API can't connect to database

Check `api/.env` is symlinked to `api/.env.local`:
```bash
cd api
ls -la .env
# Should show: .env -> .env.local
```

### Scripts use production database instead of local

Your `.env` symlink might be pointing to the wrong file:
```bash
ls -la .env
# Should show: .env -> .env.local

# Fix it:
rm .env
ln -sf .env.local .env
```

### Empty tables after pg_restore

If `runs_raw` and other tables are empty after running `pg_restore`, the dump file may not have been created correctly. Verify:

```bash
# Check dump file size (should be several MB)
ls -lh ~/Downloads/runmap_backup.dump

# Re-run the export from production with verbose output
pg_dump -U runmap_user -d runmap -h localhost -Fc -v -f /tmp/runmap_backup.dump
```

## Cleaning Up Obsolete Files

These files are obsolete and can be removed:
- `.env.staging` - old staging environment (no longer used)

## Summary

**Local Development (Mac Studio):**
- Database: `runmap_local` on localhost
- Environment: `.env` → `.env.local`
- API: `api/.env` → `api/.env.local`
- Scripts automatically use local DB

**Production (Ubuntu Server):**
- Database: `runmap` on localhost (same machine)
- Environment: `deploy.sh` copies `.env.production` → `.env`
- API: `deploy.sh` copies `api/.env.production` → `api/.env`
- Scripts automatically use production DB

**Key principle:** Scripts and apps detect environment by reading `.env`, which points to different configs based on where it's running.
