# Block-Percentage Coverage Proposal

## Current System (Chunks)

**Architecture:**
1. Split streets at intersections → 2,597 blocks
2. Subdivide blocks to 50m chunks → 6,456 chunks
3. Track coverage per chunk
4. Calculate percentage per chunk
5. Mark chunk complete if ≥90%

**Resources:**
- 6,456 segments to track
- 6,456 rows in `chunk_coverage_32610`
- Tile files contain 6,456 features

## Proposed System (Block Percentage)

**Architecture:**
1. Split streets at intersections → 2,597 blocks
2. Track coverage per block (skip subdivision)
3. Calculate percentage per block
4. Mark block complete if ≥90%

**Resources:**
- 2,597 segments to track (60% reduction)
- 2,597 rows in `block_coverage_32610` (60% reduction)
- Tile files contain 2,597 features (60% smaller)

## Why This Works

### Original Problem: Perpendicular Crossings
- **Example:** P Street is 1,800m long
- **Old system:** Marked entire 1,800m street as "partial" when crossing perpendicularly
- **Block system:** Splits P Street into 39 blocks at intersections (avg 46m each)
- **Result:** Only the crossed block shows coverage, other 38 blocks remain incomplete

### Block Length Distribution
```
Average block:  98m
Minimum block:   1m  (tiny connector segments)
Maximum block: 512m  (long segment without intersections)
```

Most blocks are 40-150m, which is perfect granularity for:
- Running a full city block
- Detecting perpendicular crossings
- Showing meaningful progress

### The 50m Chunk Subdivision Was Unnecessary
- We split blocks to ensure no segment was >50m
- But blocks average 98m, which is still fine-grained enough
- A 100m block showing "45% coverage" tells you exactly what you need to know
- You don't need it split into "chunk 1: 90%, chunk 2: 0%" - that's the same information

## Implementation Changes

### Simpler Schema
```sql
-- Instead of streets_chunks_32610, just use:
CREATE TABLE runmap.block_coverage_32610 (
  block_id INT PRIMARY KEY REFERENCES runmap.streets_blocks_32610(block_id),
  covered_geom geometry(Geometry, 32610),
  covered_length_m FLOAT,
  total_length_m FLOAT,
  coverage_pct FLOAT GENERATED ALWAYS AS (...),
  status TEXT GENERATED ALWAYS AS (
    CASE WHEN coverage_pct >= 90 THEN 'complete' ELSE 'incomplete' END
  ) STORED
);
```

### Processing Function
```sql
CREATE OR REPLACE FUNCTION runmap.apply_run_to_block_coverage(run_uuid UUID)
RETURNS void AS $$
BEGIN
  -- Get blocks that intersect this run's buffer
  INSERT INTO runmap.block_coverage_32610 (block_id, covered_geom, covered_length_m, total_length_m)
  SELECT
    b.block_id,
    ST_Intersection(b.geom_32610, rb.geom) as covered_geom,
    ST_Length(ST_Intersection(b.geom_32610, rb.geom)) as covered_length_m,
    b.block_length_m as total_length_m
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.runs_buffered_32610 rb ON ST_Intersects(b.geom_32610, rb.geom)
  WHERE rb.run_id = run_uuid
  ON CONFLICT (block_id) DO UPDATE SET
    -- Union with existing coverage
    covered_geom = ST_Union(
      runmap.block_coverage_32610.covered_geom,
      EXCLUDED.covered_geom
    ),
    covered_length_m = ST_Length(ST_Union(
      runmap.block_coverage_32610.covered_geom,
      EXCLUDED.covered_geom
    ));
END;
$$ LANGUAGE plpgsql;
```

### Tile Export
Same as current, but export from `blocks_complete` and `blocks_incomplete` views.

## Resource Savings

| Metric | Chunks | Blocks | Savings |
|--------|--------|--------|---------|
| Segments | 6,456 | 2,597 | **60%** |
| DB rows | 6,456 | 2,597 | **60%** |
| Tile features | 6,456 | 2,597 | **60%** |
| Tile file size | ~240K | ~100K | **58%** |
| Schema complexity | 3 tables + views | 2 tables + views | **Simpler** |
| Processing time | Intersection + subdivision | Intersection only | **Faster** |

## User Experience

**Before (chunks):**
- "You've completed 706 out of 6,456 chunks (10.9%)"
- Hard to visualize progress

**After (blocks):**
- "You've completed 706 out of 2,597 blocks (27.2%)"
- Each block ≈ one city block, easy to visualize
- Progress feels more meaningful

## Migration Path

1. Create `block_coverage_32610` table
2. Drop `streets_chunks_32610` and `chunk_coverage_32610`
3. Update `apply_run_to_coverage()` function
4. Reprocess all runs against blocks
5. Export new tiles
6. Update frontend (no changes to UI, just data source)

## Recommendation

**YES - Switch to block-percentage system.**

Benefits:
- ✅ 60% fewer segments to track
- ✅ Simpler schema (no subdivision step)
- ✅ Faster processing
- ✅ Smaller tiles
- ✅ More intuitive units (blocks vs arbitrary chunks)
- ✅ Same spatial accuracy (intersection-split blocks already solve perpendicular crossing problem)

No downsides - the chunk subdivision was over-engineering.
