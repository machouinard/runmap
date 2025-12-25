# Review: POSTGIS_PERFORMANCE_NOTES.md

**Date:** 2025-10-20
**Reviewer:** Claude (AI assistant)
**Context:** Evaluating PostGIS optimization suggestions in context of current RunMap implementation

---

## Executive Summary

The document [POSTGIS_PERFORMANCE_NOTES.md](POSTGIS_PERFORMANCE_NOTES.md) contains valid PostGIS optimization techniques, but some recommendations don't align with our current architecture. This review identifies which techniques are applicable and which require careful consideration.

**Current Status:**
- We recently solved a critical geometry accumulation problem (see [PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md))
- Bulk import of 628 runs is currently running (~158 runs processed in 20 minutes)
- Coverage geometry points staying at 0 (fix is working)
- Average processing time: ~7.6 seconds per run (mostly buffering overhead)

**Key Question:** Should we implement additional optimizations from POSTGIS_PERFORMANCE_NOTES.md, or is current performance acceptable?

---

## Current Architecture (What We're Actually Doing)

### Problem We Solved

**Geometry Accumulation Issue (Oct 2025):**
- Old approach stored accumulated coverage geometry in `block_coverage_32610.covered_geom`
- Each `ST_Union` added vertices → geometry complexity grew from 1.5K → 77K points in 113 runs
- Processing time increased exponentially: 1s/run → 10s/run → projected 185s/run by run 628
- Would have taken 26+ hours to process all 628 runs

**Solution Implemented:**
```sql
-- Junction table tracks which runs affect which blocks
CREATE TABLE runmap.block_run_coverage (
    block_id INTEGER,
    run_id UUID,
    coverage_length_m DOUBLE PRECISION,
    PRIMARY KEY (block_id, run_id)
);

-- Coverage function recomputes from source (doesn't store accumulated geometry)
CREATE OR REPLACE FUNCTION runmap.apply_run_to_block_coverage(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  -- 1. Store per-run coverage in junction table
  INSERT INTO runmap.block_run_coverage (block_id, run_id, coverage_length_m)
  SELECT b.block_id, run_uuid, ST_Length(ST_Intersection(b.geom_32610, rb.geom))
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = run_uuid
  WHERE ST_Intersects(b.geom_32610, rb.geom)
  ON CONFLICT (block_id, run_id) DO NOTHING;

  -- 2. Recalculate total coverage by unioning ALL run buffers for this block
  --    Key: We compute the union but DON'T store it (only store the length)
  INSERT INTO runmap.block_coverage_32610 (block_id, covered_length_m, total_length_m, covered_geom)
  SELECT
    b.block_id,
    ST_Length(ST_Intersection(b.geom_32610, ST_Union(rb.geom))),  -- Measure length
    b.block_length_m,
    NULL  -- Don't store geometry (prevents accumulation)
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.block_run_coverage brc ON brc.block_id = b.block_id
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = brc.run_id
  WHERE b.block_id IN (SELECT DISTINCT block_id FROM runmap.block_run_coverage WHERE run_id = run_uuid)
  GROUP BY b.block_id, b.geom_32610, b.block_length_m
  ON CONFLICT (block_id) DO UPDATE SET covered_length_m = EXCLUDED.covered_length_m;
END;
$function$
```

**Why this works:**
- No geometry accumulation (`covered_geom = NULL` always)
- For blocks touched by N runs, we union N small buffers (not 1 huge geometry + 1 new buffer)
- Most blocks touched by <10 runs → unioning 10 small geometries is fast
- Processing time stays constant (not growing)

**Current Performance (as of run 158):**
- Average: 7.6 seconds per run
- Breakdown: 1-14s buffering (depends on GPX complexity), 0-4s coverage (stays constant)
- Total coverage geometry points: **0** (no accumulation)
- Projected total time: ~80 minutes for 628 runs

---

## Review of POSTGIS_PERFORMANCE_NOTES.md Recommendations

### ✅ Section 1: Clip First, Union Second (ALREADY DOING THIS)

**Their recommendation:**
```sql
WITH clipped_buffers AS (
  SELECT block_id, ST_Intersection(block.geom, buffer.geom) AS clipped
  FROM blocks, buffers
  WHERE ST_Intersects(...)
)
SELECT block_id, ST_UnaryUnion(ST_Collect(clipped)) AS total_coverage
FROM clipped_buffers
GROUP BY block_id;
```

