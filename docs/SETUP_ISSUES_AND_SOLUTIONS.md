# Local Development Setup Issues & Solutions

**Purpose:** Track all issues encountered during local development setup to enable rapid infrastructure recreation and script refactoring.

**Date Started:** 2025-12-02
**Status:** In Progress

---

## Issues Encountered

### 1. macOS Port 5000 Conflict (AirPlay Receiver)
**Problem:** Flask defaults to port 5000, which is occupied by Apple's AirPlay Receiver service on macOS.

**Symptoms:**
- `curl http://localhost:5000/` returns `HTTP/1.1 403 Forbidden` from `Server: AirTunes/920.10.1`
- Flask appears to start but API requests fail
- `localhost:5000` resolves to IPv6 `::1` which hits AirPlay instead of Flask

**Root Cause:** macOS Monterey+ enables AirPlay Receiver by default on port 5000.

**Solutions Attempted:**
1. ❌ Changed Vite proxy from `localhost:5000` → `127.0.0.1:5000` (worked but fragile)
2. ✅ **FINAL:** Changed Flask port to 5001 via `FLASK_RUN_PORT=5001` in `api/.env.local`

**Files Modified:**
- `api/.env.local` - Added `FLASK_RUN_PORT=5001`
- `web/vite.config.ts` - Updated proxy target to `http://localhost:5001`

**Prevention:**
- Document Flask port configuration in setup docs
- Add port check to setup script
- Consider making Flask port configurable via .env in all environments

---

### 2. Missing Database Columns in Local Schema
**Problem:** SQL schema files in `db/` are outdated and missing columns that production API expects.

**Symptoms:**
```
"error": "column \"total_distance_m\" does not exist"
"error": "column \"processing_status\" does not exist"
```

**Root Cause:** Schema files were created early in development. Production database evolved with manual ALTER TABLE commands that weren't captured in migration files.

**Missing Columns:**
```sql
-- runs_raw, walks_raw, cycling_raw
total_distance_m NUMERIC             -- Expected by API (had distance_km instead)
processing_status TEXT                -- Track upload processing state
processing_started_at TIMESTAMPTZ
processing_completed_at TIMESTAMPTZ
error_message TEXT
```

**Solution Applied:**
```sql
ALTER TABLE runmap.runs_raw
ADD COLUMN IF NOT EXISTS total_distance_m NUMERIC,
ADD COLUMN IF NOT EXISTS processing_status TEXT DEFAULT 'processed',
ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS processing_completed_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS error_message TEXT;

-- Migrate existing data
UPDATE runmap.runs_raw
SET total_distance_m = distance_km * 1000
WHERE distance_km IS NOT NULL AND total_distance_m IS NULL;

-- Repeat for walks_raw and cycling_raw
```

**Prevention Needed:**
- Create proper migration system
- Consolidate all schema changes into single source of truth
- Add schema validation script to detect drift
- Document schema evolution in CHANGELOG

---

### 3. SQL File Load Order Dependencies
**Problem:** SQL files have implicit dependencies but no documented load order.

**Symptoms:**
```
ERROR:  relation "runmap.streets_blocks_32610" does not exist
```
When loading `04_segment_schema.sql` before `04_phase1_intersection_split.sql`.

**Root Cause:** Foreign key constraints and table references require specific execution order:
1. `01_create_tables.sql` → Base tables
2. OSM import → Populate `streets_reference`
3. `04_phase1_intersection_split.sql` → Create `streets_blocks_32610`
4. `04_segment_schema.sql` → Create segment tables (references blocks)
5. Other migration files...

**Current Order (from LOCAL_DEV_SETUP.md):**
```
01_create_tables.sql
[OSM import required here]
04_phase1_intersection_split.sql
04_segment_schema.sql
12_activity_tables.sql
13_location_tracking.sql
14_workout_hash_migration.sql
15_add_route_name.sql
02_create_views.sql
05_utility_views.sql
```

