# ST_Subdivide Integration for RunMap

**Date:** 2025-10-20
**Purpose:** Integrate ST_Subdivide optimization into our junction table architecture
**Status:** Proposed - awaiting testing

---

## Executive Summary

External optimization guides (docs/5/ directory) suggest using `ST_Subdivide` to speed up geometry intersections. This document:

1. **Explains why their additive coverage approach doesn't work** (double-counting bug)
2. **Extracts the ST_Subdivide technique** and adapts it to our architecture
3. **Proposes a benchmark protocol** to measure improvements
4. **Adds performance tracking** to monitor optimization results over time

**Key Finding:** ST_Subdivide is orthogonal to architecture choice - we can add it to our current junction table approach without migration.

---

## Why Their Additive Approach Doesn't Work

### The Bug in External Documents

All three external optimization guides suggest this pattern:

```sql
-- From runmap_migration.sql line 149
INSERT INTO runmap.block_coverage (block_id, len_hit_m, ...)
SELECT ...
ON CONFLICT (block_id) DO UPDATE
SET len_hit_m = runmap.block_coverage.len_hit_m + EXCLUDED.len_hit_m;  -- ❌ WRONG
```

### Why This Causes Double-Counting

**Example Block:** "25th Street" - 100 meters long

**Run 1:** Covers 0-60m (60m of coverage)
```
|████████████████████------------|
0m              60m          100m
```
After Run 1: `len_hit_m = 60` ✅

**Run 2:** Covers 40-100m (60m of coverage)
```
|------------████████████████████|
0m      40m                  100m
```

**With Additive Approach:**
```sql
len_hit_m = 60 + 60 = 120  -- ❌ 120% coverage of 100m block!
```

**The overlap (40-60m) is counted twice.**

### Our Approach (Correct)

```sql
-- Union all run buffers for the block, then measure
ST_Length(
  ST_Intersection(
    block.geom,
    ST_Union(run1_buffer, run2_buffer)  -- Merges overlapping areas
  )
)
-- Result: 100m coverage (correct) ✅
```

The union operation merges the overlapping 40-60m section, counting it only once.

### Could We Fix Their Approach?

**Yes, by storing geometries instead of lengths:**

```sql
-- Store intersection geometries (not lengths)
block_coverage_runs (run_id, block_id, intersection_geom)

-- Calculate total by unioning geometries
SELECT block_id, ST_Length(ST_Union(intersection_geom))
FROM block_coverage_runs
GROUP BY block_id;
```

**But this is functionally identical to what we're already doing!**

Our approach:
- Store run buffers in `runs_buffered_32610`
- Compute `ST_Intersection(block, buffer)` on demand
- Union the intersections

Their fixed approach:
- Store intersections in `block_coverage_runs`
- Union the stored intersections

**Trade-off:**
- Storing intersections: Faster queries (no re-intersection), more storage
- Computing intersections: Slower queries, less storage

**Verdict:** Not worth migrating. The performance difference would be minimal, and ST_Subdivide works with either approach.

---

## ST_Subdivide: The Actually Useful Technique

### What is ST_Subdivide?

Breaks large geometries into smaller pieces with fewer vertices:

```sql
-- Large block: 500 vertices, 200m long
SELECT ST_Subdivide(geom, 50);
-- Result: 10 smaller geometries, each ~50 vertices
```

**Why this helps:**
- `ST_Intersection(large_geom, buffer)` is O(vertices²)
- `ST_Intersection(small_geom, buffer)` is much faster
- Process 10 small intersections faster than 1 large intersection

### Where to Apply It

**Option 1: Subdivide blocks (schema change)**
```sql
-- One-time: create subdivided blocks table
CREATE TABLE runmap.streets_blocks_32610_subdiv AS
SELECT
  block_id,
  name,
  highway,
  block_length_m,
  ST_Subdivide(geom_32610, 50) AS geom_32610,
  generate_series(1, ST_NumGeometries(ST_Subdivide(geom_32610, 50))) AS subdivision_id
FROM runmap.streets_blocks_32610;

CREATE INDEX idx_blocks_subdiv_geom ON runmap.streets_blocks_32610_subdiv USING GIST(geom_32610);

-- Update coverage function to use subdivided blocks
-- Sum the lengths from all subdivisions
```

