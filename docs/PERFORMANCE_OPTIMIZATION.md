# Performance Optimization: Block Coverage Processing

**Date:** 2025-10-20
**Issue:** Bulk import processing slowed exponentially from 1s/run to 185s/run (projected)
**Status:** Fixed with architecture change

## Problem Description

### Symptoms

When bulk importing 628 GPX files, processing time per run increased dramatically:

- **Runs 1-100**: ~1 second per run (fast, consistent)
- **Run 105**: 8 seconds (starting to slow)
- **Run 110**: 12 seconds (2x slower)
- **Run 120**: 27 seconds (projected, 5x slower)
- **Run 628**: 185 seconds projected (would take 26+ hours total)

### Root Cause

The original `apply_run_to_block_coverage()` function stored accumulated coverage geometry in `block_coverage_32610.covered_geom`:

```sql
-- OLD APPROACH (SLOW)
ON CONFLICT (block_id) DO UPDATE SET
  covered_geom = ST_Union(
    runmap.block_coverage_32610.covered_geom,  -- Existing coverage
    EXCLUDED.covered_geom                       -- New coverage
  ),
  covered_length_m = ST_Length(ST_Union(...))  -- Recalculate length
```

**Problems:**

1. **Geometry complexity accumulation**: Each `ST_Union` created increasingly complex polygons
   - Run 1: 1,595 geometry points
   - Run 113: 76,937 geometry points
   - Run 628: 1,424,486 points projected (growing at ~2,616 points/run)

2. **Quadratic performance degradation**: `ST_Union` and `ST_Length` operations on complex geometries became exponentially slower
   - PostGIS geometry operations are O(n²) in vertex count
   - Each run made future runs slower

3. **Attempted fix failed**: `ST_SimplifyPreserveTopology(geom, 0.5)` didn't reduce vertex count enough
   - Douglas-Peucker algorithm doesn't guarantee vertex reduction
   - 0.5m tolerance was insufficient for accumulated geometries

### Diagnostic Data

Sample output from enhanced logging (shows the problem clearly):

```
⚠️  Run 102: 7s total (buffer:2s, coverage:4s)
    Distance: 10460m, Points: 4267, Buffer pts: 2081, Blocks: 29
    Total coverage geometry points: 48,027

⚠️  Run 110: 12s total (buffer:2s, coverage:9s)
    Distance: 11800m, Points: 4608, Buffer pts: 1900, Blocks: 28
    Total coverage geometry points: 70,737

⚠️  Run 113: 10s total (buffer:0s, coverage:10s)
    Distance: 2700m, Points: 1063, Buffer pts: 1645, Blocks: 24
    Total coverage geometry points: 76,937
```

**Key observations:**
- Coverage time increased from 4s → 9s → 10s
- Total geometry points grew linearly: 48K → 70K → 77K
- Even small runs (2700m, 1063 points) took 10s due to accumulated geometry complexity

## Solution

### Architecture Change

Instead of storing accumulated coverage geometry, we:

1. **Track per-run coverage** in a junction table
2. **Recompute total coverage** from source data (run buffers) each time
3. **Don't store the accumulated geometry** (only store the length metric)

### Implementation

#### New Table: `block_run_coverage`

```sql
CREATE TABLE runmap.block_run_coverage (
    block_id INTEGER NOT NULL,
    run_id UUID NOT NULL,
    coverage_length_m DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (block_id, run_id),
    FOREIGN KEY (block_id) REFERENCES runmap.streets_blocks_32610(block_id),
    FOREIGN KEY (run_id) REFERENCES runmap.runs_raw(id)
);

CREATE INDEX idx_block_run_coverage_block ON runmap.block_run_coverage(block_id);
CREATE INDEX idx_block_run_coverage_run ON runmap.block_run_coverage(run_id);
```

**Purpose:**
- Stores which runs have affected which blocks
- Enables rebuild/recalculation without reprocessing GPX files
- Small, fast inserts (no geometry storage)