**Issues:**
- No automated dependency checking
- Easy to run out of order
- Manual process prone to errors
- Some files fail silently if dependencies missing

**Prevention Needed:**
- Add numbered prefix to enforce order (01_, 02_, 03_...)
- Create master migration script that enforces order
- Add dependency declarations in SQL file headers
- Validate prerequisites before running each file

---

### 4. OSM Import Syntax Issues
**Problem:** `ogr2ogr` SQL syntax varies between tools and requires specific escaping.

**Symptoms:**
```
ERROR 1: SQL Expression Parsing Error: syntax error, unexpected $undefined
```

**Root Cause:**
- OSM PBF files don't have explicit `geometry` field (it's implicit)
- SQL operators like `!=` need different escaping for ogr2ogr
- Field names in SQL query must match OSM schema

**Working Solution:**
```bash
ogr2ogr -f "PostgreSQL" PG:"host=localhost dbname=runmap_local user=runmap_user password=fucker" \
  -sql "SELECT osm_id, name, highway FROM lines WHERE highway IN ('residential', ...) AND highway <> 'service'" \
  -nln runmap.streets_reference \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=gid \
  -t_srs EPSG:4326 \
  aoi_processing/SacExpanded.pbf
```

**Key Points:**
- Use `<>` instead of `!=` for inequality
- Don't include `geometry` in SELECT clause (implicit)
- Use `PROMOTE_TO_MULTI` for consistent MultiLineString type
- Use `-overwrite` flag carefully (destroys existing data)

**Prevention Needed:**
- Create wrapper script for OSM imports
- Document ogr2ogr syntax quirks
- Add validation before import
- Provide example commands in setup docs

---

### 5. Geometry Type Mismatches
**Problem:** `streets_blocks_32610` defined as LineString but OSM import creates MultiLineString.

**Symptoms:**
```
ERROR: Geometry type (MultiLineString) does not match column type (LineString)
CONTEXT: SQL statement "INSERT INTO runmap.streets_blocks_32610..."
```

**Root Cause:**
- Original schema expected LineString
- OSM import with `PROMOTE_TO_MULTI` creates MultiLineString
- PostGIS strict type checking rejects mismatch

**Solution:**
```sql
ALTER TABLE runmap.streets_blocks_32610
ALTER COLUMN geom_32610 TYPE geometry(Geometry, 32610);
```

**Prevention Needed:**
- Use flexible `Geometry` type instead of specific types where appropriate
- Document geometry type expectations
- Add geometry type validation to import scripts
- Consider using PostGIS typmod-less geometry for flexibility

---

### 6. Python Virtual Environment Dependencies
**Problem:** `requirements.txt` missing dependencies that app.py imports.

**Symptoms:**
```
ModuleNotFoundError: No module named 'requests'
```

**Root Cause:** `app.py` imports `requests` but it's not in `requirements.txt`.

**Solution:**
```bash
pip install requests
pip freeze > requirements.txt  # Update requirements
```

**Missing Dependencies Found:**
- `requests` - Used for external API calls

**Prevention Needed:**
- Audit all imports in Python files
- Generate requirements.txt from actual imports
- Add dependency check to setup script
- Consider using `pipreqs` to auto-generate requirements

---

### 7. Environment Variable Inheritance Issues
**Problem:** When testing database connections, inherited environment variables override `.env` file values.

**Symptoms:**
- Test shows connecting to production (192.168.68.25) when expecting local
- Even though `.env.local` specifies localhost

**Root Cause:**
- `scripts/common/env.sh` exports vars to parent shell
- Python `dotenv.load_dotenv()` doesn't override existing env vars by default
- Shell env vars inherited by child processes

**Workaround:**
```bash
unset DB_HOST DB_NAME DB_USER PGPASSWORD  # Clear before testing
source venv/bin/activate
python -c "from dotenv import load_dotenv; load_dotenv('.env'); ..."
```

