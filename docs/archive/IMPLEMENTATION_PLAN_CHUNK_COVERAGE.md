# Implementation Plan: Topology-Aware Chunk Coverage

## Overview

Implement a two-phase street subdivision system:
1. **Phase 1:** Split streets at real intersections (topology-based)
2. **Phase 2:** Further subdivide any segments >50m into uniform chunks

This ensures coverage tracking aligns with actual city blocks while maintaining uniform geometry sizes for rendering.

## Architecture Changes

### New Schema Components

```sql
-- 1. Intersection-split streets (block-level segments)
CREATE TABLE runmap.streets_blocks_32610 (
  block_id SERIAL PRIMARY KEY,
  parent_ogc_fid INT REFERENCES runmap.streets_reference_32610(ogc_fid),
  block_index INT,
  geom_32610 geometry(LineString, 32610),
  block_length_m FLOAT,
  -- Metadata from parent
  name TEXT,
  highway TEXT
);

-- 2. Uniform chunks (blocks further subdivided if >50m)
CREATE TABLE runmap.streets_chunks_32610 (
  chunk_id SERIAL PRIMARY KEY,
  block_id INT REFERENCES runmap.streets_blocks_32610(block_id),
  parent_ogc_fid INT,
  chunk_index INT,
  geom_32610 geometry(LineString, 32610),
  chunk_length_m FLOAT,
  -- Metadata
  name TEXT,
  highway TEXT
);
CREATE INDEX idx_chunks_geom ON runmap.streets_chunks_32610 USING GIST(geom_32610);
CREATE INDEX idx_chunks_parent ON runmap.streets_chunks_32610(parent_ogc_fid);

-- 3. Chunk-level coverage (source of truth)
-- NOTE: No global runs union needed - coverage tracked incrementally per chunk
CREATE TABLE runmap.chunk_coverage_32610 (
  chunk_id INT PRIMARY KEY REFERENCES runmap.streets_chunks_32610(chunk_id),
  covered_geom geometry(LineString, 32610),
  covered_length_m FLOAT,
  total_length_m FLOAT,
  coverage_pct FLOAT GENERATED ALWAYS AS (covered_length_m / total_length_m * 100) STORED,
  status TEXT GENERATED ALWAYS AS (
    CASE
      WHEN covered_length_m < total_length_m * 0.05 THEN 'unrun'
      WHEN covered_length_m < total_length_m * 0.90 THEN 'partial'
      ELSE 'complete'
    END
  ) STORED
);
CREATE INDEX idx_chunk_coverage_geom ON runmap.chunk_coverage_32610 USING GIST(covered_geom);
CREATE INDEX idx_chunk_coverage_status ON runmap.chunk_coverage_32610(status);
```

## Implementation Steps

### Step 1: Split Streets at Intersections

**Goal:** Create `streets_blocks_32610` with one segment per block (between intersections)

```sql
-- Function to split streets at intersection points
CREATE OR REPLACE FUNCTION runmap.split_streets_at_intersections()
RETURNS void AS $$
DECLARE
  street_rec RECORD;
  intersection_pts geometry;
  split_geom geometry;
  segment geometry;
  segment_idx INT;
BEGIN
  TRUNCATE runmap.streets_blocks_32610;

  FOR street_rec IN
    SELECT ogc_fid, name, highway, geom_32610, total_length_m
    FROM runmap.streets_reference_32610
  LOOP
    -- Find all intersection points for this street
    -- (endpoints of other streets that touch this street's geometry)
    SELECT ST_Union(pts) INTO intersection_pts
    FROM (
      SELECT ST_Intersection(street_rec.geom_32610, other.geom_32610) AS pts
      FROM runmap.streets_reference_32610 other
      WHERE other.ogc_fid != street_rec.ogc_fid
        AND ST_Intersects(street_rec.geom_32610, other.geom_32610)
        AND ST_GeometryType(ST_Intersection(street_rec.geom_32610, other.geom_32610)) = 'ST_Point'
    ) t
    WHERE pts IS NOT NULL;

    -- If no intersections found, keep original segment
    IF intersection_pts IS NULL THEN
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES
        (street_rec.ogc_fid, 0, street_rec.geom_32610, street_rec.total_length_m, street_rec.name, street_rec.highway);
      CONTINUE;
    END IF;

    -- Split street at intersection points
    split_geom := ST_Split(street_rec.geom_32610, intersection_pts);

    -- Insert each resulting segment as a block
    segment_idx := 0;
    FOR segment IN
      SELECT geom FROM ST_Dump(split_geom)
    LOOP
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES (
        street_rec.ogc_fid,
        segment_idx,
        segment,
        ST_Length(segment),
        street_rec.name,
        street_rec.highway
      );
      segment_idx := segment_idx + 1;
    END LOOP;
  END LOOP;
END;
$$ LANGUAGE plpgsql;
```