**Option 2: Subdivide on-the-fly (no schema change)**
```sql
-- In apply_run_to_block_coverage()
SELECT
  b.block_id,
  SUM(ST_Length(
    ST_Intersection(subdivided.geom, ST_Union(rb.geom))
  )) as total_length
FROM runmap.streets_blocks_32610 b
CROSS JOIN LATERAL ST_Subdivide(b.geom_32610, 50) AS subdivided(geom)
JOIN runmap.runs_buffered_32610 rb ON ST_Intersects(subdivided.geom, rb.geom)
WHERE b.block_id IN (...)
GROUP BY b.block_id;
```

**Option 3: Subdivide run buffers**
```sql
-- Subdivide buffers instead of blocks
CREATE TABLE runmap.runs_buffered_32610_subdiv AS
SELECT
  run_id,
  ST_Subdivide(geom, 256) AS geom
FROM runmap.runs_buffered_32610;

-- Use in coverage calculation
```

### Recommendation: Start with Option 2

**Why:**
- No schema migration needed
- Easy to test and measure improvement
- Can switch to Option 1 if results are good

**Implementation:**

```sql
CREATE OR REPLACE FUNCTION runmap.apply_run_to_block_coverage(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  -- Session tuning
  PERFORM set_config('work_mem', '512MB', true);
  PERFORM set_config('jit', 'off', true);

  -- Store per-run coverage in junction table
  INSERT INTO runmap.block_run_coverage (block_id, run_id, coverage_length_m)
  SELECT
    b.block_id,
    run_uuid,
    ST_Length(ST_Intersection(b.geom_32610, rb.geom)) as coverage_length
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = run_uuid
  WHERE ST_Intersects(b.geom_32610, rb.geom)
  ON CONFLICT (block_id, run_id) DO NOTHING;

  -- Recalculate total coverage using ST_Subdivide for faster intersections
  INSERT INTO runmap.block_coverage_32610 (block_id, covered_length_m, total_length_m, covered_geom)
  SELECT
    b.block_id,
    SUM(ST_Length(
      ST_Intersection(
        subdiv.geom,
        ST_Union(rb.geom)
      )
    )) as total_covered_length,
    b.block_length_m,
    NULL
  FROM runmap.streets_blocks_32610 b
  CROSS JOIN LATERAL ST_Subdivide(b.geom_32610, 50) AS subdiv(geom)  -- ← NEW
  JOIN runmap.block_run_coverage brc ON brc.block_id = b.block_id
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = brc.run_id
  WHERE b.block_id IN (
    SELECT DISTINCT block_id FROM runmap.block_run_coverage WHERE run_id = run_uuid
  )
    AND ST_Intersects(subdiv.geom, rb.geom)  -- ← Filter subdivisions
  GROUP BY b.block_id, b.geom_32610, b.block_length_m
  ON CONFLICT (block_id) DO UPDATE SET covered_length_m = EXCLUDED.covered_length_m;
END;
$function$;
```

---

## Performance Tracking Infrastructure

### Create Performance Log Table

```sql
-- Track optimization results over time
CREATE TABLE IF NOT EXISTS runmap.performance_log (
  id SERIAL PRIMARY KEY,
  logged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  operation TEXT NOT NULL,
  run_count INTEGER,
  avg_seconds NUMERIC(10,3),
  total_seconds NUMERIC(10,3),
  optimization TEXT,
  notes TEXT
);

CREATE INDEX idx_performance_log_operation ON runmap.performance_log(operation, logged_at);

-- Example usage
INSERT INTO runmap.performance_log (operation, run_count, avg_seconds, total_seconds, optimization, notes)
VALUES (
  'bulk_import',
  628,
  7.6,
  4772.8,
  'baseline',
  'Junction table approach, no ST_Subdivide, quad_segs=8'
);
```

### Add Logging to Scripts

Update `bulk_import.sh` and `process_all_runs.sh` to log results:

```bash
# At end of processing
OPTIMIZATION="baseline"  # or "st_subdivide" or "cheap_buffers" etc.

psql << EOF
INSERT INTO runmap.performance_log (operation, run_count, avg_seconds, total_seconds, optimization, notes)
VALUES (
  'bulk_import',
  $SUCCESS,
  $AVG_TIME,
  $TOTAL_ELAPSED,
  '$OPTIMIZATION',
  'Processing details: buffer avg ${AVG_BUFFER}s, coverage avg ${AVG_COVERAGE}s'
);
EOF
```

### Query Performance Trends

