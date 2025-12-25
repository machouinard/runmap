# Chunk-Based Coverage System

## Overview

The chunk-based coverage system provides **block-level granularity** for tracking running coverage across Sacramento streets. It solves the problem of marking entire long street segments as "covered" when only crossing them perpendicularly.

**Key Innovation:** Two-phase topology-aware subdivision that splits streets at real intersections, then enforces uniform chunk size for consistent rendering.

---

## Architecture

### Data Flow

```
OSM Streets (1,456 segments, avg 175m)
    ↓
Phase 1: Split at Intersections
    ↓
Blocks (2,597 segments, avg 98m, aligned with city grid)
    ↓
Phase 2: Subdivide to 50m Max
    ↓
Chunks (6,456 segments, avg 40m, uniform rendering)
    ↓
Phase 3: Apply Run Buffers
    ↓
Chunk Coverage (per-chunk tracking)
    ↓
Phase 4: Export Tiles
    ↓
PMTiles (streets_unrun/partial/complete, runs)
```

---

## Database Schema

### Source Tables

**`runmap.streets_reference_32610`** - Original OSM streets (unchanged)
- 1,456 rows
- Average length: 175m
- SRID: 32610 (UTM Zone 10N)

**`runmap.runs_raw`** - GPX tracks (unchanged)
- Primary key: `id` (UUID)
- Geometry: MultiLineString, SRID 4326
- Fields: `filename`, `uploaded_at`, `content_hash`

**`runmap.runs_buffered_32610`** - Per-run buffers (unchanged)
- One row per run
- 10m buffer in UTM projection
- Used for coverage calculation

### New Tables (Chunk System)

**`runmap.streets_blocks_32610`** - Intersection-split blocks
- 2,597 rows (from 1,456 streets)
- Created by: `split_streets_at_intersections()`
- Average length: 98.3m
- References parent street via `parent_ogc_fid`

```sql
CREATE TABLE runmap.streets_blocks_32610 (
  block_id SERIAL PRIMARY KEY,
  parent_ogc_fid INT REFERENCES runmap.streets_reference_32610(ogc_fid),
  block_index INT,
  geom_32610 geometry(LineString, 32610),
  block_length_m FLOAT,
  name TEXT,
  highway TEXT
);
```

**`runmap.streets_chunks_32610`** - Uniform chunks (max 50m)
- 6,456 rows (from 2,597 blocks)
- Created by: `subdivide_blocks_to_chunks(50.0)`
- Average length: 39.5m
- Median: 41.1m
- References parent block and original street

```sql
CREATE TABLE runmap.streets_chunks_32610 (
  chunk_id SERIAL PRIMARY KEY,
  block_id INT REFERENCES runmap.streets_blocks_32610(block_id),
  parent_ogc_fid INT,
  chunk_index INT,
  geom_32610 geometry(LineString, 32610),
  chunk_length_m FLOAT,
  name TEXT,
  highway TEXT
);
```

**`runmap.chunk_coverage_32610`** - Coverage tracking (source of truth)
- One row per chunk that has been touched by any run
- Coverage geometry can be LineString or MultiLineString (from ST_Intersection)
- Generated columns for `coverage_pct` and `status`

```sql
CREATE TABLE runmap.chunk_coverage_32610 (
  chunk_id INT PRIMARY KEY REFERENCES runmap.streets_chunks_32610(chunk_id),
  covered_geom geometry(Geometry, 32610),  -- LineString or MultiLineString
  covered_length_m FLOAT,
  total_length_m FLOAT,
  coverage_pct FLOAT GENERATED ALWAYS AS (
    CASE
      WHEN total_length_m > 0 THEN ROUND((covered_length_m / total_length_m * 100)::numeric, 2)
      ELSE 0
    END
  ) STORED,
  status TEXT GENERATED ALWAYS AS (
    CASE
      WHEN covered_length_m < total_length_m * 0.05 THEN 'unrun'
      WHEN covered_length_m < total_length_m * 0.90 THEN 'partial'
      ELSE 'complete'
    END
  ) STORED
);
```

### Status Thresholds

- **Unrun:** <5% coverage (filters perpendicular crossing artifacts)
- **Partial:** 5-90% coverage (genuinely incomplete)
- **Complete:** ≥90% coverage (accounts for GPS gaps at intersections)

---

## Key Functions

### Phase 1: Intersection Split

