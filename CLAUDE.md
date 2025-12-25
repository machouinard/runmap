# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Documentation

**[📚 Master Documentation Index](docs/README.md)** - Complete documentation organized by topic and use case

## Quick Links

- **[Day-to-Day Usage Guide](docs/USAGE_GUIDE.md)** - How to upload runs, change settings, view stats
- **[Segment-Visited System](docs/SEGMENT_VISITED_MIGRATION.md)** ⭐ **Current coverage architecture** (migrated 2025-10-20)
- **[Testing Workflow](docs/TESTING_WORKFLOW.md)** - Fast iteration for development (separate import from processing)
- **[Archived Systems](docs/archive/)** - Previous coverage approaches (incremental, block-percentage)

## Project Overview

RunMap is a geospatial web application for tracking running coverage across Sacramento streets. It processes GPX tracks using PostGIS, calculates incremental street coverage, and serves interactive vector map tiles.

**Key Innovation:** Segment-visited coverage system - uses binary visited flags instead of geometry unions, enabling constant-time processing (~0.4s/run) regardless of total run count. 67x faster than previous approaches.

## Architecture

- **Database:** PostgreSQL 16 + PostGIS 3 (incremental coverage state, per-run buffers)
- **API:** Flask (Python) - GPX upload, tile version management
- **Frontend:** React + MapLibre GL JS + PMTiles
- **Tiles:** PMTiles vector tiles (runs, coverage buffer, streets by status)
- **Processing:** GDAL/OGR, Tippecanoe
- **Server:** Nginx (reverse proxy + static files + tile serving)

## Database Schema

**Coordinate Systems:**
- Storage: EPSG:4326 (WGS84)
- Buffering/calculations: EPSG:32610 (UTM Zone 10N) for accurate meter-based operations
- Display: EPSG:3857 (Web Mercator)

**Core Tables:**

`runmap.runs_raw` - Individual GPX tracks (MultiLineString, 4326)
- Fields: `id` (UUID), `filename`, `uploaded_at`, `geom`, `workout_hash`, `location` (sacramento/portland/other), `total_distance_m`, `duration_seconds`, `start_time`
- Never deleted (immutable history)
- Location auto-detected via `detect_location()` function on insert
- **Deduplication:** `workout_hash` = SHA256(start_time rounded to 10-min bucket)
  - Example: Run at 16:47:19 → bucket "2025-10-19 16:40"
  - Detects same workout from different apps (WorkoutDoors, Apple Health, Strava)
  - Unique constraint prevents duplicate uploads

`runmap.streets_reference` - OSM street network baseline (LineString, 4326)
- Fields: `gid`, `osm_id`, `name`, `highway`, `geom`, `runnable`
- Excludes `highway = 'service'` (alleys not tracked)

`runmap.streets_reference_32610` - UTM-projected streets with precomputed lengths
- Fields: `ogc_fid`, `name`, `highway`, `geom_32610`, `total_length_m`
- Regenerated when baseline changes

`runmap.streets_blocks_32610` - Street blocks for coverage tracking
- Fields: `block_id`, `name`, `highway`, `geom_32610`, `block_length_m`
- Blocks are groups of connected street segments split at intersections
- Used instead of individual streets for more granular coverage

`runmap.runs_buffered_subdiv` - Subdivided run buffers (Polygon, 32610)
- Fields: `run_id`, `geom` (multiple polygons per run)
- Buffers subdivided with ST_Subdivide for faster intersection tests
- Multiple smaller polygons instead of one large polygon per run

`runmap.block_segments` - Pre-segmented 5m street pieces (LineString, 32610)
- Fields: `segment_id`, `block_id`, `segment_geom`, `segment_length_m`
- One-time computation: streets divided into ~5m pieces
- Enables granular coverage tracking without runtime segmentation

`runmap.block_segment_visited` - Binary visited flags for segments
- Fields: `segment_id`, `visited` (boolean)
- **Core optimization:** Just mark TRUE/FALSE, no geometry unions
- Constant-time updates regardless of run count

