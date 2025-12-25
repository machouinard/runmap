# Applicable PostGIS Optimizations for RunMap

**Date:** 2025-10-20
**Purpose:** Extract useful techniques from external PostGIS optimization guides and adapt them to our junction table architecture

---

## Executive Summary

This document reviews optimization techniques from:
- [POSTGIS_PERFORMANCE_NOTES.md](POSTGIS_PERFORMANCE_NOTES.md)
- [RunMap_Coverage_Performance_Playbook.md](RunMap_Coverage_Performance_Playbook.md)

**Key Finding:** Both documents contain valid PostGIS optimization techniques, but some recommendations conflict with our architecture or cause double-counting issues.

**Our Architecture (Junction Table + Recompute):**
- Store per-run coverage in `block_run_coverage` junction table
- Recompute total coverage by unioning ALL run buffers for each block
- Don't store accumulated geometry (prevents complexity growth)
- See [PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md) for full context

**This Document:**
- ✅ Techniques we should implement
- ⚠️ Techniques that need adaptation
- ❌ Techniques we must avoid (and why)

---

## ✅ Optimizations to Implement

### 1. ST_Subdivide for Faster Intersections

**Source:** RunMap_Coverage_Performance_Playbook.md (lines 150-160)

**Problem:** Large block geometries make `ST_Intersection` slow

**Solution:** Subdivide large blocks into smaller pieces before intersection

**Implementation:**

```sql
-- Option A: Subdivide blocks during initial setup (one-time cost)
CREATE TABLE runmap.streets_blocks_32610_subdivided AS
SELECT
  block_id,
  name,
  highway,
  block_length_m,
  ST_Subdivide(geom_32610, 50) AS geom_32610  -- Max 50 vertices per piece
FROM runmap.streets_blocks_32610;

CREATE INDEX idx_blocks_subdivided_geom ON runmap.streets_blocks_32610_subdivided USING GIST(geom_32610);

-- Then update our coverage function to use subdivided blocks
-- (measure each piece, sum the lengths)
```

**Option B: Subdivide on-the-fly (no schema change):**

```sql
-- In apply_run_to_block_coverage(), change intersection logic:
SELECT
  b.block_id,
  SUM(ST_Length(ST_Intersection(subdivided.geom, rb.geom))) as total_length
FROM runmap.streets_blocks_32610 b
CROSS JOIN LATERAL ST_Subdivide(b.geom_32610, 50) AS subdivided(geom)
JOIN runmap.runs_buffered_32610 rb ON ST_Intersects(subdivided.geom, rb.geom)
WHERE ...
GROUP BY b.block_id;
```

**Expected Benefit:**
- 10-30% faster intersection operations
- Most beneficial for long blocks (>200m)

**Trade-off:**
- Option A: One-time migration, faster queries
- Option B: No migration, slightly slower than Option A but faster than current

**Recommendation:** Test Option B first (no schema change). If significant improvement, consider Option A.

---

### 2. Session Settings for Coverage Functions

**Source:** Both documents

**Problem:** Default PostgreSQL settings not optimized for PostGIS geometry operations

**Solution:** Set session parameters at function start

**Implementation:**

```sql
CREATE OR REPLACE FUNCTION runmap.buffer_one_run(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  -- Increase work memory for geometry operations
  PERFORM set_config('work_mem', '256MB', true);  -- LOCAL to this transaction
  PERFORM set_config('jit', 'off', true);          -- JIT overhead not worth it for PostGIS
  PERFORM set_config('effective_cache_size', '4GB', true);

  -- ... existing buffer logic ...
END;
$function$;

CREATE OR REPLACE FUNCTION runmap.apply_run_to_block_coverage(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  -- Same settings for coverage calculation
  PERFORM set_config('work_mem', '512MB', true);  -- Larger for union operations
  PERFORM set_config('jit', 'off', true);
  PERFORM set_config('effective_cache_size', '4GB', true);

  -- ... existing coverage logic ...
END;
$function$;
```

**Expected Benefit:**
- 5-15% faster coverage calculations
- More memory for sorting/hashing in union operations
- No downside (only affects this transaction)

**Server Context:**
- Server has 20GB RAM
- Processing one run at a time sequentially
- 512MB work_mem is safe

**Recommendation:** ✅ Implement immediately (low risk, easy win)

---

### 3. Cheaper Buffer Parameters

**Source:** Both documents

**Problem:** Default `ST_Buffer()` creates high-quality circles (8 segments per quadrant = 32 segments total)

**Solution:** Reduce circle quality for faster buffering

**Implementation:**