### Step 2: Further Subdivide Long Blocks

**Goal:** Create `streets_chunks_32610` by splitting blocks >50m into uniform chunks

```sql
CREATE OR REPLACE FUNCTION runmap.subdivide_blocks_to_chunks(max_chunk_length_m FLOAT DEFAULT 50.0)
RETURNS void AS $$
DECLARE
  block_rec RECORD;
  num_chunks INT;
  chunk_idx INT;
  chunk_start FLOAT;
  chunk_end FLOAT;
  chunk_geom geometry;
BEGIN
  TRUNCATE runmap.streets_chunks_32610;

  FOR block_rec IN
    SELECT block_id, parent_ogc_fid, geom_32610, block_length_m, name, highway
    FROM runmap.streets_blocks_32610
  LOOP
    -- If block is already short enough, keep as single chunk
    IF block_rec.block_length_m <= max_chunk_length_m THEN
      INSERT INTO runmap.streets_chunks_32610
        (block_id, parent_ogc_fid, chunk_index, geom_32610, chunk_length_m, name, highway)
      VALUES (
        block_rec.block_id,
        block_rec.parent_ogc_fid,
        0,
        block_rec.geom_32610,
        block_rec.block_length_m,
        block_rec.name,
        block_rec.highway
      );
      CONTINUE;
    END IF;

    -- Calculate number of chunks needed
    num_chunks := CEIL(block_rec.block_length_m / max_chunk_length_m);

    -- Create uniform chunks using ST_LineSubstring
    FOR chunk_idx IN 0..(num_chunks - 1) LOOP
      chunk_start := (chunk_idx::FLOAT / num_chunks);
      chunk_end := ((chunk_idx + 1)::FLOAT / num_chunks);

      chunk_geom := ST_LineSubstring(block_rec.geom_32610, chunk_start, chunk_end);

      INSERT INTO runmap.streets_chunks_32610
        (block_id, parent_ogc_fid, chunk_index, geom_32610, chunk_length_m, name, highway)
      VALUES (
        block_rec.block_id,
        block_rec.parent_ogc_fid,
        chunk_idx,
        chunk_geom,
        ST_Length(chunk_geom),
        block_rec.name,
        block_rec.highway
      );
    END LOOP;
  END LOOP;
END;
$$ LANGUAGE plpgsql;
```

### Step 3: Incremental Coverage Calculation

**Goal:** Update coverage for only chunks touched by a new run

**NOTE:** No global runs union needed. Each run's buffer is processed individually and
coverage is accumulated per-chunk using ST_Union on the covered_geom field. This keeps
memory usage constant regardless of total run count.

```sql
-- Apply a single run to chunk coverage (incremental)
CREATE OR REPLACE FUNCTION runmap.apply_run_to_chunk_coverage(run_gid BIGINT)
RETURNS void AS $$
DECLARE
  run_buffer geometry;
  chunk_rec RECORD;
  new_coverage geometry;
  new_coverage_length FLOAT;
BEGIN
  -- Get this run's buffer
  SELECT geom INTO run_buffer
  FROM runmap.runs_buffered_32610
  WHERE run_id = run_gid;

  IF run_buffer IS NULL THEN
    RAISE EXCEPTION 'No buffer found for run_id %', run_gid;
  END IF;

  -- Update only chunks that intersect this run's buffer
  FOR chunk_rec IN
    SELECT chunk_id, geom_32610, chunk_length_m
    FROM runmap.streets_chunks_32610
    WHERE ST_Intersects(geom_32610, run_buffer)
  LOOP
    -- Calculate new coverage geometry
    new_coverage := ST_Intersection(chunk_rec.geom_32610, run_buffer);

    -- Skip if intersection is not a line/multiline (point touches don't count)
    IF ST_GeometryType(new_coverage) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
      CONTINUE;
    END IF;

    new_coverage_length := ST_Length(new_coverage);

    -- Insert or update coverage
    INSERT INTO runmap.chunk_coverage_32610 (chunk_id, covered_geom, covered_length_m, total_length_m)
    VALUES (chunk_rec.chunk_id, new_coverage, new_coverage_length, chunk_rec.chunk_length_m)
    ON CONFLICT (chunk_id) DO UPDATE SET
      covered_geom = ST_Union(runmap.chunk_coverage_32610.covered_geom, EXCLUDED.covered_geom),
      covered_length_m = ST_Length(ST_Union(runmap.chunk_coverage_32610.covered_geom, EXCLUDED.covered_geom)),
      total_length_m = EXCLUDED.total_length_m;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Full rebuild (process all runs)
CREATE OR REPLACE FUNCTION runmap.rebuild_chunk_coverage()
RETURNS void AS $$
DECLARE
  run_gid BIGINT;
BEGIN
  TRUNCATE runmap.chunk_coverage_32610;

  FOR run_gid IN
    SELECT gid FROM runmap.runs_raw ORDER BY gid
  LOOP
    PERFORM runmap.apply_run_to_chunk_coverage(run_gid);
  END LOOP;

  RAISE NOTICE 'Rebuilt coverage for % runs', (SELECT COUNT(*) FROM runmap.runs_raw);
END;
$$ LANGUAGE plpgsql;
```