```sql
-- Compare optimizations
SELECT
  optimization,
  COUNT(*) as runs,
  AVG(avg_seconds) as avg_time_per_run,
  MIN(avg_seconds) as best,
  MAX(avg_seconds) as worst
FROM runmap.performance_log
WHERE operation = 'bulk_import'
GROUP BY optimization
ORDER BY avg_time_per_run;

-- Performance over time
SELECT
  logged_at::date as date,
  optimization,
  run_count,
  avg_seconds,
  total_seconds / 60.0 as total_minutes
FROM runmap.performance_log
WHERE operation = 'bulk_import'
ORDER BY logged_at DESC;
```

---

## Benchmark Protocol

Adapted from `docs/5/RunMap_Benchmark_Protocol.md` for our architecture.

### Phase 1: Establish Baseline

**Prerequisites:**
- Wait for current 628-run bulk import to complete
- Record final timing statistics

**Steps:**

1. **Record baseline metrics:**
```sql
-- After bulk import completes
INSERT INTO runmap.performance_log (operation, run_count, total_seconds, optimization, notes)
VALUES ('bulk_import', 628, <TOTAL_SECONDS>, 'baseline', 'Current junction table approach');
```

2. **Analyze current state:**
```sql
-- Block complexity distribution
SELECT
  CASE
    WHEN block_length_m < 50 THEN '0-50m'
    WHEN block_length_m < 100 THEN '50-100m'
    WHEN block_length_m < 200 THEN '100-200m'
    ELSE '200m+'
  END as length_range,
  COUNT(*) as num_blocks,
  AVG(ST_NPoints(geom_32610))::int as avg_vertices
FROM runmap.streets_blocks_32610
GROUP BY length_range
ORDER BY length_range;

-- Run complexity distribution
SELECT
  COUNT(*) as num_runs,
  AVG(ST_NPoints(geom))::int as avg_points,
  MAX(ST_NPoints(geom)) as max_points
FROM runmap.runs_buffered_32610;

-- Blocks by run count
SELECT
  CASE
    WHEN run_count = 1 THEN '1 run'
    WHEN run_count <= 5 THEN '2-5 runs'
    WHEN run_count <= 10 THEN '6-10 runs'
    WHEN run_count <= 20 THEN '11-20 runs'
    ELSE '20+ runs'
  END as run_count_range,
  COUNT(*) as num_blocks
FROM (
  SELECT block_id, COUNT(*) as run_count
  FROM runmap.block_run_coverage
  GROUP BY block_id
) t
GROUP BY run_count_range
ORDER BY run_count_range;
```

### Phase 2: Test ST_Subdivide (Small Dataset)

**Steps:**

1. **Reset coverage:**
```bash
./scripts/reset_coverage.sh
```

2. **Update function with ST_Subdivide:**
```sql
-- Apply ST_Subdivide version from above
```

3. **Process 30 runs:**
```bash
# Manually select first 30 Sacramento runs
psql << 'EOF'
SELECT id FROM runmap.runs_raw
WHERE location = 'sacramento'
ORDER BY start_time
LIMIT 30;
EOF

# Process them (modify process_all_runs.sh to accept run IDs)
```

4. **Record results:**
```sql
INSERT INTO runmap.performance_log (operation, run_count, avg_seconds, optimization, notes)
VALUES ('test_30_runs', 30, <AVG_SECONDS>, 'st_subdivide_50', 'quad_segs=50, on-the-fly subdivision');
```

5. **Validate coverage accuracy:**
```sql
-- Coverage percentages should match baseline (within 0.5%)
-- Compare block coverage from baseline vs. ST_Subdivide test
```

### Phase 3: Test Cheaper Buffers (Small Dataset)

**Steps:**

1. **Reset coverage again**
2. **Update buffer_one_run() with cheaper parameters:**
```sql
ST_Buffer(geom, 10, 'endcap=flat join=mitre quad_segs=4')
```

3. **Process same 30 runs**
4. **Record results:**
```sql
INSERT INTO runmap.performance_log (operation, run_count, avg_seconds, optimization, notes)
VALUES ('test_30_runs', 30, <AVG_SECONDS>, 'cheap_buffers', 'quad_segs=4, endcap=flat, join=mitre');
```

5. **Validate accuracy** (coverage should be within 0.5% of baseline)

### Phase 4: Combined Optimization (Small Dataset)

**Steps:**