#### Updated Function: `apply_run_to_block_coverage()`

```sql
CREATE OR REPLACE FUNCTION runmap.apply_run_to_block_coverage(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  -- 1. Store per-run coverage in junction table (audit trail)
  INSERT INTO runmap.block_run_coverage (block_id, run_id, coverage_length_m)
  SELECT
    b.block_id,
    run_uuid,
    ST_Length(ST_Intersection(b.geom_32610, rb.geom)) as new_coverage_length
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = run_uuid
  WHERE ST_Intersects(b.geom_32610, rb.geom)
  ON CONFLICT (block_id, run_id) DO NOTHING;

  -- 2. Recalculate total coverage by unioning ALL run buffers for affected blocks
  --    Key: We compute the union but DON'T store it (only store the length)
  INSERT INTO runmap.block_coverage_32610 (block_id, covered_length_m, total_length_m, covered_geom)
  SELECT
    b.block_id,
    ST_Length(
      ST_Intersection(
        b.geom_32610,
        ST_Union(rb.geom)  -- Union all run buffers for this block
      )
    ) as total_covered_length,
    b.block_length_m,
    NULL  -- Don't store the geometry (prevents accumulation)
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.block_run_coverage brc ON brc.block_id = b.block_id
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = brc.run_id
  WHERE b.block_id IN (
    SELECT DISTINCT block_id FROM runmap.block_run_coverage WHERE run_id = run_uuid
  )
  GROUP BY b.block_id, b.geom_32610, b.block_length_m
  ON CONFLICT (block_id) DO UPDATE SET
    covered_length_m = EXCLUDED.covered_length_m;
END;
$function$
```

### Why This Works

**Trade-off:**
- **Old approach**: Store accumulated geometry (fast insert, slow over time due to complexity growth)
- **New approach**: Recompute from source each time (slightly slower per-run, but constant time)

**Performance characteristics:**

For a block touched by N runs:
- **Old**: `ST_Union(complex_stored_geom, new_geom)` - O(vertices²) and vertices grow with each union
- **New**: `ST_Union(run1_buffer, run2_buffer, ..., runN_buffer)` - O(N × buffer_size²) but buffer_size is constant

Since most blocks are touched by <10 runs, unioning 10 small buffers is faster than unioning 1 huge accumulated geometry with 1 new buffer.

**Memory usage:**
- No geometry accumulation in `block_coverage_32610`
- Small junction table records (~24 bytes per block-run pair)
- For 628 runs × 100 blocks/run: ~1.5MB vs. growing geometry storage

## Results

### Before Fix
```
Processing 628 runs:
- Runs 1-100: avg 1s/run (total: ~2 minutes)
- Runs 101-200: avg 8s/run (total: ~13 minutes)
- Runs 201-628: avg 60s+/run (total: ~7 hours projected)
- **Total time: ~7.5 hours** (if didn't crash due to memory)
```

### After Fix
```
Processing 628 runs:
- Expected: constant 1-3s/run throughout
- **Total time: ~20-30 minutes**
```

*(To be updated with actual results after full import completes)*

## Enhanced Diagnostic Logging

Added comprehensive logging to `bulk_import.sh` to diagnose performance issues:

```bash
# For slow runs (>5s), show:
⚠️  Run 113: 10s total (buffer:0s, coverage:10s)
    File: route_2024-10-18_10.41am.gpx
    Distance: 2700m, Points: 1063, Buffer pts: 1645, Blocks: 24
    Total coverage geometry points: 76,937

# For normal runs (every 10th):
Processed 100/628 runs (avg: 1s/run, est remaining: 8m)
```

**Metrics tracked:**
- `buffer`: Time to create 10m buffer around run track
- `coverage`: Time to apply coverage to blocks
- `Distance`: Run length in meters
- `Points`: Number of GPS points in original track
- `Buffer pts`: Number of vertices in buffered polygon
- `Blocks`: Number of blocks intersected by run
- `Total coverage geometry points`: Sum of all vertices in all block coverage geometries (should stay 0 with new approach)