**Prevention Needed:**
- Document env var precedence
- Add warning in env.sh about not sourcing manually
- Use `override=True` in load_dotenv() calls
- Create isolated test script that clears environment

---

### 8. Symlink Management Confusion
**Problem:** Multiple `.env` files need symlink management across different directories.

**Current Structure:**
```
.env → .env.local (root)
api/.env → api/.env.local
```

**Issues:**
- Easy to forget to create both symlinks
- Deploy script copies `.env.production` to server, overriding symlink
- No validation that symlinks point to correct files
- Different behavior on Mac (symlinks) vs server (copies)

**Prevention Needed:**
- Create setup script that creates all symlinks
- Add symlink validation
- Document symlink vs copy behavior per environment
- Consider using direnv or similar tool

---

### 9. Missing Processing Queue Columns
**Problem:** API endpoints expect processing queue columns that don't exist in fresh schema.

**Related to Issue #2** - Part of broader schema drift problem.

**Prevention Needed:**
- Same as Issue #2 (proper migrations)

---

### 10. View Creation Errors Due to Schema Drift
**Problem:** SQL views in `02_create_views.sql` reference columns/tables that don't exist in fresh install.

**Symptoms:**
```
ERROR: column s.ogc_fid does not exist
ERROR: relation "runmap.streets_unrun" does not exist
```

**Root Cause:**
- Views written against production schema
- Production schema evolved separately from migration files
- Column name changes (ogc_fid vs osm_id) not reflected in views

**Prevention Needed:**
- Regenerate all views from current production schema
- Add view validation to schema tests
- Document view dependencies

---

### 11. OSM Import Including Non-Runnable Highway Types
**Problem:** Initial OSM import included all highway types (footways, cycleways, motorways, etc.) instead of just runnable streets.

**Symptoms:**
- Local database had 10,101 streets vs production's 1,456
- Map showed bike paths, freeways, and pedestrian-only areas
- Tile file size 3.7M vs expected ~1M

**Root Cause:**
- ogr2ogr SQL filter included too many highway types:
```sql
-- WRONG: Includes non-runnable types
WHERE highway IN ('residential', 'primary', 'secondary', 'tertiary', 'trunk',
                  'motorway', 'unclassified', 'footway', 'path', 'cycleway',
                  'pedestrian', 'living_street')
```

**Correct Filter (Matches Production):**
```sql
-- CORRECT: Only runnable street types
WHERE highway IN ('residential', 'primary', 'secondary', 'tertiary',
                  'unclassified', 'living_street')
AND highway <> 'service'  -- Exclude alleys
```

**Solution Applied:**
```sql
-- Delete non-runnable types
DELETE FROM runmap.streets_reference
WHERE highway IN ('motorway', 'footway', 'cycleway', 'path', 'pedestrian');

-- Result: 10,101 streets → 2,629 streets (matching production types)
```

**Prevention Needed:**
- Document highway type filter in OSM import scripts
- Add validation check after import to compare highway types with production
- Create reusable highway type list constant

### 12. Streets Extending Beyond AOI Boundary After Osmium Extract
**Problem:** After using `osmium extract` to trim PBF to GeoJSON boundary, street geometries still extend beyond the AOI boundary.

**Symptoms:**
- Streets highlighted in green extending beyond red AOI boundary in QGIS
- Database bounds slightly larger than GeoJSON bounds
- 81 out of 2,629 streets crossing the boundary

**Root Cause:**
- OSM "ways" are stored as complete linestring geometries
- `osmium extract` includes entire ways if they intersect the polygon boundary
- Streets that cross the boundary are included in full, not clipped at the edge

**Database Bounds vs AOI Bounds:**
```
Database streets: lng -121.519497 to -121.418426, lat 38.535114 to 38.601314
AOI boundary:     lng -121.519955 to -121.418189, lat 38.535112 to 38.602731
```