`runmap.block_coverage_segments` - Aggregate coverage per block
- Fields: `block_id`, `visited_length_m`, `total_length_m`, `coverage_pct`
- Computed from count of visited segments
- `coverage_pct` = (visited_length_m / total_length_m) × 100

`runmap.performance_log` - Performance tracking
- Fields: `id`, `logged_at`, `operation`, `run_count`, `avg_seconds`, `total_seconds`, `optimization`, `notes`
- Tracks optimization results and performance metrics

`runmap.processing_errors` - Error log for failed processing
- Tracks runs that failed to process with error details

`runmap.walks_raw` - Walking activity tracks (MultiLineString, 4326)
- Same schema as `runs_raw`, different activity type

`runmap.cycling_raw` - Cycling activity tracks (MultiLineString, 4326)
- Same schema as `runs_raw`, different activity type

`runmap.aoi` - Areas of Interest (Polygon, 4326)
- Contains Sacramento AOI boundary for coverage tracking
- **Note:** Location detection (`detect_location()`) uses hardcoded coordinates, not this table

`runmap.settings` - Configuration (JSONB key-value)
- `buffer_distance_m`: GPS buffer radius (default: 20m)
- `completion_threshold_pct`: Coverage % to mark block as complete (default: 90)
- `tiles_version`: Cache-busting timestamp

**Views:**

`runmap.streets_unrun` - Blocks with <5% coverage (orange on map) - hardcoded threshold
`runmap.streets_partial` - Blocks with 5% to completion threshold (orange on map) - uses `get_completion_threshold()`
`runmap.streets_complete` - Blocks ≥ completion threshold (green on map) - uses `get_completion_threshold()`

**Note:** Despite the "streets_" prefix, these views operate on blocks (`streets_blocks_32610`), not individual street segments. They query `block_coverage_segments` from the segment-visited system. The completion threshold is configurable via `completion_threshold_pct` setting (default: 90%).

**Materialized Views:**

`runmap.coverage_stats_blocks` - Overall coverage statistics

**Critical Functions:**

`runmap.buffer_one_run_subdiv(run_id)` - Creates 20m buffer and subdivides for fast intersection
`runmap.apply_run_to_segments(run_id)` - Marks segments as visited (constant-time operation)
`runmap.auto_process_new_run_segments()` - Trigger function that processes new runs automatically
`runmap.cleanup_coverage_on_delete()` - Trigger function that recalculates coverage when runs deleted
`runmap.detect_location(geom)` - Returns 'sacramento', 'portland', or 'other' based on centroid coordinates
`runmap.get_buffer_distance()` - Returns current buffer distance from settings
`runmap.get_completion_threshold()` - Returns completion threshold % from settings (default: 90)

## Common Commands

### Database Operations

```bash
# Connect to database
psql -U runmap_user -d runmap -h localhost

# Initial schema setup (fresh database)
psql -U runmap_user -d runmap -h localhost -f db/01_create_tables.sql
psql -U runmap_user -d runmap -h localhost -f db/04_segment_schema.sql
# Note: Triggers are created automatically by 04_segment_schema.sql

# Check coverage stats
psql -U runmap_user -d runmap -h localhost -c "SELECT * FROM runmap.coverage_stats_blocks;"

# Get distance totals by location
psql -U runmap_user -d runmap -h localhost << 'EOF'
SELECT
  location,
  COUNT(*) as num_runs,
  ROUND((SUM(total_distance_m) / 1609.34)::numeric, 2) as total_miles,
  ROUND((AVG(total_distance_m) / 1609.34)::numeric, 2) as avg_miles_per_run
FROM runmap.runs_raw
WHERE total_distance_m IS NOT NULL
GROUP BY location
ORDER BY location;
EOF

# Sacramento-only distance totals
psql -U runmap_user -d runmap -h localhost << 'EOF'
SELECT
  COUNT(*) as total_runs,
  ROUND((SUM(total_distance_m) / 1609.34)::numeric, 2) as total_miles
FROM runmap.runs_raw
WHERE location = 'sacramento' AND total_distance_m IS NOT NULL;
EOF

# Change buffer distance (example: setting to 20m)
psql -U runmap_user -d runmap -h localhost -c "UPDATE runmap.settings SET value = '20'::jsonb WHERE key = 'buffer_distance_m';"

# Full rebuild after buffer change (reprocess all runs)
bash scripts/rebuild_all_coverage.sh

# Change completion threshold (% coverage to mark block as complete)
psql -U runmap_user -d runmap -h localhost << 'EOF'
UPDATE runmap.settings SET value = '85'::jsonb WHERE key = 'completion_threshold_pct';
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
EOF
bash scripts/export_tiles_blocks.sh
# Update tiles version to invalidate browser caches
psql -U runmap_user -d runmap -h localhost -c "UPDATE runmap.settings SET value = to_jsonb(extract(epoch from now())::bigint) WHERE key = 'tiles_version';"
```