1. **Reset coverage**
2. **Apply BOTH optimizations:**
   - ST_Subdivide in coverage function
   - Cheaper buffers in buffer function
   - Session settings (work_mem, jit)

3. **Process 30 runs**
4. **Record results:**
```sql
INSERT INTO runmap.performance_log (operation, run_count, avg_seconds, optimization, notes)
VALUES ('test_30_runs', 30, <AVG_SECONDS>, 'combined', 'ST_Subdivide + cheap buffers + session tuning');
```

### Phase 5: Full Dataset Test

**If Phase 2-4 show improvement AND maintain accuracy:**

1. **Reset coverage**
2. **Apply best optimization from Phase 2-4**
3. **Process all 628 runs:**
```bash
./scripts/process_all_runs.sh
```

4. **Record final results:**
```sql
INSERT INTO runmap.performance_log (operation, run_count, avg_seconds, total_seconds, optimization)
VALUES ('bulk_import', 628, <AVG>, <TOTAL>, '<best_optimization>');
```

5. **Compare to baseline:**
```sql
SELECT
  optimization,
  total_seconds / 60.0 as total_minutes,
  avg_seconds as avg_per_run
FROM runmap.performance_log
WHERE operation = 'bulk_import'
ORDER BY optimization;
```

---

## Expected Results

### Conservative Estimates

**Baseline (current):**
- 628 runs in ~80 minutes (~7.6s per run)
- Breakdown: 5s buffering, 2.6s coverage (average)

**With ST_Subdivide:**
- Coverage: 2.6s → 1.8s (30% faster)
- Total: 7.6s → 6.8s per run
- **Total time: ~71 minutes (save 9 minutes)**

**With cheaper buffers:**
- Buffering: 5s → 3.5s (30% faster)
- Total: 7.6s → 6.1s per run
- **Total time: ~64 minutes (save 16 minutes)**

**With both:**
- Buffering: 5s → 3.5s
- Coverage: 2.6s → 1.8s
- Total: 7.6s → 5.3s per run
- **Total time: ~55 minutes (save 25 minutes)**

### Optimistic Estimates

If subdivide and cheaper buffers both achieve 40% improvement:
- Total: 7.6s → 4.2s per run
- **Total time: ~44 minutes (save 36 minutes)**

---

## Migration Considerations

### Is Schema Migration Worth It?

**Question:** Should we adopt the schema from docs/5/ documents?

**Their schema:**
```sql
runs (id, geom_wgs, geom_utm, ...)
run_buffers (run_id, geom_buf, ...)
blocks (block_id, geom, total_m, ...)
block_coverage_runs (run_id, block_id, len_hit_m, ...)  -- Per-run
block_coverage (block_id, len_hit_m, ...)               -- Aggregate (BUGGED)
```

**Our schema:**
```sql
runs_raw (id, geom, ...)
runs_buffered_32610 (run_id, geom, ...)
streets_blocks_32610 (block_id, geom_32610, block_length_m, ...)
block_run_coverage (run_id, block_id, coverage_length_m, ...)  -- Per-run
block_coverage_32610 (block_id, covered_length_m, covered_geom, ...)  -- Aggregate (CORRECT)
```

**Differences:**
1. Table names (cosmetic)
2. Their aggregate table is bugged (additive instead of union-based)
3. Functionally equivalent after fixing their bug

**Migration cost at this stage:**
- Low: 628 runs can be re-imported in ~15 minutes
- Schema changes: ~30 minutes
- Update all scripts/docs: ~2 hours
- **Total: ~3 hours**

**Migration benefit:**
- Cleaner table names? (subjective)
- **No performance benefit** (ST_Subdivide works with either schema)
- **No functional benefit** (both use junction table + union pattern after fixing their bug)

**Verdict: Don't migrate**
- Not worth 3 hours for cosmetic changes
- ST_Subdivide is the valuable technique, not their schema
- Our architecture is already documented and working

### If We Ever Do Migrate

**Reasons to reconsider:**
1. External collaborators strongly prefer their naming
2. We discover their schema has hidden benefits
3. Starting fresh for production deployment

**Migration path:**
1. Create new tables with their schema
2. Copy data: `INSERT INTO runs SELECT * FROM runs_raw`
3. Run bulk import to populate new tables
4. Update all functions to use new table names
5. Update all scripts
6. Update all documentation
7. Drop old tables

**Time: 4-6 hours** (doable but not justified currently)