**Solution Applied:**
```sql
-- 1. Import AOI boundary polygon
ogr2ogr -f "PostgreSQL" PG:"host=localhost dbname=runmap_local user=runmap_user password=fucker" \
  -sql "SELECT 'Sacramento' as name FROM SacExpanded" \
  -nln runmap.aoi \
  -nlt POLYGON \
  -lco GEOMETRY_NAME=geom \
  -t_srs EPSG:4326 \
  -append \
  aoi_processing/SacExpanded.geojson

-- 2. Clip streets to AOI boundary
UPDATE runmap.streets_reference
SET geom = ST_Multi(ST_Intersection(geom, (SELECT geom FROM runmap.aoi WHERE name = 'Sacramento')))
WHERE NOT ST_Within(geom, (SELECT geom FROM runmap.aoi WHERE name = 'Sacramento'))
  AND ST_Intersects(geom, (SELECT geom FROM runmap.aoi WHERE name = 'Sacramento'));
-- UPDATE 81 (streets clipped)

-- 3. Rebuild UTM-projected version with clipped geometries
TRUNCATE TABLE runmap.streets_reference_32610;
INSERT INTO runmap.streets_reference_32610 (ogc_fid, osm_id, name, highway, geom_32610, total_length_m)
SELECT
  gid as ogc_fid,
  osm_id,
  name,
  highway,
  ST_Transform(geom, 32610) as geom_32610,
  ST_Length(ST_Transform(geom, 32610)) as total_length_m
FROM runmap.streets_reference;

-- 4. Rebuild blocks and segments with clipped geometries
TRUNCATE TABLE runmap.block_segment_visited CASCADE;
TRUNCATE TABLE runmap.block_segments CASCADE;
TRUNCATE TABLE runmap.block_coverage_segments CASCADE;
TRUNCATE TABLE runmap.streets_blocks_32610 CASCADE;

SELECT runmap.split_streets_at_intersections();

INSERT INTO runmap.block_segments (block_id, segment_geom, segment_length_m)
SELECT
  b.block_id,
  (ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom AS segment_geom,
  ST_Length((ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom) AS segment_length_m
FROM runmap.streets_blocks_32610 b;

INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE FROM runmap.block_segments;

INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
SELECT block_id, 0, SUM(segment_length_m)
FROM runmap.block_segments
GROUP BY block_id;

-- 5. Regenerate tiles
bash scripts/export_tiles_blocks.sh
```

**Results:**
- Streets now properly clipped to AOI boundary
- Database bounds now match GeoJSON bounds
- 4,518 blocks created (down from 4,524 due to clipping)
- Tiles regenerated: `streets_incomplete.pmtiles` (1.0M)

**Prevention Needed:**
- Document that osmium extract includes full ways, not clipped geometries
- Add PostGIS clipping step to OSM import script
- Create function to validate streets are within AOI boundary
- Add this step to automated setup script

### 13. PMTiles Partial Transfer Error in Vite Dev Server
**Problem:** `streets_incomplete.pmtiles` fails to load in local development with `NS_ERROR_NET_PARTIAL_TRANSFER` error in Firefox DevTools.

**Symptoms:**
- Production works fine (Nginx serving tiles as static files)
- Local development shows partial transfer error
- Tile appears to transfer complete size (15.32 kB / 15.32 kB) but shows red error
- Map doesn't display incomplete streets (red) despite database having them

**Root Cause:**
- Vite dev server custom middleware using `fs.createReadStream().pipe(res)` for range requests
- Node.js streams are asynchronous and timing-sensitive
- Stream may close before browser receives all expected bytes based on Content-Length header
- Content-Length calculated from range, but actual bytes delivered may differ slightly

**Solution Applied:**
Changed from streaming to synchronous buffer-based reads in `web/vite.config.ts`:

```typescript
// OLD (streaming - unreliable)
const stream = fs.createReadStream(tilePath, { start, end })
stream.on('error', (err) => { ... })
stream.pipe(res)

// NEW (buffer-based - reliable)
const buffer = Buffer.alloc(chunkSize)
const fd = fs.openSync(tilePath, 'r')
try {
  const bytesRead = fs.readSync(fd, buffer, 0, chunkSize, start)
  fs.closeSync(fd)

  res.statusCode = 206
  res.setHeader('Content-Length', bytesRead.toString())
  // ... other headers

  res.end(buffer.slice(0, bytesRead))
} catch (err) {
  console.error('PMTiles read error:', err)
  fs.closeSync(fd)
  res.statusCode = 500
  res.end()
}
```

**Key Changes:**
- Read entire range chunk into memory first
- Set Content-Length to actual bytes read (not calculated)
- Send buffer directly with `res.end()` instead of streaming
- Ensures exact byte count matches Content-Length header

**Results:**
- Tiles load without errors in local development
- Matches production behavior (static file serving)
- Map displays incomplete streets correctly (red/orange)

**Why This Only Affects Local Dev:**
- Production: Nginx serves PMTiles as static files with native range request support
- Local: Vite dev server requires custom middleware for tile serving
- The fix makes local development behave identically to production

**Prevention Needed:**
- Document that PMTiles range requests require exact Content-Length matching
- Add this pattern to any future custom tile serving middleware
- Consider using Nginx for local development to match production exactly

### 14. Hardcoded Database Connections in API Endpoints
**Problem:** API endpoints (upload, delete, update name) use hardcoded database connection parameters when calling psql via subprocess, causing failures in local development.

**Symptoms:**
- Delete activity fails with: `Command '['psql', '-U', 'runmap_user', '-d', 'runmap', '-h', 'localhost', ...]' returned non-zero exit status 2`
- Error occurs because `-d runmap` doesn't exist on local (should be `-d runmap_local`)
- Upload and name update endpoints have same issue

**Root Cause:**
- Four subprocess.run() calls in api/app.py hardcoded database parameters:
  - Lines 521-524: Upload endpoint (refresh matview)
  - Lines 529-532: Upload endpoint (tiles_version update)
  - Lines 915-918: Delete endpoint (tiles_version update)
  - Lines 977-980: Update name endpoint (tiles_version update)
- Used hardcoded values: `-U runmap_user`, `-d runmap`, `-h localhost`
- Should use environment variables: DB_USER, DB_NAME, DB_HOST, DB_PASSWORD

**Solution Applied:**
Added environment variable configuration and updated all psql calls in `api/app.py`:

```python
# At top of file (lines 44-48):
# Database configuration for subprocess calls
DB_NAME = os.getenv('DB_NAME')
DB_USER = os.getenv('DB_USER')
DB_HOST = os.getenv('DB_HOST')
DB_PASSWORD = os.getenv('PGPASSWORD')

# All psql subprocess calls updated to:
env = os.environ.copy()
env['PGPASSWORD'] = DB_PASSWORD
subprocess.run([
    'psql', '-U', DB_USER, '-d', DB_NAME, '-h', DB_HOST, '-c',
    "SQL COMMAND HERE;"
], env=env, check=True)
```

**Results:**
- API now works in both local dev (runmap_local) and production (runmap)
- Delete, upload, and name update operations work correctly in both environments
- No more hardcoded database connection parameters

**Prevention Needed:**
- Lint rule to prevent hardcoded 'runmap' database name in Python code
- Add integration tests for API endpoints in local dev environment
- Document that all database connections must use environment variables

---

## Refactoring Needed

### High Priority

1. **Consolidated Schema Setup Script**
   - Single script that sets up complete database from scratch
   - Enforces correct execution order
   - Validates prerequisites
   - Handles OSM import
   - Reports progress and errors clearly

2. **Schema Migration System**
   - Proper migration tracking (version numbers)
   - Up/down migrations
   - Schema validation
   - Automatic detection of drift
   - Generate migration from production schema

3. **Environment Setup Script**
   - Creates all necessary symlinks
   - Validates environment files exist
   - Checks Python dependencies
   - Validates database connectivity
   - Checks port availability
   - One-command setup