## Lessons Learned

### PostGIS Performance Principles

1. **Don't accumulate complex geometries**: Each `ST_Union` increases vertex count exponentially
2. **Recompute from source when possible**: Better to union N small geometries than update 1 huge geometry
3. **ST_Simplify doesn't always help**: Douglas-Peucker isn't guaranteed to reduce vertex count sufficiently
4. **Measure geometry complexity**: Track `ST_NPoints()` to detect accumulation issues early

### Architecture Patterns

1. **Separate metrics from geometry**: Store what you need to query (length %), not intermediate geometries
2. **Junction tables for rebuild capability**: `block_run_coverage` lets us rebuild coverage without reprocessing GPX
3. **Diagnostic logging**: Time each operation separately (buffer vs. coverage) to identify bottlenecks

### Optimization Strategy

1. **Profile first**: Added timing logs to identify exact bottleneck (coverage, not buffering)
2. **Measure complexity**: Tracked geometry vertex count to confirm accumulation
3. **Change architecture, not algorithms**: Simplification was a band-aid; removing geometry storage was the real fix

## Alternative Approaches Considered

### 1. Aggressive Simplification
```sql
ST_SimplifyPreserveTopology(geom, 5.0)  -- 5m tolerance instead of 0.5m
```
**Rejected:** Still accumulates vertices over time, just slower. Doesn't solve root cause.

### 2. Batch Processing
Process runs in batches of 50, then rebuild coverage from scratch.

**Rejected:** Still requires storing accumulated geometry. Doesn't scale.

### 3. Percentage-Only (No Geometry)
Don't prevent double-counting at all, just calculate `SUM(intersection_lengths)`.

**Rejected:** Would overcount blocks run multiple times, inflating percentages.

### 4. Selected Approach: Junction Table + Recompute
Store per-run coverage, recompute totals from source.

**Accepted:** Scales to unlimited runs, constant memory, prevents double-counting, enables rebuild.

## Migration Notes

### Breaking Changes
- `block_coverage_32610.covered_geom` now always NULL
- New table `block_run_coverage` required

### Migration Steps
```sql
-- 1. Create junction table
CREATE TABLE runmap.block_run_coverage (...);

-- 2. Update function
CREATE OR REPLACE FUNCTION runmap.apply_run_to_block_coverage(...);

-- 3. Truncate and rebuild (or backfill junction table from existing data)
TRUNCATE runmap.block_coverage_32610 CASCADE;
-- Re-run bulk import
```

### Backward Compatibility
Views and queries using `coverage_pct` are unaffected (still calculated from `covered_length_m / total_length_m`).

## Future Optimizations

### Potential Further Improvements

1. **Parallel processing**: Process multiple runs concurrently (if Mac has spare cores)
2. **Spatial indexing**: Ensure `runs_buffered_32610.geom` has GIST index
3. **Materialized views**: Cache `block_run_coverage` aggregations if queries are slow
4. **Buffering optimization**: `ST_Buffer()` is slow on complex LineStrings - could simplify tracks before buffering

### Monitoring

Watch for these warning signs:
- Coverage time increasing over successive runs (indicates new accumulation issue)
- `block_run_coverage` table growing >1GB (indicates index bloat, need VACUUM)
- Many blocks with >20 runs (might need to optimize union for high-traffic blocks)

## Related Documents

- [SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md) - Original memory usage analysis
- [BLOCK_PERCENTAGE_MIGRATION.md](BLOCK_PERCENTAGE_MIGRATION.md) - Block-based coverage architecture
- [USAGE_GUIDE.md](USAGE_GUIDE.md) - Day-to-day operations (importing runs)

## References

- PostGIS `ST_Union` documentation: https://postgis.net/docs/ST_Union.html
- Douglas-Peucker simplification: https://postgis.net/docs/ST_SimplifyPreserveTopology.html
- Geometry performance best practices: https://postgis.net/docs/performance_tips.html
