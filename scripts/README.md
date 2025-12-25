# RunMap Scripts Directory

## Production Scripts (Use These)

### Core Import & Processing
- **`bulk_import.sh`** - Universal bulk GPX import with duplicate detection
  - Usage: `./bulk_import.sh <gpx_directory>`
  - Disables triggers during import for speed
  - Batch processes all runs after import
  - Refreshes tiles automatically

- **`ingest_gpx.sh`** - Single GPX file import
  - Used by API and bulk import
  - Calculates content hash (binary mode)
  - Inserts to runs_raw (triggers handle processing)
  - Usage: `./ingest_gpx.sh /path/to/file.gpx`

### Tile Export
- **`export_tiles_blocks.sh`** - Export all PMTiles (runs, coverage, streets)
  - Usage: `./export_tiles_blocks.sh`
  - Generates 5 tile layers
  - Updates tiles_version in database
  - Run after bulk imports or DB changes

### Maintenance
- **`rebuild_all_coverage.sh`** - Full coverage rebuild from scratch
  - Usage: `./rebuild_all_coverage.sh`
  - Use when buffer distance changes
  - Use when street data changes
  - Use to fix broken coverage state

- **`delete_recent_20_runs.sh`** - Delete N most recent runs (by run date)
  - Usage: `./delete_recent_20_runs.sh [N]` (default: 20)
  - Deletes by start_time (not upload date)
  - Rebuilds coverage after deletion
  - Use for development/testing

- **`fix_content_hashes.sh`** - Recalculate hashes in binary mode
  - Usage: `./fix_content_hashes.sh`
  - Use if bulk import used wrong hash method
  - Requires GPX files in `gpx/` directory

---

## Archived Scripts (One-Time Use)

Located in `archive/` directory:
- `add_geometry_batch.sh` - Initial geometry backfill (already done)
- `add_geometry_bulk.sh` - Alternative geometry import (already done)
- `parse_apple_health_export.py` - Parse export.xml for initial import
- `detect_activity_type.py` - Classify run/walk/cycle from export.xml
- `process_new_run.sh` - Old manual processing (replaced by triggers)
- `process_run_incremental.sh` - Old incremental processing (replaced by triggers)

---

## Obsolete Scripts (Old System)

Located in `obsolete/` directory:
- Old bulk import: `bulk_import_from_export.sh`, `run_bulk_import_on_server.sh`
- Old phase system: `run_phase1_split.sh`, `run_phase2_subdivision.sh`, `run_phase3_coverage.sh`
- Old verification: `verify_phase1.sh`, `verify_phase2.sh`, `verify_phase3.sh`
- Old tile exports: `export_tiles_incremental.sh`
- Old path scripts: `slow_path.sh`, `slow_path_mac.sh`, `slow_path_minimal.sh`, `fast_path.sh`
- Old utilities: `test_classification.py`, `test_single_run.sh`, `find_test_gpx_files.sh`
- Old debugging: `debug_coverage.sh`, `check_coverage_table.sh`, `fix_coverage_table.sh`
- Development: `clear_test_data.sh`

---

## Common Workflows

### Import new GPX files
```bash
# Single file
./ingest_gpx.sh /path/to/run.gpx

# Bulk directory
./bulk_import.sh /path/to/gpx_directory

# After bulk import, export tiles
./export_tiles_blocks.sh
```

### Change buffer distance
```bash
# Update database setting
psql -h 192.168.68.25 -U runmap_user -d runmap -c \
  "UPDATE runmap.settings SET value = '10'::jsonb WHERE key = 'buffer_distance_m';"

# Rebuild all coverage
./rebuild_all_coverage.sh

# Export updated tiles
./export_tiles_blocks.sh
```

### Development testing
```bash
# Delete 20 most recent runs
./delete_recent_20_runs.sh 20

# Re-import them
./bulk_import.sh /path/to/test_runs

# Export tiles
./export_tiles_blocks.sh
```

---

## Environment Variables

All scripts use:
- `DB_HOST` - Database host (default: `192.168.68.25` for server, `localhost` for local)
- `DB_NAME` - Database name (default: `runmap`)
- `DB_USER` - Database user (default: `runmap_user`)

Password stored in `~/.pgpass` file (not in scripts).

---

## Cleanup History

**2025-10-19**: Moved 21 obsolete scripts and 6 archive scripts to subdirectories.
- Cleaned up old phase-based coverage system
- Removed duplicate bulk import scripts
- Archived one-time migration/backfill scripts
- Kept 6 core production scripts