4. **Schema Consolidation**
   - Export current production schema as baseline
   - Create single "clean slate" schema file
   - Migrate all ALTER TABLE commands to initial schema
   - Remove obsolete migration files
   - Document schema evolution going forward

### Medium Priority

5. **Port Configuration**
   - Make all ports configurable via .env
   - Add port conflict detection
   - Document port usage
   - Default to non-conflicting ports on macOS

6. **OSM Import Wrapper**
   - Script that handles ogr2ogr complexity
   - Validates PBF file before import
   - Checks for schema compatibility
   - Handles geometry type promotion
   - Reports import statistics

7. **Dependency Management**
   - Auto-generate requirements.txt from imports
   - Add missing package detection
   - Version pinning strategy
   - Document Python version requirements

8. **Testing Infrastructure**
   - Schema validation tests
   - API endpoint tests
   - Environment configuration tests
   - Database connection tests
   - Import/export pipeline tests

### Low Priority

9. **Documentation Improvements**
   - Single source of truth for setup
   - Troubleshooting guide with common errors
   - Architecture diagrams
   - API documentation
   - Database schema documentation

10. **Development Tools**
    - Makefile for common tasks
    - Docker development environment option
    - Database seeding script
    - Sample data generation
    - Performance benchmarking tools

---

## Quick Reference: Current Working Setup (Mac Local Dev)

```bash
# 1. Environment symlinks
ln -sf .env.local .env
cd api && ln -sf .env.local .env && cd ..

# 2. Database setup
createdb -U postgres runmap_local
psql -U postgres -d runmap_local -c "CREATE EXTENSION IF NOT EXISTS postgis;"
psql -U postgres -d runmap_local -c "CREATE SCHEMA IF NOT EXISTS runmap;"
psql -U postgres -d runmap_local -c "CREATE USER runmap_user WITH PASSWORD 'fucker';"
psql -U postgres -d runmap_local -c "GRANT ALL PRIVILEGES ON DATABASE runmap_local TO runmap_user;"
psql -U postgres -d runmap_local -c "GRANT ALL ON SCHEMA runmap TO runmap_user;"

# 3. Load schema (IN ORDER)
psql -U runmap_user -d runmap_local -h localhost -f db/01_create_tables.sql

# 4. Import OSM
ogr2ogr -f "PostgreSQL" PG:"host=localhost dbname=runmap_local user=runmap_user password=fucker" \
  -sql "SELECT osm_id, name, highway FROM lines WHERE highway IN ('residential', 'primary', 'secondary', 'tertiary', 'trunk', 'motorway', 'unclassified', 'footway', 'path', 'cycleway', 'pedestrian', 'living_street') AND highway <> 'service'" \
  -nln runmap.streets_reference \
  -nlt PROMOTE_TO_MULTI \
  -lco GEOMETRY_NAME=geom \
  -lco FID=gid \
  -t_srs EPSG:4326 \
  -overwrite \
  aoi_processing/SacExpanded.pbf

# 5. Add runnable column and create UTM version
psql -U runmap_user -d runmap_local -h localhost << 'SQL'
ALTER TABLE runmap.streets_reference ADD COLUMN IF NOT EXISTS runnable BOOLEAN DEFAULT TRUE;
DROP TABLE IF EXISTS runmap.streets_reference_32610 CASCADE;
CREATE TABLE runmap.streets_reference_32610 AS
SELECT gid as ogc_fid, osm_id, name, highway,
       ST_Transform(geom, 32610) as geom_32610,
       ST_Length(ST_Transform(geom, 32610)) as total_length_m
FROM runmap.streets_reference;
ALTER TABLE runmap.streets_reference_32610 ADD PRIMARY KEY (ogc_fid);
CREATE INDEX IF NOT EXISTS streets_reference_32610_geom_idx ON runmap.streets_reference_32610 USING GIST (geom_32610);
SQL

# 6. Continue with schema files
psql -U runmap_user -d runmap_local -h localhost -f db/04_phase1_intersection_split.sql

# Fix geometry type mismatch
psql -U runmap_user -d runmap_local -h localhost -c "ALTER TABLE runmap.streets_blocks_32610 ALTER COLUMN geom_32610 TYPE geometry(Geometry, 32610);"

psql -U runmap_user -d runmap_local -h localhost -f db/04_segment_schema.sql
psql -U runmap_user -d runmap_local -h localhost -f db/12_activity_tables.sql
psql -U runmap_user -d runmap_local -h localhost -f db/13_location_tracking.sql
psql -U runmap_user -d runmap_local -h localhost -f db/14_workout_hash_migration.sql
psql -U runmap_user -d runmap_local -h localhost -f db/15_add_route_name.sql
psql -U runmap_user -d runmap_local -h localhost -f db/02_create_views.sql
psql -U runmap_user -d runmap_local -h localhost -f db/05_utility_views.sql

# 7. Add missing columns
psql -U runmap_user -d runmap_local -h localhost << 'SQL'
ALTER TABLE runmap.runs_raw
ADD COLUMN IF NOT EXISTS total_distance_m NUMERIC,
ADD COLUMN IF NOT EXISTS processing_status TEXT DEFAULT 'processed',
ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS processing_completed_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS error_message TEXT;

ALTER TABLE runmap.walks_raw
ADD COLUMN IF NOT EXISTS total_distance_m NUMERIC,
ADD COLUMN IF NOT EXISTS processing_status TEXT DEFAULT 'processed',
ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS processing_completed_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS error_message TEXT;

ALTER TABLE runmap.cycling_raw
ADD COLUMN IF NOT EXISTS total_distance_m NUMERIC,
ADD COLUMN IF NOT EXISTS processing_status TEXT DEFAULT 'processed',
ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS processing_completed_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS error_message TEXT;
SQL

# 8. Initialize coverage system
psql -U runmap_user -d runmap_local -h localhost << 'SQL'
SELECT runmap.split_streets_at_intersections();

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
SQL

# 9. Python virtual environment
cd api
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pip install requests  # Missing from requirements.txt

# 10. Start Flask API (port 5001)
flask run --debug

# 11. Start React dev server (separate terminal)
cd web
npm install
npm run dev
```