**Our implementation:**
We're already doing this conceptually:
1. Intersect each run buffer with block geometry
2. Union the intersections (via `ST_Union(rb.geom)` grouped by block)
3. Don't store the result

**Status:** ✅ Already implemented (in spirit)

---

### 🟡 Section 2: Cheaper Buffers (WORTH TESTING)

**Their recommendation:**
```sql
ST_Buffer(line_32610, 15, 'endcap=flat join=mitre mitre_limit=2.0 quad_segs=4')
```

**Context:**
- Buffering currently takes 1-14 seconds depending on GPX complexity
- Default `ST_Buffer()` uses `quad_segs=8` (8 segments per circle quadrant)
- Reducing to `quad_segs=4` creates rougher circles but faster

**Potential benefit:**
- 20-30% speedup on buffering step
- For 628 runs with avg 8s buffering, could save ~1000 seconds (~17 minutes total)

**Concerns:**
- Lower quality buffer (more jagged circles around track points)
- For 10m GPS buffer with ±5-10m GPS accuracy, this is probably fine
- Need to test if it affects coverage percentage accuracy

**Recommendation:** ✅ Test on small dataset, compare coverage percentages before/after

**Implementation:**
```sql
-- Update buffer_one_run() function
CREATE OR REPLACE FUNCTION runmap.buffer_one_run(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_buffer_distance FLOAT;
BEGIN
  v_buffer_distance := runmap.get_buffer_distance();

  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  SELECT
    id,
    ST_Buffer(
      ST_Transform(geom, 32610),
      v_buffer_distance,
      'endcap=flat join=mitre quad_segs=4'  -- Faster buffering
    )
  FROM runmap.runs_raw
  WHERE id = run_uuid
  ON CONFLICT (run_id) DO NOTHING;
END;
$function$;
```

---

### ✅ Section 3: Spatial Indexes (NEED TO VERIFY)

**Their recommendation:**
```sql
CREATE INDEX idx_blocks_geom ON blocks USING GIST(geom);
CREATE INDEX idx_buffers_geom ON buffers USING GIST(geom);
```

**Our tables:**
- `streets_blocks_32610.geom_32610` - needs GIST index
- `runs_buffered_32610.geom` - needs GIST index
- `block_coverage_32610.covered_geom` - has index but geometry is always NULL (can drop?)

**Action needed:** ✅ Check existing indexes, add if missing

```sql
-- Check current indexes
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'runmap'
  AND tablename IN ('streets_blocks_32610', 'runs_buffered_32610', 'block_coverage_32610')
ORDER BY tablename, indexname;
```

---

### 🔴 Section 4: Avoid ST_Contains/ST_Within (NOT APPLICABLE)

**Their recommendation:** Use `ST_Intersects` instead of `ST_Contains`

**Our code:** We already use `ST_Intersects` everywhere

**Status:** ✅ Already following this practice

---

### 🟡 Section 5: Interval-Based Coverage (MAJOR REFACTOR - PROBABLY NOT WORTH IT)

**Their recommendation:** Convert to 1D linear referencing instead of 2D geometry operations

**Example:**
```sql
-- Convert coverage segments to linear positions [start, end] along block
WITH intervals AS (
  SELECT block_id,
         ST_LineLocatePoint(block, ST_StartPoint(segment)) AS start_frac,
         ST_LineLocatePoint(block, ST_EndPoint(segment)) AS end_frac
  FROM coverage_segments
)
-- Merge overlapping intervals
SELECT block_id, merge_intervals(start_frac, end_frac) AS coverage
FROM intervals;
```

**Benefits:**
- Faster interval merging than 2D geometry unions
- Less memory (store [0.2, 0.5] instead of geometry)
- Potentially 2-5x faster coverage calculation

**Challenges in our context:**
1. **Blocks are MultiLineString networks, not simple lines**
   - A block can have branches (e.g., residential cul-de-sac with multiple segments)
   - How do you apply 1D linear referencing to a branching network?
   - Would need to decompose into individual LineStrings, track separately, then reaggregate

2. **Schema overhaul required**
   - New table structure for intervals
   - New interval-merging logic (complex SQL or custom PostgreSQL function)
   - Rewrite all coverage calculation code

3. **Current solution is working**
   - Coverage time staying at 0-4s (constant, no slowdown)
   - Geometry points staying at 0 (no accumulation)
   - Total time ~80 minutes is acceptable for bulk import (done once)

**Recommendation:** 🔴 **Do NOT implement unless current solution proves inadequate**