### Processing Pipeline

```bash
# Process single GPX file incrementally (Mac/local dev)
bash scripts/ingest_gpx.sh /path/to/run.gpx
RUN_ID=$(psql -d runmap -t -c "SELECT MAX(gid) FROM runmap.runs_raw;")
bash scripts/process_run_incremental.sh $RUN_ID
bash scripts/export_tiles_incremental.sh

# Export tiles only (after direct DB changes)
bash scripts/export_tiles_incremental.sh

# Upload via API (server)
curl -X POST https://runmap.chouinard.me/api/upload -F "file=@run.gpx"
```

### Tile Management

```bash
# List tiles
ls -lh tiles/*.pmtiles

# Show tile metadata
pmtiles show tiles/runs.pmtiles

# Test tile serving
curl -I https://runmap.chouinard.me/tiles/streets_unrun.pmtiles
```

### Frontend Development

```bash
cd web
npm run dev      # Dev server with hot reload
npm run build    # Production build to web/build/
```

## File Locations

- Project root: `/Volumes/RunMap` (Mac) or `/home/mark/runmap` (server)
- GPX storage: `gpx/`
- Generated tiles: `tiles/`
- Database schema: `db/`
- Processing scripts: `scripts/`
- Frontend: `web/` (built to `web/build/`)
- API: `api/`

## Key Processing Details

### Segment-Visited Coverage Algorithm

1. **On GPX Upload:**
   - Insert to `runs_raw` (UUID primary key, auto-generated)
   - **Trigger automatically fires:** `trigger_auto_process_run_segments`
   - Call `buffer_one_run_subdiv(id)` → creates UTM buffer + subdivides in `runs_buffered_subdiv`
   - Call `apply_run_to_segments(id)` → marks intersecting segments as visited:
     - Find 5m segments intersecting run buffer
     - Set `visited = TRUE` for those segments (one-time, idempotent)
     - Update aggregate coverage in `block_coverage_segments`
   - Refresh `coverage_stats_blocks` materialized view
   - Export tiles

2. **Coverage Thresholds:**
   - <5%: Unrun (grey on map) - `streets_unrun` view - **hardcoded at 5%**
   - 5% to completion threshold: Partial (purple on map) - `streets_partial` view
   - ≥ completion threshold: Complete (green on map) - `streets_complete` view
   - **Completion threshold is configurable** via `completion_threshold_pct` setting (default: 90%)
   - Change threshold: Update setting → Refresh matview → Re-export tiles (see Common Commands)

3. **Why 90% not 100%:**
   - GPS tracks start/stop 5-15m from intersections
   - 20m buffer doesn't quite reach street ends on long segments
   - GPS gaps create small uncovered sections
   - Blocks you fully ran often show 85-95% coverage
   - 90% threshold represents "reasonably complete" coverage
   - You can adjust this threshold (e.g., 95% for stricter, 85% for more lenient)
   - Diagnostic: Query `streets_partial` ordered by coverage % DESC to validate threshold

### Memory Usage & Performance

