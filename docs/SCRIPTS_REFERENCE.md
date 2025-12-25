# Scripts Reference

Quick reference for all processing scripts in `scripts/` directory.

## Production Scripts (Use These)

### `ingest_gpx.sh`
**Purpose:** Import single GPX file to database with deduplication
**Usage:** `bash scripts/ingest_gpx.sh path/to/run.gpx`
**Time:** ~2-5 seconds

**What it does:**
1. Parses GPX file (Python + gpxpy)
2. Extracts GPS tracks, start time, duration, distance
3. Calculates `workout_hash` (date + time in 10-min buckets)
4. Inserts to `runs_raw` with `ON CONFLICT (workout_hash) DO NOTHING`
5. Auto-detects location (Sacramento, Portland, Other)
6. Calculates total distance in meters

**Deduplication:**
- Hash based on start_time rounded to 10-minute bucket
- Example: Run at 16:47:19 → bucket "2025-10-19 16:40"
- Detects same workout from different apps (WorkoutDoors, Apple Health, Strava)
- Skips if duplicate found

**Automatic Processing:**
- Database trigger `auto_process_new_run()` fires after insert
- Creates 10m buffer automatically
- Updates block coverage automatically
- Refreshes coverage stats automatically

**When to use:**
- Called by API upload endpoint
- Called by `bulk_import.sh`
- Manual single-file import (rare)

**Output:**
- `✓ Inserted run: <run_id>` - Success
- `⚠ Duplicate run (already in database)` - Skipped

---

### `bulk_import.sh`
**Purpose:** Import directory of GPX files with batch processing
**Usage:** `bash scripts/bulk_import.sh /path/to/gpx_directory`
**Time:** ~2-3 minutes for 20 runs

**What it does:**
1. Counts GPX files in directory
2. Disables `trigger_auto_process_run` (for speed)
3. Imports each file via `ingest_gpx.sh`
4. Tracks: SUCCESS / DUPLICATE / ERROR counts
5. Re-enables trigger
6. Batch processes all new runs:
   - `buffer_one_run()` for each
   - `apply_run_to_block_coverage()` for each
7. Refreshes coverage stats

**Progress indicators:**
- Shows every 5 runs processed
- Final summary with counts

**When to use:**
- Initial import of historical runs
- Importing Apple Health export (600+ runs)
- Any bulk GPX import operation

**Important:**
- Does NOT export tiles (run `export_tiles_blocks.sh` separately)
- Much faster than individual uploads (disables triggers during import)

**Example:**
```bash
# On server
DB_HOST=localhost bash scripts/bulk_import.sh /home/mark/runmap/data/import

# Output:
# ✓ SUCCESS: route_2025-10-01_11.09am.gpx
# ⚠️ DUPLICATE: route_2025-10-02_8.34pm.gpx
# ✓ SUCCESS: route_2025-10-03_9.40am.gpx
# ...
# ✓ Imported: 18
# ⚠️ Duplicates: 2
# ✗ Errors: 0
```

---

### `export_tiles_blocks.sh`
**Purpose:** Export block coverage to PMTiles for web map
**Usage:** `bash scripts/export_tiles_blocks.sh`
**Time:** ~30 seconds

**What it does:**
1. Exports incomplete blocks (<90% coverage) to GeoJSON
2. Exports complete blocks (≥90% coverage) to GeoJSON
3. Exports all runs to GeoJSON
4. Converts to MBTiles via Tippecanoe (z4-z14)
5. Converts MBTiles to PMTiles format
6. Saves to `tiles/` directory
7. Updates `tiles_version` in database (cache busting)

**Generates:**
- `streets_incomplete.pmtiles` - Purple blocks (<90% coverage)
- `streets_complete.pmtiles` - Green blocks (≥90% coverage)
- `runs.pmtiles` - Red run tracks

**When to use:**
- After bulk import
- After any coverage changes
- After changing completion threshold
- When map tiles are stale

**Note:**
- Frontend polls `/api/tiles/version` and auto-reloads when tiles update
- Tippecanoe generates zoom levels 4-14 (city-scale)

---

### `rebuild_all_coverage.sh`
**Purpose:** Full rebuild of all coverage from scratch
**Usage:** `bash scripts/rebuild_all_coverage.sh`
**Time:** ~5-10 minutes depending on run count

**What it does:**
1. Truncates `runs_buffered_32610` (clears all buffers)
2. Truncates `block_coverage_32610` (clears all coverage)
3. Truncates `street_coverage_32610` (clears street coverage)
4. Rebuilds buffers for ALL runs in database
5. Recalculates block coverage for ALL runs
6. Refreshes coverage statistics