### Step 4: Tile Export Views

**Goal:** Export chunks grouped by status for map display

```sql
-- Chunks by status (for tile export)
CREATE OR REPLACE VIEW runmap.chunks_unrun AS
SELECT
  c.chunk_id,
  c.geom_32610,
  c.name,
  c.highway,
  COALESCE(cc.coverage_pct, 0) as coverage_pct
FROM runmap.streets_chunks_32610 c
LEFT JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
WHERE COALESCE(cc.status, 'unrun') = 'unrun';

CREATE OR REPLACE VIEW runmap.chunks_partial AS
SELECT
  c.chunk_id,
  c.geom_32610,
  c.name,
  c.highway,
  cc.coverage_pct
FROM runmap.streets_chunks_32610 c
JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
WHERE cc.status = 'partial';

CREATE OR REPLACE VIEW runmap.chunks_complete AS
SELECT
  c.chunk_id,
  c.geom_32610,
  c.name,
  c.highway,
  cc.coverage_pct
FROM runmap.streets_chunks_32610 c
JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
WHERE cc.status = 'complete';

-- Aggregate stats per original street
CREATE OR REPLACE VIEW runmap.street_coverage_aggregated AS
SELECT
  s.ogc_fid,
  s.name,
  s.highway,
  COUNT(c.chunk_id) as total_chunks,
  COUNT(cc.chunk_id) FILTER (WHERE cc.status = 'complete') as complete_chunks,
  COUNT(cc.chunk_id) FILTER (WHERE cc.status = 'partial') as partial_chunks,
  COUNT(c.chunk_id) - COALESCE(COUNT(cc.chunk_id), 0) as unrun_chunks,
  ROUND(AVG(COALESCE(cc.coverage_pct, 0))::numeric, 1) as avg_coverage_pct,
  SUM(c.chunk_length_m) as total_length_m,
  SUM(COALESCE(cc.covered_length_m, 0)) as covered_length_m
FROM runmap.streets_reference_32610 s
JOIN runmap.streets_chunks_32610 c ON c.parent_ogc_fid = s.ogc_fid
LEFT JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
GROUP BY s.ogc_fid, s.name, s.highway;
```

### Step 5: Overall Coverage Stats

```sql
CREATE MATERIALIZED VIEW runmap.coverage_stats_chunks AS
SELECT
  (SELECT COUNT(*) FROM runmap.streets_chunks_32610) as total_chunks,
  (SELECT COUNT(*) FROM runmap.chunk_coverage_32610 WHERE status = 'unrun') as unrun_chunks,
  (SELECT COUNT(*) FROM runmap.chunk_coverage_32610 WHERE status = 'partial') as partial_chunks,
  (SELECT COUNT(*) FROM runmap.chunk_coverage_32610 WHERE status = 'complete') as complete_chunks,
  (SELECT SUM(chunk_length_m) FROM runmap.streets_chunks_32610) as total_length_m,
  (SELECT SUM(covered_length_m) FROM runmap.chunk_coverage_32610) as covered_length_m,
  (SELECT ROUND((SUM(covered_length_m) / SUM(total_length_m) * 100)::numeric, 2)
   FROM runmap.chunk_coverage_32610) as overall_coverage_pct;
```

## Migration Process

1. **Create new schema** (run SQL above)
2. **Build block/chunk tables:**
   ```sql
   SELECT runmap.split_streets_at_intersections();
   SELECT runmap.subdivide_blocks_to_chunks(50.0);
   ```
3. **Rebuild coverage from existing runs:**
   ```sql
   SELECT runmap.rebuild_chunk_coverage();
   REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;
   ```
4. **Update tile export script** to use chunk views instead of street views
5. **Update API** to call chunk coverage functions on upload
6. **Export new tiles**

## Updated Upload Workflow

When a new GPX is uploaded:

```python
# In Flask API after GPX ingest
run_id = get_latest_run_id()

# 1. Buffer the run
db.execute("SELECT runmap.buffer_one_run(%s)", [run_id])

# 2. Apply to chunk coverage (incremental)
db.execute("SELECT runmap.apply_run_to_chunk_coverage(%s)", [run_id])

# 3. Refresh stats
db.execute("REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks")

# 4. Update tiles version
db.execute("UPDATE runmap.settings SET value = %s WHERE key = 'tiles_version'",
           [int(time.time())])

# 5. Export tiles (async)
subprocess.Popen(['bash', 'scripts/export_tiles_chunks.sh'])
```