**`runmap.split_streets_at_intersections()`**
- Finds all points where streets cross each other
- Uses `ST_Split()` to divide streets at intersection points
- Creates blocks that align with real city grid
- Handles topology errors gracefully (keeps original if split fails)

**Runtime:** ~2-5 minutes for 1,456 streets
**Memory:** ~500 MB - 1 GB peak

### Phase 2: Chunk Subdivision

**`runmap.subdivide_blocks_to_chunks(max_chunk_length_m FLOAT DEFAULT 50.0)`**
- Takes blocks from Phase 1
- Keeps blocks ≤50m as single chunks
- Splits blocks >50m into uniform chunks using `ST_LineSubstring()`
- Configurable chunk size (default: 50m)

**Runtime:** ~1-2 minutes for 2,597 blocks
**Memory:** ~200-500 MB peak

### Phase 3: Coverage Calculation

**`runmap.apply_run_to_chunk_coverage(run_uuid UUID)`** - Incremental update
- Gets buffer for specific run from `runs_buffered_32610`
- Finds all chunks that intersect the buffer (spatial index)
- Calculates `ST_Intersection(chunk, buffer)` for each
- Inserts new coverage or unions with existing coverage
- Updates only touched chunks (O(chunks touched), typically 100-300 per run)

**Runtime:** ~10-30 seconds per run
**Memory:** ~300-500 MB (constant, regardless of total runs)

**`runmap.rebuild_chunk_coverage()`** - Full rebuild
- Truncates coverage table
- Processes all runs sequentially using `apply_run_to_chunk_coverage()`
- Useful after changing buffer distance or chunk size

**Runtime:** ~30-90 seconds for 3 runs
**Memory:** ~500 MB - 1 GB peak

### Coverage Algorithm Details

**No Global Union Required:**
- Old system: Unioned all runs → 112GB RAM crash with 11 runs
- New system: Track coverage per-chunk, union within each chunk only
- Memory usage stays constant regardless of total run count

**Per-chunk coverage accumulation:**
```sql
-- On first run touching this chunk:
INSERT covered_geom = ST_Intersection(chunk, run_buffer)

-- On subsequent runs:
UPDATE covered_geom = ST_Union(existing_covered_geom, new_intersection)
```

**Why geometry(Geometry) not geometry(LineString):**
- `ST_Intersection(LineString, MultiPolygon)` can return MultiLineString
- Happens when buffer crosses chunk in multiple places (e.g., GPS wobble)
- Using `Geometry` type accepts LineString, MultiLineString, etc.

---

## Views and Materialized Views

### Status Views (for tile export)

**`runmap.chunks_unrun`** - Chunks with <5% coverage or no coverage
```sql
SELECT c.*, COALESCE(cc.coverage_pct, 0) as coverage_pct
FROM runmap.streets_chunks_32610 c
LEFT JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
WHERE COALESCE(cc.status, 'unrun') = 'unrun';
```

**`runmap.chunks_partial`** - Chunks with 5-90% coverage
**`runmap.chunks_complete`** - Chunks with ≥90% coverage

### Aggregation Views

**`runmap.street_coverage_aggregated`** - Roll up to original streets
- Shows coverage stats per original OSM street
- Aggregates all chunks belonging to each street
- Fields: `total_chunks`, `complete_chunks`, `partial_chunks`, `avg_coverage_pct`

**`runmap.streets_most_complete`** - Top 50 streets by coverage
**`runmap.streets_least_complete`** - Bottom 50 streets (work to do!)

### Statistics

**`runmap.coverage_stats_chunks`** - Materialized view for overall stats
- Refreshed after each run upload
- Fields: `total_chunks`, `unrun_chunks`, `partial_chunks`, `complete_chunks`, `overall_coverage_pct`

```sql
REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;
```

---

## Tile Export

### Script: `scripts/export_tiles_chunks.sh`

**Process:**
1. Export 4 GeoJSON layers from PostGIS (transform to EPSG:4326)
2. Convert to MBTiles using Tippecanoe (zoom 4-14)
3. Convert MBTiles to PMTiles
4. Clean up temporary files

**Layers:**
- `streets_unrun.pmtiles` - Grey layer (~943 KB)
- `streets_partial.pmtiles` - Purple layer (~109 KB)
- `streets_complete.pmtiles` - Green layer (~91 KB)
- `runs.pmtiles` - Red tracks (~25 KB)