**⚠️ WARNING:** Heavy operation - only use when:
- Changing buffer distance (requires reprocessing)
- Coverage data corrupted
- After changing street network baseline
- After major database schema changes

**When to use:**
- Never for routine operations!
- Only when coverage state needs complete reset

---

### `delete_recent_20_runs.sh`
**Purpose:** Delete N most recent runs by run date (for testing)
**Usage:** `bash scripts/delete_recent_20_runs.sh [N]`
**Default:** N=20
**Time:** ~5-10 seconds

**What it does:**
1. Finds N most recent runs **by start_time** (not upload date!)
2. Deletes from `runs_raw` (CASCADE to buffers/coverage)
3. Shows deleted run IDs and filenames
4. Rebuilds coverage after deletion

**When to use:**
- Development/testing
- Remove test imports
- Clean up before production import

**Example:**
```bash
# Delete 5 most recent runs
bash scripts/delete_recent_20_runs.sh 5

# Delete 20 most recent runs (default)
bash scripts/delete_recent_20_runs.sh
```

**Important:** Deletes by **run date** not upload date!
- Deletes the runs you ran most recently
- Not the runs you uploaded most recently

---

### `fix_content_hashes.sh`
**Purpose:** Recalculate workout_hash for existing runs (utility)
**Usage:** `bash scripts/fix_content_hashes.sh`
**Time:** ~10-30 seconds depending on run count

**What it does:**
1. Finds all runs with NULL `workout_hash`
2. For each run:
   - Extracts start_time and duration from database
   - Calculates workout_hash (Python)
   - Updates run in database
3. Shows progress every 5 runs

**When to use:**
- After migration from `content_hash` to `workout_hash`
- If hash calculation logic changes
- Backfill after schema change

**Rarely needed** - mainly for one-time migrations

---

## Archived Scripts (Reference Only)

Located in `scripts/archive/`:

- `add_geometry_batch.sh` - Initial geometry backfill (one-time use)
- `add_geometry_bulk.sh` - Alternative geometry import (one-time use)
- `parse_apple_health_export.py` - Parse export.xml for initial import
- `detect_activity_type.py` - Classify run/walk/cycle from export.xml
- `process_new_run.sh` - Old manual processing (replaced by triggers)
- `process_run_incremental.sh` - Old incremental processing (replaced by triggers)

**Don't use these** - kept for reference/history only

---

## Obsolete Scripts (Historical)

Located in `scripts/obsolete/`:

- Old bulk import variants
- Old phase system scripts (phase1, phase2, phase3)
- Old verification scripts
- Old tile export scripts
- Old path scripts (slow_path, fast_path)
- Old debugging utilities

**Can be deleted** - no longer part of system

---

## Common Workflows

### Daily Use: Upload Run via iOS Shortcut
```
1. Export GPX from WorkOutDoors
2. Run "Upload to RunMap" shortcut
3. Done! (automatic processing + tile export)
```

### Daily Use: Upload via Web Interface
```
1. Open https://runmap.chouinard.me
2. Click "Upload GPX"
3. Select file
4. Map auto-updates in ~30 seconds
```

### Bulk Import Historical Runs
```bash
# 1. Copy GPX files to server
scp ~/Downloads/apple_health_export/workout-routes/*.gpx \
    runmap:/home/mark/runmap/data/bulk-import/

# 2. SSH and run bulk import
ssh -p 2222 runmap
cd /home/mark/runmap
DB_HOST=localhost bash scripts/bulk_import.sh /home/mark/runmap/data/bulk-import

# 3. Export tiles
bash scripts/export_tiles_blocks.sh

# 4. Check results
psql -h localhost -U runmap_user -d runmap \
  -c "SELECT * FROM runmap.coverage_stats_blocks;"

exit
```

### Development: Test with Sample Runs
```bash
# 1. Wipe database
ssh -p 2222 runmap
psql -h localhost -U runmap_user -d runmap << 'EOF'
TRUNCATE TABLE runmap.runs_raw CASCADE;
TRUNCATE TABLE runmap.runs_buffered_32610 CASCADE;
TRUNCATE TABLE runmap.street_coverage_32610 CASCADE;
TRUNCATE TABLE runmap.block_coverage_32610 CASCADE;
EOF

# 2. Import test runs
DB_HOST=localhost bash scripts/bulk_import.sh /home/mark/runmap/data/dev-runs

# 3. Export tiles
bash scripts/export_tiles_blocks.sh

exit
```