---

## Implementation Checklist

### Phase 1: Infrastructure (30 minutes)

- [ ] Create performance_log table
- [ ] Add logging to bulk_import.sh
- [ ] Add logging to process_all_runs.sh
- [ ] Verify spatial indexes exist
- [ ] Run ANALYZE on all tables

### Phase 2: Baseline (Wait for current import)

- [ ] Record baseline timing from current 628-run import
- [ ] Analyze block complexity distribution
- [ ] Analyze run complexity distribution
- [ ] Analyze blocks by run count

### Phase 3: ST_Subdivide Test (2 hours)

- [ ] Update apply_run_to_block_coverage() with ST_Subdivide
- [ ] Reset coverage
- [ ] Process 30 test runs
- [ ] Record timing
- [ ] Validate coverage accuracy (within 0.5%)
- [ ] Compare to baseline

### Phase 4: Cheaper Buffers Test (2 hours)

- [ ] Update buffer_one_run() with quad_segs=4
- [ ] Reset coverage
- [ ] Process 30 test runs
- [ ] Record timing
- [ ] Validate coverage accuracy (within 0.5%)
- [ ] Compare to baseline

### Phase 5: Combined Test (2 hours)

- [ ] Apply both optimizations + session settings
- [ ] Reset coverage
- [ ] Process 30 test runs
- [ ] Record timing
- [ ] Validate accuracy
- [ ] Identify best optimization

### Phase 6: Full Test (1.5 hours)

- [ ] Reset coverage
- [ ] Apply best optimization
- [ ] Process all 628 runs
- [ ] Record final timing
- [ ] Compare to baseline
- [ ] Update documentation with results

**Total Time: ~8 hours** (spread over multiple sessions)

---

## Success Criteria

### Minimum Success
- 10% improvement in total time (80 min → 72 min)
- Coverage accuracy within 1% of baseline
- No increase in complexity

### Target Success
- 20-30% improvement (80 min → 56-64 min)
- Coverage accuracy within 0.5%
- Cleaner, more maintainable code

### Stretch Success
- 40%+ improvement (80 min → <48 min)
- Perfect coverage accuracy
- Documented, reproducible optimization process

---

## Related Documentation

### Required Context
- **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** - Why junction table + recompute works
- **[APPLICABLE_POSTGIS_OPTIMIZATIONS.md](APPLICABLE_POSTGIS_OPTIMIZATIONS.md)** - All potential optimizations
- **[TESTING_WORKFLOW.md](TESTING_WORKFLOW.md)** - How to reset and reprocess efficiently

### External Sources (For Reference)
- **[docs/5/RunMap_Benchmark_Protocol.md](5/RunMap_Benchmark_Protocol.md)** - Original benchmark protocol
- **[docs/5/runmap_migration.sql](5/runmap_migration.sql)** - Schema with ST_Subdivide (but additive bug)
- **[docs/5/RunMap_Implementation_Checklist.md](5/RunMap_Implementation_Checklist.md)** - Implementation steps
- **[docs/5/RunMap_Single_DB_Safety_Pattern.md](5/RunMap_Single_DB_Safety_Pattern.md)** - Safety patterns for migrations

---

## Questions for Review

1. **Is on-the-fly ST_Subdivide the right approach?**
   - Or should we create subdivided blocks table (Option 1)?
   - Trade-off: query-time overhead vs. storage/migration

2. **What subdivision size?**
   - Suggested: 50 vertices per subdivision
   - Too small: overhead of many tiny pieces
   - Too large: no performance benefit

3. **Should we subdivide blocks or buffers?**
   - Blocks are static (subdivide once)
   - Buffers are per-run (subdivide every time)
   - Blocks seem like better target

4. **Is the benchmark protocol sufficient?**
   - Missing any critical measurements?
   - Better ways to validate accuracy?

---

## Next Steps

1. **Wait for current bulk import to complete** - need baseline data
2. **Implement performance logging infrastructure** - track all future tests
3. **Test ST_Subdivide on 30 runs** - measure improvement, validate accuracy
4. **Test cheaper buffers on 30 runs** - measure improvement, validate accuracy
5. **If both work, test combined** - measure cumulative benefit
6. **Apply best optimization to full dataset** - measure final improvement
7. **Update all documentation** - record results, update recommendations

**Do NOT migrate schema** - ST_Subdivide works with our current architecture.