**Total size:** ~1.2 MB (vs ~20 MB with old system)

**Export command:**
```bash
bash scripts/export_tiles_chunks.sh
```

**Runtime:** ~2-5 minutes

---

## Current Statistics (3 runs)

### Overall Coverage
- **Total chunks:** 6,456
- **Chunks touched:** 858 (13.3%)
- **Complete chunks:** 432 (6.7%)
- **Partial chunks:** 412 (6.4%)
- **Barely touched:** 14 (0.2%)
- **Overall coverage:** 9.34% of Sacramento

### Coverage by Highway Type
| Highway Type | Total Chunks | Coverage % |
|--------------|--------------|------------|
| Secondary    | 1,136        | 10.4%      |
| Residential  | 4,087        | 9.9%       |
| Primary      | 325          | 9.0%       |
| Tertiary     | 884          | 6.8%       |

### Sample Complete Streets (100% coverage)
- 32nd Street: 11/11 chunks
- 29th Street: 7/7 chunks
- 28th Street: 5/5 chunks
- McKinley Boulevard: 4/4 chunks
- Santa Ynez Way: 4/4 chunks

---

## Workflow: Processing a New Run

### 1. GPX Upload (API)

```python
# In Flask API after GPX ingest
run_id = get_latest_run_id()  # Returns UUID

# 1. Buffer the run (existing function)
db.execute("SELECT runmap.buffer_one_run(%s)", [run_id])

# 2. Apply to chunk coverage (NEW)
db.execute("SELECT runmap.apply_run_to_chunk_coverage(%s::uuid)", [run_id])

# 3. Refresh stats
db.execute("REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks")

# 4. Update tiles version
db.execute("UPDATE runmap.settings SET value = %s WHERE key = 'tiles_version'",
           [int(time.time())])

# 5. Export tiles (async)
subprocess.Popen(['bash', 'scripts/export_tiles_chunks.sh'])
```

### 2. Tile Export (Async)

The export script runs in the background:
- Exports 4 GeoJSON layers
- Converts to PMTiles
- Takes ~2-5 minutes
- Frontend polls `/api/tiles/version` to detect updates

### 3. Frontend Update

Frontend detects new `tiles_version` and reloads map layers:
- Removes old layers
- Adds new PMTiles sources
- Applies styling (grey/purple/green/red)

---

## Performance Characteristics

### Memory Usage

| Operation | Peak RAM | Scales With |
|-----------|----------|-------------|
| Split at intersections | 500 MB - 1 GB | Number of streets (constant) |
| Subdivide to chunks | 200-500 MB | Number of blocks (constant) |
| Apply single run | 300-500 MB | Chunks touched (~100-300) |
| Rebuild all coverage | 500 MB - 1 GB | Number of runs × chunks/run |
| Export tiles | 500 MB - 1 GB | Number of chunks (constant) |

**Key insight:** Memory usage is **constant** per run, not cumulative. Can scale to unlimited runs.

### Processing Time

| Operation | Duration | Notes |
|-----------|----------|-------|
| Phase 1: Intersection split | 2-5 min | One-time setup |
| Phase 2: Chunk subdivision | 1-2 min | One-time setup |
| Phase 3: Apply one run | 10-30 sec | Per upload |
| Phase 3: Rebuild all (3 runs) | 30-90 sec | Full recalculation |
| Phase 4: Export tiles | 2-5 min | After each upload |

### Storage

| Table | Rows | Size | Notes |
|-------|------|------|-------|
| `streets_blocks_32610` | 2,597 | ~3-4 MB | Includes indexes |
| `streets_chunks_32610` | 6,456 | ~7-9 MB | Includes indexes |
| `chunk_coverage_32610` | ~858 | ~2-3 MB | Grows with runs |
| **Total new tables** | | **~12-16 MB** | Negligible |

**Database size:** 577 MB → ~610 MB (+33 MB)

---

## Configuration

### Chunk Size

Default: 50m (configurable)

```sql
-- Change chunk size
SELECT runmap.subdivide_blocks_to_chunks(40.0);  -- 40m chunks
SELECT runmap.subdivide_blocks_to_chunks(25.0);  -- 25m chunks
```

**Recommendation:** 50m is optimal for:
- GPS accuracy (10-20m wide buffer corridor)
- Visual clarity at city zoom levels
- Balance between granularity and performance