### Change Buffer Distance
```bash
# 1. Update setting
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
UPDATE runmap.settings SET value = '15'::jsonb WHERE key = 'buffer_distance_m';
EOF

# 2. Rebuild all coverage (required!)
ssh -p 2222 runmap
cd /home/mark/runmap
bash scripts/rebuild_all_coverage.sh

# 3. Export tiles
bash scripts/export_tiles_blocks.sh

exit
```

### Change Completion Threshold
```bash
# 1. Update setting
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
UPDATE runmap.settings SET value = '85'::jsonb WHERE key = 'completion_threshold_pct';
EOF

# 2. Refresh stats (fast)
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
EOF

# 3. Export tiles (threshold only affects classification)
ssh -p 2222 runmap
cd /home/mark/runmap
bash scripts/export_tiles_blocks.sh
exit
```

---

## Environment Variables

All scripts use these defaults:

```bash
DB_HOST=${DB_HOST:-192.168.68.25}  # Database server
DB_USER=${DB_USER:-runmap_user}    # Database user
DB_NAME=${DB_NAME:-runmap}         # Database name
PGPASSWORD=${PGPASSWORD:-<password>}   # Database password (in bulk_import.sh)
```

**Override for local execution:**
```bash
DB_HOST=localhost bash scripts/bulk_import.sh /path/to/gpx
```

**Note:** Password stored in `~/.pgpass` for security (except bulk_import.sh which sets PGPASSWORD)

---

## Script Locations

**On Mac (development via SMB):**
```
/Volumes/RunMap/scripts/
```

**On Server (production):**
```
/home/mark/runmap/scripts/
```

**Via API:**
- iOS Shortcut → API → `ingest_gpx.sh` → database trigger
- Web upload → API → `ingest_gpx.sh` → database trigger
- Tiles exported asynchronously by API

---

## Troubleshooting

### Script hangs or fails
**Check database connection:**
```bash
psql -h 192.168.68.25 -U runmap_user -d runmap -c "SELECT 1;"
```

**Check for password issues:**
- Ensure `~/.pgpass` exists: `chmod 600 ~/.pgpass`
- Or use `PGPASSWORD=<password>` environment variable

### Duplicate detection not working
**Verify workout_hash calculation:**
```bash
# Check if runs have workout_hash
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT filename, workout_hash, start_time
FROM runmap.runs_raw
WHERE workout_hash IS NULL;
EOF
```

**Run hash backfill if needed:**
```bash
bash scripts/fix_content_hashes.sh
```

### Tiles not updating on web
**Check tile timestamps:**
```bash
ls -lh /home/mark/runmap/tiles/*.pmtiles
```

**Verify tiles_version updated:**
```bash
psql -h 192.168.68.25 -U runmap_user -d runmap -c \
  "SELECT value FROM runmap.settings WHERE key = 'tiles_version';"
```

**Hard refresh browser:**
- Mac Chrome/Firefox: `Cmd+Shift+R`
- Mac Safari: `Cmd+Option+E` then `Cmd+R`

**Check nginx serving tiles:**
```bash
curl -I https://runmap.chouinard.me/tiles/streets_complete.pmtiles
```

### Import fails with "already exists"
This is normal! Duplicate detection working correctly.
- Check if file was already imported: different filename, same run
- Verify with `workout_hash` query in database

### Processing seems slow
**Check server resources:**
```bash
ssh -p 2222 runmap
htop  # Look for CPU/memory usage
```

**For bulk imports:**
- Normal: ~2-3 minutes for 20 runs
- Slow: >10 minutes for 20 runs → check server load

---

## Dependencies

**Required on server:**
- PostgreSQL 16 + PostGIS 3
- Python 3.12 with packages: `gpxpy`, `psycopg2`, `shapely`, `geopy`
- GDAL/OGR (for `ogr2ogr`)
- Tippecanoe (for tile generation)
- PMTiles CLI (for MBTiles → PMTiles conversion)

**Installation:**
```bash
# PostgreSQL + PostGIS
sudo apt install postgresql-16 postgresql-16-postgis-3

# Python packages
pip install gpxpy psycopg2-binary shapely geopy

# GDAL
sudo apt install gdal-bin

# Tippecanoe
git clone https://github.com/felt/tippecanoe.git
cd tippecanoe && make -j && sudo make install

# PMTiles
npm install -g pmtiles
```

---

## See Also

- **[Usage Guide](USAGE_GUIDE.md)** - Complete day-to-day operations
- **[Architecture](ARCHITECTURE.md)** - System design and data flow
- **[CLAUDE.md](../CLAUDE.md)** - Full technical reference for AI assistance
- **[scripts/README.md](../scripts/README.md)** - Scripts directory overview