- **Very old system (full recalculation):** O(all runs × all streets) → 112GB RAM, crashed with 11 runs
- **Old system (union-based incremental):** O(runs touching same block) → degraded to 27s/run with 265 runs
- **Current system (segment-visited):** O(segments touched) → constant 0.4s/run regardless of run count
- **Speedup:** 67x faster than union approach, truly constant time
- **Memory:** ~3GB RAM regardless of run count
- Server (20GB RAM) can now process uploads instantly

### Tile Export

Exports PMTiles layers:
- `runs.pmtiles` - All running tracks (blue lines)
- `streets_incomplete.pmtiles` - Unrun + partial blocks (<completion threshold, orange)
  - Combines `streets_unrun` + `streets_partial` views
- `streets_complete.pmtiles` - Complete blocks (≥completion threshold, green)
  - From `streets_complete` view

Pipeline: PostGIS → GeoJSON → Tippecanoe (MBTiles) → pmtiles convert

## Code Conventions

### SQL
- Schema: `runmap` for all objects
- Use `IF NOT EXISTS` for tables/views
- Primary keys: `id` (UUID for new tables), `gid` (auto-increment from ogr2ogr legacy)
- Always specify SRID in geometry types: `geometry(LineString, 4326)`
- Prefer `ST_Transform(geom, 32610)` over `::geography` for distance calculations
- **Current system uses binary flags, not geometry unions** - update segments, not geometries
- Use `ST_Subdivide` for faster intersection tests (256 vertices max)
- **Never** use `ST_SnapToGrid` in coverage calculations (causes artifacts)

### Shell Scripts
- `set -e` for fail-fast
- Clean up temp files in `/tmp/`
- Use `$TILES_DIR` and `$TMP_DIR` environment variables
- Check for empty GeoJSON before running tippecanoe:
  ```bash
  if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/file.geojson"; then
    tippecanoe ...
  fi
  ```
- Tippecanoe: `-Z4 -z14 --force` (zoom 4-14, overwrite existing)
- Do NOT use `ogr2ogr -overwrite` with `-sql` queries (fails)

### Python/Flask
- Secure filenames: `werkzeug.secure_filename()`
- JSON responses for all endpoints
- Use `subprocess.run()` for blocking operations (GPX ingest)
- Use `subprocess.Popen()` for async operations (tile export)
- Environment variables for all paths/config

### Frontend
- MapLibre GL JS for map rendering
- PMTiles protocol for efficient tile loading
- Poll `/api/tiles/version` to detect updates, reload layers
- Layer styling: orange (incomplete <threshold), green (complete ≥threshold), blue (runs)

## Diagnostics & Troubleshooting

### Coverage Calculation Issues

**Blocks marked partial that should be complete:**
```sql
-- Check coverage percentages of "partial" blocks (near completion threshold)
SELECT b.name, b.highway, ROUND(bcs.coverage_pct::numeric, 1) as pct
FROM runmap.block_coverage_segments bcs
JOIN runmap.streets_blocks_32610 b USING (block_id)
WHERE bcs.coverage_pct >= 5
  AND bcs.coverage_pct < runmap.get_completion_threshold()
ORDER BY bcs.coverage_pct DESC
LIMIT 20;
```
If many show 85-89%, consider lowering the completion threshold (e.g., from 90% to 85%).

**Coverage distribution analysis:**
```sql
-- See how blocks are distributed by coverage percentage
SELECT
  CASE
    WHEN coverage_pct < 5 THEN '0-5%'
    WHEN coverage_pct < 25 THEN '5-25%'
    WHEN coverage_pct < 50 THEN '25-50%'
    WHEN coverage_pct < 75 THEN '50-75%'
    WHEN coverage_pct < 90 THEN '75-90%'
    ELSE '90-100%'
  END as range,
  COUNT(*) as blocks
FROM runmap.block_coverage_segments
GROUP BY 1
ORDER BY 1;
```

