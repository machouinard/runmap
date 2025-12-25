# TODO: AOI Expansion Process

## Overview
Expand the area of interest (AOI) from Sacramento city to a larger area (e.g., Sacramento County, or Sacramento + Arden-Arcade).

## Strategy: Option C - Recreate From Scratch (Recommended)

This approach provides the cleanest result with no risk of duplicates and consistent data.

## Prerequisites

- [ ] Identify the expanded area boundaries
- [ ] Download larger OSM extract file (e.g., from Geofabrik)
  - Current: Sacramento city
  - Expanded: Sacramento County or custom bounding box
  - Source: https://download.geofabrik.de/north-america/us/california.html

## Steps

### 1. Backup Existing Data
```bash
# Backup current streets_reference table
pg_dump -h 192.168.68.25 -U runmap_user -d runmap \
  -t runmap.streets_reference \
  -t runmap.streets_reference_32610 \
  > backup_streets_$(date +%Y%m%d).sql

# Backup entire database (optional, for safety)
pg_dump -h 192.168.68.25 -U runmap_user -d runmap \
  > backup_runmap_$(date +%Y%m%d).sql
```

### 2. Download Expanded OSM Data
```bash
# Download from Geofabrik (example for Sacramento County)
wget https://download.geofabrik.de/north-america/us/california/sacramento-county-latest.osm.pbf

# Or use custom bounding box with osmium
osmium extract -b WEST,SOUTH,EAST,NORTH california-latest.osm.pbf -o expanded_area.osm.pbf
```

### 3. Clear Existing Streets Data
```bash
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
-- This will cascade delete to:
-- - streets_reference_32610
-- - streets_blocks_32610 (via foreign key)
-- - block_segments (via cascade from blocks)
-- - block_segment_visited (via cascade from segments)
-- - block_coverage_segments (via cascade from blocks)

TRUNCATE runmap.streets_reference CASCADE;
EOF
```

### 4. Import New OSM Data
```bash
# Import with osm2pgsql
osm2pgsql -d runmap \
  -H 192.168.68.25 \
  -U runmap_user \
  expanded_area.osm.pbf

# Transfer to streets_reference (excluding service roads/alleys)
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
INSERT INTO runmap.streets_reference (osm_id, name, highway, geom)
SELECT osm_id, name, highway, way as geom
FROM planet_osm_line
WHERE highway IS NOT NULL
  AND highway != 'service';  -- Exclude alleys/driveways
EOF
```

### 5. Regenerate Derived Tables

```bash
# Create UTM-projected streets with lengths
psql -h 192.168.68.25 -U runmap_user -d runmap -f db/01_create_tables.sql

# Split streets at intersections to create blocks
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT runmap.split_streets_at_intersections();
EOF
```

### 6. Recreate Segment System

```bash
# Run segment schema setup
psql -h 192.168.68.25 -U runmap_user -d runmap -f db/04_segment_schema.sql

# This will:
# - Create block_segments table (subdivisions of each block)
# - Create block_segment_visited table
# - Create block_coverage_segments view
# - Set up segment-visited tracking functions
```

### 7. Reprocess All Existing Runs

```bash
# Process all existing runs against new blocks/segments
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
-- Truncate old run buffers
TRUNCATE runmap.runs_buffered_subdiv CASCADE;

-- Reprocess each run
DO $$
DECLARE
  run_record RECORD;
  run_count INTEGER := 0;
  total_runs INTEGER;
BEGIN
  SELECT COUNT(*) INTO total_runs FROM runmap.runs_raw;
  RAISE NOTICE 'Reprocessing % runs...', total_runs;

  FOR run_record IN
    SELECT id FROM runmap.runs_raw ORDER BY uploaded_at
  LOOP
    run_count := run_count + 1;

    -- Progress every 10 runs
    IF run_count % 10 = 0 THEN
      RAISE NOTICE 'Processing run % of % (%.0f%%)...',
        run_count, total_runs, (run_count::FLOAT / total_runs * 100);
    END IF;

    -- Buffer and apply to segments
    PERFORM runmap.buffer_one_run_subdiv(run_record.id);
    PERFORM runmap.apply_run_to_segments(run_record.id);
  END LOOP;

  RAISE NOTICE 'Reprocessing complete!';
END $$;

-- Refresh stats
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
EOF
```

### 8. Regenerate Tiles

```bash
# Export new tiles with expanded area
bash scripts/export_tiles_blocks.sh

# Deploy to server
bash scripts/deploy.sh
```

### 9. Verification

```bash
# Check new block count
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT
  (SELECT COUNT(*) FROM runmap.streets_reference) as total_streets,
  (SELECT COUNT(*) FROM runmap.streets_blocks_32610) as total_blocks,
  (SELECT COUNT(*) FROM runmap.block_segments) as total_segments;
EOF

# Check coverage stats
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT * FROM runmap.coverage_stats_blocks;
EOF

# Verify some completed blocks are still marked complete
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT COUNT(*) as complete_blocks
FROM runmap.streets_blocks_32610 b
JOIN runmap.block_coverage_segments bc ON b.block_id = bc.block_id
WHERE bc.coverage_pct >= 90;
EOF
```

## Expected Results

- **Before:** ~2,597 blocks (Sacramento city only)
- **After:** ~3,500-5,000 blocks (depending on expanded area size)
- **Existing coverage:** Should be preserved (1,999+ complete blocks remain complete)
- **New coverage:** Runs that went into expanded area will now show coverage there

## Potential Issues & Solutions

### Issue: Runs outside expanded area
Some runs may be in Portland or other locations outside the new AOI.

**Solution:** They'll fail processing gracefully (no intersecting blocks), or add location-based filtering:
```sql
WHERE location = 'sacramento'
```

### Issue: Processing time
Reprocessing 310+ runs could take 15-30 minutes.

**Solution:** Run during off-hours, or process in batches with progress monitoring.

### Issue: Tile file sizes increase
More blocks = larger tile files.

**Solution:** Monitor tile sizes, consider zoom level adjustments if needed.

## Rollback Plan

If something goes wrong:

```bash
# Restore from backup
psql -h 192.168.68.25 -U runmap_user -d runmap < backup_runmap_YYYYMMDD.sql

# Or just restore streets tables
psql -h 192.168.68.25 -U runmap_user -d runmap < backup_streets_YYYYMMDD.sql

# Rebuild from existing streets
psql -c "SELECT runmap.split_streets_at_intersections();"
psql -f db/04_segment_schema.sql
# (then reprocess runs as above)
```

## Notes

- **All existing run data is safe** - `runs_raw` table is never truncated
- **Coverage recalculates correctly** - Segment-visited system handles this automatically
- **Block IDs will change** - New sequential IDs assigned, but this doesn't affect coverage
- **Foreign keys cascade properly** - Dependent tables clean up automatically
- **Tiles need regeneration** - Users will see expanded area after deploy

## Estimated Timeline

- Download OSM data: 5-10 minutes
- Backup: 2-5 minutes
- Import new streets: 5-10 minutes
- Split at intersections: 3-5 minutes
- Create segments: 5-10 minutes
- Reprocess runs: 15-30 minutes
- Generate tiles: 5-10 minutes
- **Total: ~45-80 minutes**

## References

- [README.md](../README.md) - Original OSM import process
- [db/04_phase1_intersection_split.sql](../db/04_phase1_intersection_split.sql) - Block creation
- [db/04_segment_schema.sql](../db/04_segment_schema.sql) - Segment system
- [CLAUDE.md](../CLAUDE.md) - System architecture