```sql
CREATE OR REPLACE FUNCTION runmap.buffer_one_run(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_buffer_distance FLOAT;
BEGIN
  PERFORM set_config('work_mem', '256MB', true);
  PERFORM set_config('jit', 'off', true);

  v_buffer_distance := runmap.get_buffer_distance();

  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  SELECT
    id,
    ST_Buffer(
      ST_Transform(geom, 32610),
      v_buffer_distance,
      'endcap=flat join=mitre quad_segs=4'  -- 4 segs/quad instead of 8
    )
  FROM runmap.runs_raw
  WHERE id = run_uuid
  ON CONFLICT (run_id) DO NOTHING;
END;
$function$;
```

**Parameters Explained:**
- `quad_segs=4`: 4 segments per circle quadrant (16 total instead of 32)
- `endcap=flat`: Flat line ends instead of rounded
- `join=mitre`: Sharp corners instead of rounded

**Expected Benefit:**
- 20-30% faster buffering
- For 628 runs averaging 8s buffering, saves ~1000-1500 seconds (~17-25 minutes)

**Trade-off:**
- Lower quality buffer (more jagged)
- For 10m buffer with ±5-10m GPS accuracy, this is acceptable
- Must verify coverage percentages don't change significantly

**Testing Plan:**
```sql
-- Test on 30 runs with both settings, compare coverage
-- Old: ST_Buffer(geom, 10)
-- New: ST_Buffer(geom, 10, 'endcap=flat join=mitre quad_segs=4')
-- If coverage percentages differ by <1%, proceed
```

**Recommendation:** ✅ Test on small dataset first, then implement if accurate

---

### 4. Verify and Add Spatial Indexes

**Source:** Both documents

**Problem:** Missing spatial indexes cause table scans

**Solution:** Verify GIST indexes exist on all geometry columns

**Check Current Indexes:**

```sql
SELECT
  tablename,
  indexname,
  indexdef
FROM pg_indexes
WHERE schemaname = 'runmap'
  AND tablename IN (
    'streets_blocks_32610',
    'runs_buffered_32610',
    'block_coverage_32610',
    'runs_raw'
  )
ORDER BY tablename, indexname;
```

**Required Indexes:**

```sql
-- Blocks (for ST_Intersects in coverage calculation)
CREATE INDEX IF NOT EXISTS idx_blocks_geom
  ON runmap.streets_blocks_32610 USING GIST(geom_32610);

-- Run buffers (for ST_Intersects in coverage calculation)
CREATE INDEX IF NOT EXISTS idx_run_buffers_geom
  ON runmap.runs_buffered_32610 USING GIST(geom);

-- Raw runs (for spatial queries, location detection)
CREATE INDEX IF NOT EXISTS idx_runs_raw_geom
  ON runmap.runs_raw USING GIST(geom);

-- Block coverage (already has index, but geometry is NULL - can drop?)
-- Note: covered_geom is always NULL in our architecture
-- This index may be unnecessary
```

**Check Index Usage:**

```sql
-- Run EXPLAIN ANALYZE on coverage function to verify index usage
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM runmap.apply_run_to_block_coverage('some-uuid');
```

Look for:
- "Index Scan using idx_blocks_geom" ✅ (good)
- "Seq Scan on streets_blocks_32610" ❌ (bad - missing index)

**Recommendation:** ✅ Verify immediately, add if missing (critical for performance)

---

### 5. ANALYZE After Bulk Operations

**Source:** RunMap_Coverage_Performance_Playbook.md (line 102)

**Problem:** PostgreSQL query planner has stale statistics after bulk inserts

**Solution:** Run ANALYZE after bulk import

**Implementation:**

Add to `bulk_import.sh` and `process_all_runs.sh`:

```bash
# After processing all runs
echo "Updating database statistics..."
psql -c "ANALYZE runmap.runs_raw;"
psql -c "ANALYZE runmap.runs_buffered_32610;"
psql -c "ANALYZE runmap.block_coverage_32610;"
psql -c "ANALYZE runmap.block_run_coverage;"
```

**Expected Benefit:**
- Better query plans for subsequent operations
- Especially important after inserting 628 runs

**Recommendation:** ✅ Add to scripts (negligible cost, ensures optimal query plans)

---

### 6. Batch Geometry Operations

**Source:** POSTGIS_PERFORMANCE_NOTES.md

**Problem:** Processing geometries one-by-one in loops is slow

**Current Implementation:** We already do this! ✅

Our coverage function processes all blocks for a run in a single SQL statement:

```sql
-- Good: Single INSERT with GROUP BY (batch operation)
INSERT INTO runmap.block_coverage_32610 (...)
SELECT b.block_id, ST_Length(ST_Intersection(...))
FROM ... JOIN all runs for affected blocks ...
GROUP BY b.block_id;

-- Bad: Loop in application code
-- for each block:
--   INSERT INTO ... (one row at a time)
```