**Validate buffer radius on small blocks:**
```sql
-- Show buffer as % of block length for small blocks
SELECT b.name, b.highway,
  ROUND(b.block_length_m::numeric, 2) as block_m,
  20.0 as buffer_m,
  ROUND((20.0 / b.block_length_m * 100)::numeric, 1) as buffer_pct
FROM runmap.streets_blocks_32610 b
WHERE b.block_length_m < 50
ORDER BY b.block_length_m
LIMIT 10;
```
GPS accuracy is ~5-10m. Buffer too large creates false positives on parallel streets.

### Frontend Cache Issues

**Browser not showing changes to HTML/tiles:**
- Hard refresh: Cmd+Shift+R (Mac Chrome/Firefox), Cmd+Option+E then Cmd+R (Safari)
- Open DevTools → Network → Check "Disable cache"
- Verify tile `Last-Modified` header: `curl -I https://runmap.chouinard.me/tiles/streets_unrun.pmtiles`

### Performance Monitoring

```bash
# Check materialized view sizes
psql -U runmap_user -d runmap -h localhost -c "\d+ runmap.coverage_stats_blocks"

# Verify segment-visited system is populated
psql -U runmap_user -d runmap -h localhost << 'EOF'
SELECT
  (SELECT COUNT(*) FROM runmap.runs_raw WHERE location = 'sacramento') as sac_runs,
  (SELECT COUNT(DISTINCT run_id) FROM runmap.runs_buffered_subdiv) as buffered_runs,
  (SELECT COUNT(*) FROM runmap.block_segments) as total_segments,
  (SELECT COUNT(*) FROM runmap.block_segment_visited WHERE visited = true) as visited_segments,
  (SELECT COUNT(*) FROM runmap.block_coverage_segments WHERE coverage_pct >= 75) as complete_blocks,
  (SELECT ROUND(AVG(coverage_pct)::numeric, 2) FROM runmap.block_coverage_segments WHERE visited_length_m > 0) as avg_coverage_pct;
EOF
```

## Migration Notes

**Current System:** Segment-visited coverage (migrated 2025-10-20)
- See [docs/SEGMENT_VISITED_MIGRATION.md](docs/SEGMENT_VISITED_MIGRATION.md) for migration details and performance results
- Previous systems (incremental unions, block-percentage) archived in [docs/archive/](docs/archive/)

**To rebuild coverage from scratch:**
```bash
bash scripts/rebuild_all_coverage.sh
# Uses buffer_one_run_subdiv() + apply_run_to_segments()
# Processes ~300 runs in ~2 minutes (constant time per run)
```

**Changing buffer distance:**
```bash
# 1. Update the setting
psql -U runmap_user -d runmap -h localhost -c \
  "UPDATE runmap.settings SET value = '15'::jsonb WHERE key = 'buffer_distance_m';"

# 2. Clear buffers and visited flags
psql -U runmap_user -d runmap -h localhost << 'EOF'
TRUNCATE runmap.runs_buffered_subdiv;
UPDATE runmap.block_segment_visited SET visited = false;
UPDATE runmap.block_coverage_segments SET visited_length_m = 0, coverage_pct = 0;
EOF

# 3. Rebuild all coverage (this repopulates the tables)
bash scripts/rebuild_all_coverage.sh
```
**Note:** The rebuild script reprocesses all runs and repopulates `block_coverage_segments`. Simply truncating tables without rebuilding leaves coverage data empty.

**Including/excluding street types:**

To include alleys (currently excluded):
```bash
# 1. Re-import streets with alleys included
# Edit the OSM import to NOT filter out highway='service'
# Then regenerate streets_blocks_32610 and block_segments

# 2. Rebuild coverage
bash scripts/rebuild_all_coverage.sh
```

To exclude a street type:
```sql
-- Remove from reference tables
DELETE FROM runmap.streets_reference WHERE highway = 'service';
DELETE FROM runmap.streets_reference_32610 WHERE highway = 'service';

-- Also remove affected blocks and segments
DELETE FROM runmap.streets_blocks_32610 WHERE highway = 'service';
-- Then regenerate block_segments and rebuild coverage
```
**Current exclusions:** `highway = 'service'` (alleys/driveways)

**Expanding the AOI (adding more streets):**

This is safe to do incrementally - existing coverage is preserved and the app continues working.