## Tile Export Script Updates

Create `scripts/export_tiles_chunks.sh`:

```bash
#!/bin/bash
set -e

TILES_DIR=${TILES_DIR:-tiles}
TMP_DIR=${TMP_DIR:-/tmp/runmap_tiles}
mkdir -p "$TMP_DIR"

# Export chunks by status (transform to 3857 for web display)
ogr2ogr -f GeoJSON "$TMP_DIR/chunks_unrun.geojson" \
  PG:"dbname=runmap user=runmap_user" \
  -sql "SELECT chunk_id, ST_Transform(geom_32610, 3857) as geometry, name, highway, coverage_pct FROM runmap.chunks_unrun" \
  -t_srs EPSG:3857

ogr2ogr -f GeoJSON "$TMP_DIR/chunks_partial.geojson" \
  PG:"dbname=runmap user=runmap_user" \
  -sql "SELECT chunk_id, ST_Transform(geom_32610, 3857) as geometry, name, highway, coverage_pct FROM runmap.chunks_partial" \
  -t_srs EPSG:3857

ogr2ogr -f GeoJSON "$TMP_DIR/chunks_complete.geojson" \
  PG:"dbname=runmap user=runmap_user" \
  -sql "SELECT chunk_id, ST_Transform(geom_32610, 3857) as geometry, name, highway, coverage_pct FROM runmap.chunks_complete" \
  -t_srs EPSG:3857

# Convert to PMTiles (unrun/partial/complete)
for status in unrun partial complete; do
  if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/chunks_$status.geojson"; then
    tippecanoe -o "$TMP_DIR/streets_$status.mbtiles" \
      -Z4 -z14 --force \
      -l "streets_$status" \
      "$TMP_DIR/chunks_$status.geojson"

    pmtiles convert "$TMP_DIR/streets_$status.mbtiles" "$TILES_DIR/streets_$status.pmtiles"
  fi
done

# Runs and coverage buffers unchanged
# ... (keep existing run/coverage export logic)

echo "Chunk-based tiles exported successfully"
```

## Performance Considerations

**Estimated table sizes:**
- Original streets: 1,456 segments
- After intersection split: ~3,000-5,000 blocks (est. 3-4 intersections per street)
- After 50m chunking: ~10,000-15,000 chunks (est. 2-3 chunks per block)

**Query performance:**
- Spatial indexes on all geometry columns
- Parent FK indexes for aggregation queries
- Generated columns avoid recalculation

**Memory usage:**
- Incremental updates: O(chunks touched by run) ~50-200 chunks per run
- Full rebuild: O(total chunks) but sequential processing, ~5-10GB max

## Buffer Size Adjustment

Changed from 10m to smaller buffer (3-8m recommendation):

```sql
-- Update buffer function to use smaller radius
CREATE OR REPLACE FUNCTION runmap.buffer_one_run(run_gid BIGINT)
RETURNS void AS $$
DECLARE
  buffer_dist_m FLOAT;
BEGIN
  -- Get buffer distance from settings (now defaults to 5m)
  SELECT (value::jsonb)::float INTO buffer_dist_m
  FROM runmap.settings WHERE key = 'buffer_distance_m';

  IF buffer_dist_m IS NULL THEN
    buffer_dist_m := 5.0; -- Changed from 10.0
  END IF;

  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  SELECT
    gid,
    ST_Buffer(ST_Transform(geom, 32610), buffer_dist_m)
  FROM runmap.runs_raw
  WHERE gid = run_gid
  ON CONFLICT (run_id) DO UPDATE SET geom = EXCLUDED.geom;
END;
$$ LANGUAGE plpgsql;

-- Update settings
UPDATE runmap.settings SET value = '5'::jsonb WHERE key = 'buffer_distance_m';
```

## Testing Plan

1. **Verify chunk creation:**
   - Check that blocks align with intersections
   - Verify no chunks >50m
   - Spot-check known streets (e.g., "P Street" should be ~30 blocks)

2. **Test coverage calculation:**
   - Cross a street perpendicularly - should mark 1-2 chunks only
   - Run full block - should mark all chunks in that block
   - Run partial block - should mark proportional chunks

3. **Visual verification:**
   - Load tiles in map
   - Check that perpendicular crossings show small green segments
   - Verify full block runs show complete block coverage

4. **Performance testing:**
   - Time full rebuild with all existing runs
   - Measure incremental update time per run
   - Check tile export time with ~10-15k chunks

## Rollback Plan

If chunk-based system has issues:

1. Keep old tables (`streets_reference_32610`, `street_coverage_32610`)
2. Can revert API to use old functions
3. Re-export tiles from old views
4. Investigate/fix chunk system offline

All new tables use different names, so no data loss risk.