**Recommendation:** ✅ Already doing this, no change needed

---

## ⚠️ Techniques Requiring Careful Adaptation

### 7. Pre-Simplify GPS Tracks Before Buffering

**Source:** Both documents

**Suggestion:** Simplify GPS tracks to reduce point count before buffering

**Example:**
```sql
ST_Simplify(ST_Transform(geom, 32610), 2.0)  -- Remove points within 2m tolerance
```

**Concerns:**
- GPS tracks are already imprecise (±5-10m accuracy)
- Further simplification might miss small streets or create gaps
- We tried geometry simplification before and it caused artifacts

**Testing Required:**
- Simplify tracks in `ingest_gpx.sh` before storing
- Process 30 runs with/without simplification
- Compare coverage percentages
- If <0.5% difference and faster, proceed

**Recommendation:** ⚠️ Test carefully, may not be worth the risk

---

### 8. Parallel Processing

**Source:** Both documents

**Suggestion:** Process multiple runs concurrently

**Implementation Idea:**
```bash
# In process_all_runs.sh, use GNU parallel
echo "$NEW_RUN_IDS" | parallel -j 4 '
  psql -c "SELECT runmap.buffer_one_run('{}');" &&
  psql -c "SELECT runmap.apply_run_to_block_coverage('{}');"
'
```

**Concerns:**
- Concurrent writes to `block_coverage_32610` could cause conflicts
- Would need UPSERT locking or serializable isolation
- Current sequential approach is simpler and working

**Potential Benefit:**
- 2-3x speedup on Mac with multiple cores
- 80 minutes → 25-40 minutes for bulk import

**Complexity:**
- Need to handle concurrent updates to same blocks
- More difficult debugging if errors occur

**Recommendation:** ⚠️ Only pursue if current solution proves too slow (>2 hours for bulk import)

---

## ❌ Techniques We Must Avoid

### 9. Additive Coverage Calculation (Double-Counting)

**Source:** RunMap_Coverage_Performance_Playbook.md (lines 50-60)

**Their Approach:**
```sql
-- WRONG: Just add new coverage to existing coverage
SET len_hit_m = block_coverage.len_hit_m + EXCLUDED.len_hit_m;
```

**Why This Fails:**

Example: Block is 100m long

- Run 1 covers 0-60m: `len_hit_m = 60`
- Run 2 covers 40-100m: `len_hit_m = 60 + 60 = 120` ❌ **Over 100%!**

The overlap (40-60m) is counted twice.

**Our Approach (Correct):**
```sql
-- Union all run buffers, then measure (overlaps merged)
ST_Length(ST_Intersection(block.geom, ST_Union(all_run_buffers)))
-- Run 1 covers 0-60m
-- Run 2 covers 40-100m
-- Union merges overlap: total coverage = 100m ✅
```

**Recommendation:** ❌ **Never use additive approach** - causes fundamental accuracy errors

---

### 10. Store Accumulated Coverage Geometry

**Source:** Old approach (before our Oct 2025 fix)

**Their Approach:**
```sql
-- Store the union of all coverage so far
covered_geom = ST_Union(old_covered_geom, new_coverage_geom)
```

**Why This Fails:**
- Geometry vertex count grows: 1.5K → 77K → 1.4M points
- Each union operation gets exponentially slower
- This was the exact problem we just solved!

**Our Approach (Correct):**
```sql
-- Don't store accumulated geometry
covered_geom = NULL

-- Recompute from source when needed
ST_Union(run1_buffer, run2_buffer, ..., runN_buffer)
```

**See:** [PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md) for full analysis

**Recommendation:** ❌ **Never store accumulated geometry** - this was the root cause of our performance issue

---

### 11. Reduce Coordinate Precision (ST_SnapToGrid)

**Source:** POSTGIS_PERFORMANCE_NOTES.md Section 8

**Their Approach:**
```sql
ST_SnapToGrid(geom, 0.1)  -- Snap to 0.1m grid
```

**Why This Fails:**
- GPS tracks already have ±5-10m accuracy
- Snapping creates artificial vertices and coverage artifacts
- We explicitly rejected this approach in testing

**Recommendation:** ❌ **Do not use** - causes coverage inaccuracies

---

### 12. UNLOGGED Tables for Production Data

**Source:** RunMap_Coverage_Performance_Playbook.md (line 111)

**Their Approach:**
```sql
CREATE UNLOGGED TABLE runs (...);  -- Faster writes, no WAL
```

**Why This Fails:**
- UNLOGGED tables lose data on PostgreSQL crash
- Acceptable for staging/temp data only
- Our runs are permanent historical records

**Our Use Case:**
- Runs are imported once and never deleted (immutable history)
- Data loss on crash is unacceptable
- We're not importing fast enough to need UNLOGGED tables