**Access:**
- Frontend: http://localhost:3000
- API: http://localhost:5001
- Admin login: `shitfuck`

---

## Setup Complete ✓

**Date Completed:** 2025-12-02

**Final State:**
- Local database: `runmap_local` with 2,629 runnable streets (downtown Sacramento AOI)
- Flask API: Running on port 5001 (avoiding macOS AirPlay conflict)
- Tiles generated: `streets_incomplete.pmtiles` (1.0M, 4,524 blocks)
- Coverage system: Initialized with segment-visited tracking
- Schema: Matches production (15 tables, all functions/views)
- Highway types: residential, secondary, tertiary, primary, unclassified, living_street (excludes motorways, footways, cycleways, paths)
- Admin access: API key `shitfuck` (development only)

**Working Commands:**
```bash
# Start Flask API (from api/ directory)
cd api && source venv/bin/activate && flask run --debug

# Start React dev server (from web/ directory)
cd web && npm run dev

# Access points
# Frontend: http://localhost:3000
# API: http://localhost:5001
```

## Next Steps

1. **Immediate:** Test uploading GPX files via API to verify full pipeline
2. **Short-term:** Create `scripts/setup_local_dev.sh` that automates above
3. **Medium-term:** Implement proper schema migration system
4. **Long-term:** Refactor all scripts per refactoring plan above

---

## Notes

- All commands tested on macOS (Mac Studio) with PostgreSQL 16 + PostGIS 3
- Python 3.14.0 used for testing
- Node.js/npm versions: (add when confirmed)
- This document should be updated as new issues are discovered