See [docs/CHUNK_SIZE_ANALYSIS.md](CHUNK_SIZE_ANALYSIS.md) for detailed comparison.

### Buffer Distance

Default: 10m (from existing `runmap.settings`)

**Recommendation:** Consider reducing to 5-8m with chunk system:
- Chunks are smaller (40m avg vs 175m avg)
- Smaller buffer reduces false positives on parallel streets
- GPS accuracy is typically ±5-10m

```sql
-- Update buffer distance
UPDATE runmap.settings SET value = '5'::jsonb WHERE key = 'buffer_distance_m';

-- Rebuild buffers for all runs
TRUNCATE runmap.runs_buffered_32610;
DO $$
DECLARE run_rec RECORD;
BEGIN
  FOR run_rec IN SELECT id FROM runmap.runs_raw LOOP
    PERFORM runmap.buffer_one_run(run_rec.id);
  END LOOP;
END $$;

-- Rebuild coverage
SELECT runmap.rebuild_chunk_coverage();
```

### Coverage Thresholds

Current thresholds in `chunk_coverage_32610.status`:
- Unrun: <5%
- Partial: 5-90%
- Complete: ≥90%

**To change thresholds:** Modify the generated column definition in `db/06_phase3_coverage_tracking.sql` and recreate the table.

---

## Diagnostic Queries

### Overall Coverage

```sql
SELECT * FROM runmap.coverage_stats_chunks;
```

### Coverage by Status

```sql
SELECT * FROM runmap.coverage_summary;
```

### Streets with Most Coverage

```sql
SELECT * FROM runmap.streets_most_complete LIMIT 20;
```

### Streets with Least Coverage

```sql
SELECT * FROM runmap.streets_least_complete LIMIT 20;
```

### Find Chunks on a Specific Street

```sql
SELECT
  chunk_id,
  chunk_index,
  ROUND(chunk_length_m::numeric, 1) as length_m,
  COALESCE(cc.status, 'unrun') as status,
  COALESCE(ROUND(cc.coverage_pct::numeric, 1), 0) as pct
FROM runmap.streets_chunks_32610 c
LEFT JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
WHERE name = 'P Street'
  AND parent_ogc_fid = (
    SELECT ogc_fid FROM runmap.streets_reference_32610
    WHERE name = 'P Street' ORDER BY total_length_m DESC LIMIT 1
  )
ORDER BY chunk_index;
```

### Chunks Touched by a Specific Run

```sql
SELECT
  c.name,
  c.highway,
  cc.status,
  ROUND(cc.coverage_pct::numeric, 1) as pct
FROM runmap.chunk_coverage_32610 cc
JOIN runmap.streets_chunks_32610 c USING (chunk_id)
WHERE ST_Intersects(
  c.geom_32610,
  (SELECT geom FROM runmap.runs_buffered_32610 WHERE run_id = '<UUID>')
)
ORDER BY cc.coverage_pct DESC;
```

---

## Maintenance

### Rebuild After Schema Changes

If you modify streets, buffer distance, or chunk size:

```bash
# 1. Rebuild blocks and chunks
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT runmap.split_streets_at_intersections();
SELECT runmap.subdivide_blocks_to_chunks(50.0);
EOF

# 2. Rebuild coverage
bash scripts/run_phase3_coverage.sh

# 3. Export tiles
bash scripts/export_tiles_chunks.sh
```

### Check for Issues

**Verify chunk count:**
```sql
SELECT COUNT(*) FROM runmap.streets_chunks_32610;
-- Expected: ~6,000-7,000
```

**Check for orphaned coverage:**
```sql
SELECT COUNT(*) FROM runmap.chunk_coverage_32610 cc
WHERE NOT EXISTS (
  SELECT 1 FROM runmap.streets_chunks_32610 c WHERE c.chunk_id = cc.chunk_id
);
-- Expected: 0
```

**Verify buffer existence:**
```sql
SELECT
  (SELECT COUNT(*) FROM runmap.runs_raw) as total_runs,
  (SELECT COUNT(*) FROM runmap.runs_buffered_32610) as buffered_runs;
-- Should match
```

---

## Migration from Old System

The old segment-based coverage system used:
- `runmap.street_coverage_32610` - One row per street
- `runmap.streets_unrun/partial/complete` - Views based on % thresholds
- Full recalculation on each run (memory explosion)