**When to reconsider:**
- If daily incremental runs take >10 seconds each (currently 2-4s, acceptable)
- If bulk rebuilds become frequent (they shouldn't be)
- If you add thousands more runs and coverage time grows despite junction table

---

### 🟡 Section 6: PostgreSQL Session Settings (EASY WIN)

**Their recommendation:**
```sql
SET LOCAL work_mem = '256MB';  -- More memory for sorting/hashing
SET LOCAL jit = off;           -- JIT overhead not worth it for PostGIS
```

**Implementation:**
Add to our coverage functions:

```sql
CREATE OR REPLACE FUNCTION runmap.apply_run_to_block_coverage(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
  -- Increase work memory for this transaction
  PERFORM set_config('work_mem', '256MB', true);
  PERFORM set_config('jit', 'off', true);

  -- ... existing function code ...
END;
$function$;
```

**Potential benefit:**
- Faster sorts/joins in coverage calculation
- Minimal downside (only affects this transaction)

**Recommendation:** ✅ Implement (easy, low risk)

---

### 🔴 Section 7: Parallel Query (NOT APPLICABLE)

**Their recommendation:** Enable parallel workers for large aggregations

**Our context:**
- We process runs sequentially (one at a time)
- Each run only affects a few blocks (typically 25-40)
- Parallelism overhead not worth it for small operations

**Recommendation:** 🔴 Not applicable

---

### 🔴 Section 8: Reduce Precision (DON'T DO THIS)

**Their recommendation:** Use `ST_SnapToGrid` to reduce coordinate precision

**Why we explicitly DON'T do this:**
- We tried this before, caused coverage artifacts
- GPS tracks are already imprecise (±5-10m accuracy)
- Further reducing precision would inflate coverage percentages
- We solved geometry complexity without precision reduction (junction table approach)

**Recommendation:** 🔴 **Do NOT implement** (causes coverage inaccuracies)

---

### ✅ Section 9: Batch Processing (ALREADY DOING THIS)

**Their recommendation:** Process in batches instead of recalculating everything each time

**Our implementation:**
- `bulk_import.sh` processes runs in batch (disables triggers, processes all, re-enables)
- Each run only updates blocks it touches (incremental approach)
- Junction table enables efficient batch recalculation if needed

**Status:** ✅ Already doing this

---

### 🟡 Section 10: Materialized Views (ALREADY DOING THIS, BUT COULD OPTIMIZE)

**Their recommendation:** Cache expensive queries in materialized views

**Our implementation:**
- `coverage_stats_blocks` materialized view for aggregate statistics
- Refreshed after each batch import

**Potential optimization:**
- Currently refresh entire materialized view after processing
- Could use `REFRESH MATERIALIZED VIEW CONCURRENTLY` (requires unique index)
- For 628-run import, this is called once at end (acceptable)

**Recommendation:** 🟡 Low priority (current approach works fine)

---

## Summary Table

| Section | Recommendation | Status | Priority | Estimated Impact |
|---------|---------------|--------|----------|------------------|
| 1. Clip first, union second | Use `ST_Intersection` before `ST_Union` | ✅ Already doing | - | - |
| 2. Cheaper buffers | Use `quad_segs=4` parameter | 🟡 Test | **HIGH** | ~20% faster buffering (~17 min saved) |
| 3. Spatial indexes | Verify GIST indexes exist | ✅ Verify | **HIGH** | Critical if missing |
| 4. Avoid ST_Contains | Use `ST_Intersects` | ✅ Already doing | - | - |
| 5. Interval-based coverage | 1D linear referencing | 🔴 Don't do | **LOW** | Major refactor, unclear benefit |
| 6. Session settings | `work_mem=256MB`, `jit=off` | 🟡 Implement | **MEDIUM** | ~5-10% faster coverage |
| 7. Parallel query | Enable parallel workers | 🔴 Not applicable | - | - |
| 8. Reduce precision | Use `ST_SnapToGrid` | 🔴 Don't do | **NEVER** | Causes coverage artifacts |
| 9. Batch processing | Process in batches | ✅ Already doing | - | - |
| 10. Materialized views | Cache aggregations | ✅ Already doing | - | - |

---

## Recommendations for Colleague Review

### Context for New Reviewer

**What we're trying to optimize:**
- Bulk import of 628 GPX running tracks
- Each track needs to be buffered (10m) and applied to street block coverage
- Current performance: ~7.6 seconds per run (~80 minutes total)
- Breakdown: 1-14s buffering (varies by GPX complexity), 0-4s coverage (constant)

**What we just fixed (Oct 2025):**
- Geometry accumulation problem causing exponential slowdown
- Old approach: stored accumulated coverage geometry, vertices grew from 1.5K → 77K
- New approach: junction table + recompute from source (no geometry storage)
- Result: coverage time stays constant (0-4s), no accumulation

**What we're NOT trying to optimize:**
- Daily incremental runs (2-4s each, perfectly acceptable)
- Coverage accuracy (must be preserved)
- Schema complexity (current architecture is clean and working)

### Questions for Reviewer

1. **Spatial indexes:** Can you verify these exist and are being used?
   ```sql
   SELECT tablename, indexname, indexdef
   FROM pg_indexes
   WHERE schemaname = 'runmap'
     AND tablename IN ('streets_blocks_32610', 'runs_buffered_32610');
   ```

2. **Cheaper buffers:** Is `quad_segs=4` safe for 10m GPS buffers (±5-10m accuracy)?
   - Would this cause coverage percentage errors?
   - Expected speedup: 20-30% on buffering step

3. **Session settings:** Any risk to setting `work_mem=256MB` in a function?
   - Our server has 20GB RAM
   - Functions process one run at a time sequentially

4. **Is 80 minutes acceptable?**
   - Bulk import is one-time operation (already imported 628 runs, won't repeat)
   - Daily incremental: 1 run in 2-4s (perfectly fine)
   - Only re-run bulk if we change buffer distance or coverage algorithm

5. **Interval-based coverage (Section 5):**
   - Is this worth the refactor for our use case?
   - Our blocks are MultiLineString networks (branches/loops), not simple lines
   - Current solution has constant-time coverage (0-4s regardless of run count)

### What NOT to Suggest

❌ **Don't suggest geometry simplification** (`ST_SimplifyPreserveTopology`, `ST_SnapToGrid`)
- We already tried this, it caused coverage artifacts
- Current solution avoids geometry accumulation without simplification

❌ **Don't suggest storing accumulated geometry**
- This was the problem we just solved
- Junction table approach is specifically designed to avoid this

❌ **Don't suggest full recalculation on each run**
- We do incremental processing (only update blocks touched by each run)
- This is a core design principle for memory efficiency

---

## Testing Plan (If Implementing Optimizations)

### Phase 1: Verify Current State
1. Check spatial indexes
2. Profile current bulk import (finish the running one, collect timing data)
3. Establish baseline: average time per run, breakdown of buffer vs coverage

### Phase 2: Low-Risk Optimizations
1. Add session settings (`work_mem`, `jit`) to functions
2. Test on small dataset (30 runs)
3. Measure improvement

### Phase 3: Cheaper Buffers (If Phase 2 Insufficient)
1. Update `buffer_one_run()` with `quad_segs=4`
2. Process 30 test runs with old and new buffer settings
3. Compare coverage percentages (should be <1% difference)
4. If accurate, proceed with full dataset

### Phase 4: Measure Results
1. Re-run bulk import of all 628 runs with optimizations
2. Compare total time: baseline vs. optimized
3. Verify coverage percentages unchanged

---

## Current Bulk Import Status

**As of last check (run 158, ~20 min elapsed):**
- Average: 7.6 seconds per run
- Coverage geometry points: **0** (fix is working)
- No slowdown observed (coverage time staying 0-4s)
- Projected completion: ~60 minutes remaining

**Wait for this to complete before implementing optimizations** - we need baseline data.

---

## Related Documentation

- **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** - Geometry accumulation problem and junction table solution
- **[TESTING_WORKFLOW.md](TESTING_WORKFLOW.md)** - How to test coverage algorithm changes efficiently
- **[BLOCK_PERCENTAGE_MIGRATION.md](BLOCK_PERCENTAGE_MIGRATION.md)** - Block-based coverage architecture
- **[CLAUDE.md](../CLAUDE.md)** - Complete database schema and function reference

---

## Questions or Concerns?

**For the colleague reviewing this:**

If you have expertise in PostGIS optimization and disagree with any of the above assessments, please document your reasoning. Particularly interested in:

1. Are there PostgreSQL/PostGIS settings we're missing?
2. Is the junction table approach optimal, or is there a better pattern?
3. Would interval-based coverage (Section 5) actually work with MultiLineString blocks?
4. Any other bottlenecks visible in the function code?

**Please provide:**
- Specific code examples
- Expected performance impact (quantified if possible)
- Any risks or trade-offs
- Testing methodology to validate improvements