**Recommendation:** ❌ **Do not use** for production tables (`runs_raw`, `block_coverage_32610`, etc.)

---

## Implementation Priority

### High Priority (Implement Now)
1. ✅ **Verify spatial indexes** - Critical, 5 minutes
2. ✅ **Session settings** - Easy win, 10 minutes
3. ✅ **ANALYZE after bulk** - Add to scripts, 5 minutes

### Medium Priority (Test Then Implement)
4. ⚠️ **Cheaper buffers** - Test on 30 runs, validate accuracy
5. ⚠️ **ST_Subdivide** - Test Option B (on-the-fly), measure improvement

### Low Priority (Only If Needed)
6. ⚠️ **Pre-simplify tracks** - Risky, test carefully
7. ⚠️ **Parallel processing** - Complex, only if bulk import >2 hours

### Never Implement
8. ❌ **Additive coverage** - Fundamentally wrong
9. ❌ **Store accumulated geometry** - Solved problem
10. ❌ **Reduce precision** - Causes artifacts
11. ❌ **UNLOGGED production tables** - Data loss risk

---

## Testing Methodology

### Before Implementing Any Optimization

1. **Establish baseline:**
   - Wait for current 628-run bulk import to complete
   - Record total time, average time per run
   - Record coverage percentages for sample blocks

2. **Test on small dataset:**
   - Reset coverage: `SELECT runmap.reset_coverage_processing();`
   - Process 30 runs with optimization enabled
   - Compare timing and coverage percentages

3. **Validate accuracy:**
   - Coverage percentages should differ by <0.5%
   - No blocks should exceed 100% coverage
   - Visual inspection of map (no obvious artifacts)

4. **Full test if validation passes:**
   - Reset coverage again
   - Process all 628 runs with optimization
   - Compare total time to baseline

5. **Document results:**
   - Update this document with actual performance gains
   - Note any issues or trade-offs discovered

---

## Current Performance Baseline

**As of 2025-10-20 (run 158 of 628):**
- Average: 7.6 seconds per run
- Breakdown: 1-14s buffering (varies), 0-4s coverage (constant)
- Total coverage geometry points: **0** (junction table working)
- No slowdown observed (coverage time staying constant)
- Projected total time: ~80 minutes for 628 runs

**Wait for completion to establish final baseline before optimizing further.**

---

## Related Documentation

### Required Reading (Understand Our Architecture)
- **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** - Why we use junction table + recompute
- **[BLOCK_PERCENTAGE_MIGRATION.md](BLOCK_PERCENTAGE_MIGRATION.md)** - Block-based coverage architecture
- **[CLAUDE.md](../CLAUDE.md)** - Database schema and function reference

### Additional Context
- **[POSTGIS_PERFORMANCE_REVIEW.md](POSTGIS_PERFORMANCE_REVIEW.md)** - Review of POSTGIS_PERFORMANCE_NOTES.md
- **[TESTING_WORKFLOW.md](TESTING_WORKFLOW.md)** - How to test algorithm changes efficiently
- **[SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md)** - Memory usage and scalability

### External Sources (For Reference)
- **[POSTGIS_PERFORMANCE_NOTES.md](POSTGIS_PERFORMANCE_NOTES.md)** - Generic PostGIS optimization techniques
- **[RunMap_Coverage_Performance_Playbook.md](RunMap_Coverage_Performance_Playbook.md)** - AI-generated optimization guide (different architecture)

---

## Questions for External Reviewers

If you're reviewing this as a PostGIS expert or colleague:

1. **Is our junction table + recompute approach sound?**
   - Any hidden performance issues with unioning N small buffers repeatedly?
   - Alternative approaches that avoid double-counting without geometry accumulation?

2. **ST_Subdivide applicability:**
   - Should we subdivide blocks once (schema change) or on-the-fly (LATERAL join)?
   - Expected performance impact for blocks averaging 100m length, 25 blocks per run?

3. **Cheaper buffer settings:**
   - Is `quad_segs=4` too aggressive for 10m buffers with ±5-10m GPS accuracy?
   - Will `endcap=flat join=mitre` cause coverage artifacts at line ends?

4. **Missing optimizations:**
   - Any PostgreSQL/PostGIS settings we're not using?
   - Any geometric algorithms better suited to our use case?

Please provide:
- Specific code examples
- Quantified performance expectations
- Risks and trade-offs
- Testing methodology

---

## Changelog

**2025-10-20:**
- Initial document created
- Extracted applicable techniques from POSTGIS_PERFORMANCE_NOTES.md and RunMap_Coverage_Performance_Playbook.md
- Identified techniques to avoid (additive coverage, geometry accumulation, precision reduction)
- Established implementation priority and testing methodology