**Migration completed:**
- ✅ Phase 1: Intersection split (2,597 blocks)
- ✅ Phase 2: Chunk subdivision (6,456 chunks)
- ✅ Phase 3: Coverage calculation (858 chunks covered)
- ✅ Phase 4: Tile export (1.2 MB tiles)

**Old tables preserved:**
- Can keep `street_coverage_32610` for comparison
- Or drop to save space: `DROP TABLE runmap.street_coverage_32610 CASCADE;`

---

## Troubleshooting

### Issue: No coverage calculated

**Check:**
1. Do buffers exist? `SELECT COUNT(*) FROM runmap.runs_buffered_32610;`
2. Do chunks intersect buffers? Run `scripts/debug_coverage.sh`
3. Check function parameters: UUIDs not BIGINTs

### Issue: Geometry type mismatch

**Error:** `Geometry type (MultiLineString) does not match column type (LineString)`

**Fix:** Table must use `geometry(Geometry, 32610)` not `geometry(LineString, 32610)`

```bash
bash scripts/rebuild_coverage_table.sh
```

### Issue: Tiles not loading

**Check:**
1. Tile export completed? `ls -lh tiles/*.pmtiles`
2. Correct projection? Should be EPSG:4326 (WGS84)
3. Frontend pointing to correct tile URLs?

### Issue: High memory usage

**Check:**
1. Are you using `rebuild_chunk_coverage()` repeatedly? (Use incremental updates)
2. Server has adequate RAM? (Needs 2-5 GB free)
3. Too many chunks? (Consider larger chunk size)

---

## Future Enhancements

### Possible Improvements

1. **Smaller buffer distance** (5-8m instead of 10m)
   - More accurate with chunk system
   - Reduces false positives

2. **Variable chunk size by street type**
   - Residential: 50m
   - Primary/Secondary: 100m
   - Would reduce total chunk count

3. **Directional coverage tracking**
   - Track which direction you ran each chunk
   - "Ran both ways" badge for complete streets

4. **Time-based coverage**
   - Track when each chunk was last run
   - Highlight old coverage needing refresh

5. **Coverage goals**
   - Set target % for neighborhoods
   - Track progress over time

6. **Heatmap visualization**
   - Show run frequency per chunk
   - Identify favorite routes

---

## File Reference

### Database Schema
- `db/04_phase1_intersection_split.sql` - Block creation
- `db/05_phase2_chunk_subdivision.sql` - Chunk creation
- `db/06_phase3_coverage_tracking.sql` - Coverage tables and functions

### Scripts
- `scripts/run_phase1_split.sh` - Execute intersection split
- `scripts/verify_phase1.sh` - Verify block creation
- `scripts/run_phase2_subdivision.sh` - Execute chunk subdivision
- `scripts/verify_phase2.sh` - Verify chunk creation
- `scripts/run_phase3_coverage.sh` - Build coverage from all runs
- `scripts/verify_phase3.sh` - Verify coverage results
- `scripts/export_tiles_chunks.sh` - Export PMTiles
- `scripts/debug_coverage.sh` - Debug coverage issues
- `scripts/test_single_run.sh` - Test single run coverage

### Documentation
- `docs/COVERAGE_GRANULARITY_OPTIONS.md` - Original design options
- `docs/CHUNK_SIZE_ANALYSIS.md` - 25m vs 50m analysis
- `docs/IMPLEMENTATION_PLAN_CHUNK_COVERAGE.md` - Technical implementation plan
- `docs/RESOURCE_IMPACT_ANALYSIS.md` - Memory and performance analysis
- `docs/CHUNK_COVERAGE_SYSTEM.md` - This document

---

## Credits

Built incrementally through Phases 1-4 to solve the "perpendicular crossing" problem where entire long street segments were marked as covered when only crossing them briefly.

**Design principles:**
1. Topology-aware (split at real intersections)
2. Uniform rendering (max chunk size enforcement)
3. Incremental updates (constant memory per run)
4. Configurable thresholds (chunk size, buffer distance, coverage %)

**Server specs:**
- 32 GB RAM
- PostgreSQL 16 + PostGIS 3
- Ubuntu server (192.168.68.25)

**Result:** Scalable chunk-based coverage system that provides block-level granularity while maintaining constant memory usage regardless of total run count.