```bash
# Overview:
# 1. Import new streets from OSM for expanded area
# 2. Split new streets into blocks
# 3. Segment new blocks into 5m pieces
# 4. Initialize coverage tracking for new blocks
# 5. (Optional) Reprocess runs to mark new segments as visited
# 6. Export tiles to include new area
```

Step-by-step:

```bash
# 1. Import additional streets from OSM
# Use your OSM import process to get streets for the expanded area
# Filter by bounding box that includes the new area
# Import into a temp table first, then merge

# Example using ogr2ogr (adjust bounds for your expansion):
ogr2ogr -f "PostgreSQL" PG:"host=localhost dbname=runmap user=runmap_user" \
  -sql "SELECT osm_id, name, highway, geometry FROM lines WHERE highway IN ('residential', 'primary', 'secondary', 'tertiary', 'footway', 'path', 'cycleway')" \
  -nln runmap.streets_new_import \
  -t_srs EPSG:4326 \
  your_expanded_osm_file.pbf

# 2. Merge new streets into reference tables (avoiding duplicates)
psql -U runmap_user -d runmap -h localhost << 'EOF'
-- Add new streets (skip any that already exist by osm_id)
INSERT INTO runmap.streets_reference (osm_id, name, highway, geom, runnable)
SELECT osm_id, name, highway, geom, TRUE
FROM runmap.streets_new_import
WHERE osm_id NOT IN (SELECT osm_id FROM runmap.streets_reference)
  AND highway != 'service';  -- Exclude alleys

-- Add to UTM-projected table
INSERT INTO runmap.streets_reference_32610 (name, highway, geom_32610, total_length_m)
SELECT
  name,
  highway,
  ST_Transform(geom, 32610),
  ST_Length(ST_Transform(geom, 32610))
FROM runmap.streets_new_import
WHERE osm_id NOT IN (SELECT osm_id FROM runmap.streets_reference WHERE osm_id IS NOT NULL)
  AND highway != 'service';

-- Cleanup temp table
DROP TABLE IF EXISTS runmap.streets_new_import;
EOF

# 3. Split new streets into blocks at intersections
# NOTE: split_streets_at_intersections() recreates ALL blocks
# For incremental expansion, use this targeted approach instead:

psql -U runmap_user -d runmap -h localhost << 'EOF'
-- Get the max block_id before adding new ones
DO $$
DECLARE
  v_max_block_id INT;
  v_new_streets_count INT;
BEGIN
  SELECT COALESCE(MAX(block_id), 0) INTO v_max_block_id FROM runmap.streets_blocks_32610;

  -- Count new streets (those without blocks yet)
  SELECT COUNT(*) INTO v_new_streets_count
  FROM runmap.streets_reference_32610 s
  WHERE NOT EXISTS (
    SELECT 1 FROM runmap.streets_blocks_32610 b
    WHERE b.parent_ogc_fid = s.ogc_fid
  );

  RAISE NOTICE 'Adding blocks for % new streets (starting from block_id %)',
    v_new_streets_count, v_max_block_id + 1;
END $$;

-- Add blocks for new streets only
-- (Simplified: treats each new street as one block. For proper intersection splitting,
-- you may need to run split_streets_at_intersections() which rebuilds all blocks)
INSERT INTO runmap.streets_blocks_32610 (name, highway, geom_32610, block_length_m, parent_ogc_fid)
SELECT
  s.name,
  s.highway,
  s.geom_32610,
  s.total_length_m,
  s.ogc_fid
FROM runmap.streets_reference_32610 s
WHERE NOT EXISTS (
  SELECT 1 FROM runmap.streets_blocks_32610 b
  WHERE b.parent_ogc_fid = s.ogc_fid
);
EOF

# 4. Create 5m segments for new blocks and initialize tracking
psql -U runmap_user -d runmap -h localhost << 'EOF'
-- Segment new blocks into 5m pieces
INSERT INTO runmap.block_segments (block_id, segment_geom, segment_length_m)
SELECT
  b.block_id,
  (ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom AS segment_geom,
  ST_Length((ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom) AS segment_length_m
FROM runmap.streets_blocks_32610 b
WHERE NOT EXISTS (
  SELECT 1 FROM runmap.block_segments bs
  WHERE bs.block_id = b.block_id
);

-- Initialize visited flags for new segments (all FALSE)
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE
FROM runmap.block_segments
WHERE segment_id NOT IN (SELECT segment_id FROM runmap.block_segment_visited);

-- Initialize aggregate coverage for new blocks (0%)
INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
SELECT
  block_id,
  0,
  SUM(segment_length_m)
FROM runmap.block_segments
WHERE block_id NOT IN (SELECT block_id FROM runmap.block_coverage_segments)
GROUP BY block_id;

-- Verify new blocks were added
SELECT
  COUNT(*) as new_blocks,
  SUM(total_length_m) as new_length_m
FROM runmap.block_coverage_segments
WHERE visited_length_m = 0;
EOF

# 5. (OPTIONAL) Reprocess existing runs to cover new segments
# Only needed if you've already run in the expanded area
# Skip this if the new area is truly new territory

# This reprocesses all Sacramento runs against the new segments:
bash scripts/rebuild_all_coverage.sh

# 6. Export tiles to include new area
bash scripts/export_tiles_blocks.sh

# Update tiles version
psql -U runmap_user -d runmap -h localhost -c \
  "UPDATE runmap.settings SET value = to_jsonb(extract(epoch from now())::bigint) WHERE key = 'tiles_version';"

# 7. (Optional) Update AOI polygon if you use it for visualization
psql -U runmap_user -d runmap -h localhost << 'EOF'
-- Example: Expand AOI to include new area
-- Replace with your actual expanded boundary coordinates
UPDATE runmap.aoi
SET geom = ST_GeomFromText('POLYGON((...your expanded coordinates...))', 4326)
WHERE name = 'sacramento';
EOF
```

