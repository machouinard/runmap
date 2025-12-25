# Database Setup Guide

This directory contains SQL schema files for the RunMap database. Run these files in order when setting up a fresh database or after major schema changes.

## Prerequisites

- PostgreSQL 16+ with PostGIS 3+
- Database: `runmap`
- User: `runmap_user` with appropriate permissions
- Connection details in `api/.env`

## Initial Setup (Fresh Database)

Run these files in order:

```bash
# 1. Create core tables (runs, streets, settings)
psql -U runmap_user -d runmap -h localhost -f db/01_create_tables.sql

# 2. Create segment-based coverage system (current production system)
psql -U runmap_user -d runmap -h localhost -f db/04_segment_schema.sql

# Note: 04_segment_schema.sql includes:
#   - Block segmentation (streets_blocks_32610)
#   - 5m pre-segmented streets (block_segments)
#   - Segment-visited tables (block_segment_visited, block_coverage_segments)
#   - Auto-processing triggers (trigger_auto_process_run_segments)
```

## File Descriptions

### Core Schema

- **`01_create_tables.sql`** - Core tables for runs, walks, cycling, streets, settings
  - `runs_raw`, `walks_raw`, `cycling_raw` - Activity tracks with deduplication
  - `streets_reference` - OSM street network baseline
  - `settings` - Configuration (buffer distance, tiles version)
  - Functions: `detect_location()`, `get_buffer_distance()`

### Coverage System

- **`04_segment_schema.sql`** - Segment-visited coverage system (CURRENT)
  - `runs_buffered_subdiv` - Subdivided run buffers for fast intersection
  - `block_segment_visited` - Binary flags for visited segments
  - `block_coverage_segments` - Aggregate coverage per block
  - Functions: `buffer_one_run_subdiv()`, `apply_run_to_segments()`
  - **Memory efficient:** O(segments touched) vs O(all runs × all streets)

### Triggers

Triggers are created by `04_segment_schema.sql`:
  - `trigger_auto_process_run_segments` - Auto-buffer and update coverage on insert
  - `trigger_set_location_before_insert` - Auto-detect location (Sacramento/Portland/other)
  - `trigger_cleanup_coverage_on_delete` - Recalculates coverage when runs are deleted
    - Efficiently checks affected segments for remaining coverage from other runs
    - Updates only affected blocks instead of full rebuild
    - Automatically refreshes materialized view

## Obsolete Files (For Reference Only)

These files represent old approaches that have been replaced:

- `03_incremental_coverage.sql` - Very old incremental coverage
- `03_incremental_coverage_fixed.sql` - Fixed version of old system
- `09_block_percentage_coverage.sql` - Block-percentage system (never fully deployed)
- `10_fix_buffer_function.sql` - Old buffer function fixes
- `11_auto_process_trigger.sql` - **INCORRECT** - Documents non-existent trigger (production uses different trigger)

**Do not run these on new databases.** The current system is defined in `04_segment_schema.sql`.

## Common Operations

### Check Coverage Stats

```sql
SELECT * FROM runmap.coverage_stats_blocks;
```

### Manual Tile Export Trigger

```sql
-- Update tiles version for cache busting
UPDATE runmap.settings
SET value = (EXTRACT(EPOCH FROM NOW())::bigint)::jsonb
WHERE key = 'tiles_version';
```

Then run:
```bash
ssh -p 2222 mark@192.168.68.25 "cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh"
```

### Verify Triggers

```sql
-- Check triggers on runs_raw
SELECT tgname, tgenabled, pg_get_triggerdef(oid)
FROM pg_trigger
WHERE tgrelid = 'runmap.runs_raw'::regclass
  AND tgname LIKE '%auto_process%'
   OR tgname LIKE '%cleanup%';
```

### Rebuild All Coverage (After Schema Changes)

```bash
# Option 1: Use the automated script (recommended)
bash scripts/rebuild_all_coverage.sh

# Option 2: Manual rebuild
psql -U runmap_user -d runmap -h localhost << 'EOF'
-- Clear existing coverage
TRUNCATE runmap.runs_buffered_subdiv;
TRUNCATE runmap.block_segment_visited;
TRUNCATE runmap.block_coverage_segments;

-- Reinitialize visited flags (required!)
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE FROM runmap.block_segments
ON CONFLICT (segment_id) DO NOTHING;

-- Reprocess all Sacramento runs
DO $$
DECLARE
  run_record RECORD;
  counter INTEGER := 0;
BEGIN
  FOR run_record IN
    SELECT id FROM runmap.runs_raw
    WHERE location = 'sacramento'
    ORDER BY start_time
  LOOP
    PERFORM runmap.buffer_one_run_subdiv(run_record.id);
    PERFORM runmap.apply_run_to_segments(run_record.id);
    counter := counter + 1;
    IF counter % 50 = 0 THEN
      RAISE NOTICE 'Processed % runs', counter;
    END IF;
  END LOOP;
END $$;

-- Refresh stats
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
EOF
```

## Troubleshooting

### "relation runs_buffered_32610 does not exist"

Old trigger is still active. Drop it:

```sql
DROP TRIGGER IF EXISTS trigger_auto_process_run ON runmap.runs_raw;
```

Then ensure `05_triggers.sql` has been run.

### Coverage not updating after delete

Check that the cleanup trigger exists:

```sql
SELECT * FROM pg_trigger
WHERE tgrelid = 'runmap.runs_raw'::regclass
  AND tgname = 'trigger_cleanup_coverage_on_delete';
```

If missing, run `db/05_triggers.sql`.

### Tiles not regenerating

Tiles are NOT automatically regenerated by database triggers. After deletes or manual coverage changes, trigger export via API or manually:

```bash
ssh -p 2222 mark@192.168.68.25 "cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh"
```

### All blocks show 0% coverage (after deletes or schema changes)

The `block_segment_visited` table needs to be initialized with entries for all segments:

```sql
-- Check if table is empty
SELECT COUNT(*) FROM runmap.block_segment_visited;  -- Should match block_segments count

-- Initialize if empty
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE FROM runmap.block_segments
ON CONFLICT (segment_id) DO NOTHING;

-- Then reprocess all runs with buffers
DO $$
DECLARE
  run_record RECORD;
  counter INTEGER := 0;
BEGIN
  FOR run_record IN
    SELECT DISTINCT run_id
    FROM runmap.runs_buffered_subdiv
    WHERE run_id IN (SELECT id FROM runmap.runs_raw WHERE location = 'sacramento')
  LOOP
    PERFORM runmap.apply_run_to_segments(run_record.run_id);
    counter := counter + 1;
    IF counter % 50 = 0 THEN
      RAISE NOTICE 'Processed % runs', counter;
    END IF;
  END LOOP;
  RAISE NOTICE 'Total processed: %', counter;
END $$;

-- Refresh stats
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
```

## Notes

- **Database migrations are NOT part of `scripts/deploy.sh`** - Deploy handles code/scripts only
- Schema changes should be run manually via SSH to the server
- Always backup before running schema changes: `pg_dump runmap > backup.sql`
- The segment-based system is the current recommended approach
- Old buffer system files are kept for historical reference but should not be used