**Important notes about AOI expansion:**

1. **Existing coverage is preserved** - Your current blocks, segments, and visited flags remain unchanged. New streets simply appear as 0% coverage (orange on map).

2. **ID sequences are safe** - `block_id` and `segment_id` use auto-increment sequences, so new blocks/segments get unique IDs without conflicts.

3. **Reprocessing is optional** - If you haven't run in the new area yet, skip the rebuild step. New blocks will show as orange until you actually run there.

4. **Incremental vs full rebuild** - The simplified approach above treats each new street as one block. For proper intersection splitting (recommended), run `split_streets_at_intersections()` which rebuilds all blocks. This is safe but takes longer.

5. **Tile bounds adjust automatically** - Tippecanoe reads the GeoJSON bounding box, so new areas are automatically included in tiles.

6. **AOI table is informational** - The `runmap.aoi` table isn't used for location detection (that uses hardcoded coordinates in `detect_location()`), but update it if you use it for visualization.

**Concerns to be aware of:**

- **OSM data consistency** - Ensure your OSM import uses the same highway type filters as the original import
- **Intersection splitting** - The simplified approach doesn't split at intersections; for consistency, consider running `split_streets_at_intersections()` on all streets
- **Processing time** - Full rebuild takes ~2 minutes for 300 runs; scales linearly with run count
- **Overlapping imports** - The `WHERE osm_id NOT IN (...)` check prevents duplicates, but verify your OSM data has consistent osm_ids

## Important Constraints

- **Service roads excluded:** `highway = 'service'` filtered out (alleys not part of running goal)
- **Buffer radius:** 20m (GPS accuracy, configurable in settings)
- **Coverage thresholds:** <5% unrun (hardcoded), ≥ completion_threshold_pct complete (default 90%, configurable via settings)
- **Coordinate precision:** Use UTM 32610 for all distance calculations, never WGS84 degrees
- **Memory limit:** Server has 20GB RAM, current system uses ~3GB
- **Tile zoom:** z4-z14 (city-scale, not building-level)
- **Performance:** Constant 0.4s per run regardless of total run count (segment-visited system)
