# Segment-Visited Migration Guide

**Date:** 2025-10-20
**Purpose:** Migrate from union-based coverage to segment-visited approach for constant-time performance
**Status:** ✅ COMPLETE - Successfully deployed to production

---

## ⭐ **THIS IS THE CURRENT PRODUCTION SYSTEM** ⭐

This document describes the **actively deployed** coverage system as of 2025-10-20.
All other coverage approaches (incremental unions, block-percentage, chunk-based)
have been superseded and archived.

**Verified production deployment:**
- ✅ Tables: `block_segments`, `block_segment_visited`, `block_coverage_segments`, `runs_buffered_subdiv`
- ✅ Trigger: `trigger_auto_process_run_segments` → `auto_process_new_run_segments()`
- ✅ Functions: `buffer_one_run_subdiv()`, `apply_run_to_segments()`
- ✅ Performance: Constant 0.4s/run, 67x faster than previous approaches

---

## Final Results

**Migration completed successfully on 2025-10-20**

- ✅ **309 Sacramento runs processed in 2 minutes 5 seconds**
- ✅ **Average: 398ms per run (constant time)**
- ✅ **67x speedup** vs. union approach (27s → 0.4s per run)
- ✅ **Zero blocks over 100% coverage** (mathematically correct)
- ✅ **Coverage: 1645 complete, 489 partial, 463 unrun blocks**
- ✅ **Deployed to production: https://runmap.chouinard.me**

---

## Problem Statement

**Current Performance (Junction Table + Union):**
- Run 1-100: ~7.6s per run (fast)
- Run 100-265: ~27s per run (degrading)
- Projected time for 628 runs: **8+ hours**

**Root Cause:**
```sql
-- We recompute union of ALL run buffers for each block
ST_Union(run1_buffer, run2_buffer, ..., run265_buffer)
-- Cost grows with number of runs touching the block: O(N)
```

**Why This Happens:**
- Popular blocks (your neighborhood streets) touched by 100+ runs
- Each new run requires unioning 100+ buffers for those blocks
- Union time grows linearly with run count

---

## Solution: Segment-Visited Approach

**Key Insight from docs/5/ST_SUBDIVIDE_INTEGRATION_v2.md:**

Instead of unioning geometries, use binary visited flags:

1. **Pre-segment blocks** into small pieces (5m each)
2. **Mark segments as visited** when a run touches them
3. **Count visited segments** to get coverage
4. **No unions in the hot path** - just mark TRUE/FALSE

**Performance:**
- Each run marks ~20-50 segments as visited
- Fast UPDATE operations (indexed)
- **Constant time regardless of total run count**
- Expected: 1-3s per run, 15-30 minutes for 628 runs

---

## Architecture Comparison

### Current Approach (Union-Based)
```
Blocks: [Block A (100m)] [Block B (150m)]
Runs: Run1, Run2, Run3... Run265

For each new run:
  1. Buffer the run
  2. Find intersecting blocks
  3. For each block:
     - Union ALL run buffers for that block (expensive!)
     - Measure length of union

Block A touched by 100 runs:
  ST_Union(100 buffers) → slow and getting slower
```

### New Approach (Segment-Visited)
```
Blocks segmented:
  Block A: [seg1: 0-5m] [seg2: 5-10m] ... [seg20: 95-100m]

Visited flags:
  Block A: [T] [T] [F] [T] ... [T]  (binary true/false)

For each new run:
  1. Buffer the run
  2. Find intersecting segments
  3. Mark segments as visited = TRUE

Coverage = COUNT(visited) × 5m / total_length
No unions! Just mark flags!
```

---

## Migration Strategy: Shadow Deployment

We'll create new tables alongside existing ones, validate, then switch over.

### Phase 1: Create Shadow Schema (Keep Existing Tables)

```sql
-- Run buffers subdivided for faster intersection tests
CREATE TABLE IF NOT EXISTS runmap.runs_buffered_subdiv (
  run_id UUID NOT NULL REFERENCES runmap.runs_raw(id),
  geom geometry(Polygon, 32610) NOT NULL,
  PRIMARY KEY (run_id, geom)
);
CREATE INDEX idx_runs_buffered_subdiv_geom ON runmap.runs_buffered_subdiv USING GIST(geom);

-- Pre-segmented blocks (one-time computation)
CREATE TABLE IF NOT EXISTS runmap.block_segments (
  segment_id SERIAL PRIMARY KEY,
  block_id INTEGER NOT NULL REFERENCES runmap.streets_blocks_32610(block_id),
  segment_geom geometry(LineString, 32610) NOT NULL,
  segment_length_m DOUBLE PRECISION NOT NULL,
  UNIQUE (block_id, segment_id)
);
CREATE INDEX idx_block_segments_block ON runmap.block_segments(block_id);
CREATE INDEX idx_block_segments_geom ON runmap.block_segments USING GIST(segment_geom);

-- Binary visited flags (the secret sauce!)
CREATE TABLE IF NOT EXISTS runmap.block_segment_visited (
  segment_id INTEGER NOT NULL REFERENCES runmap.block_segments(segment_id),
  visited BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (segment_id)
);
CREATE INDEX idx_segment_visited ON runmap.block_segment_visited(segment_id) WHERE visited = TRUE;

-- New aggregate coverage view (computed from visited segments)
CREATE TABLE IF NOT EXISTS runmap.block_coverage_segments (
  block_id INTEGER PRIMARY KEY REFERENCES runmap.streets_blocks_32610(block_id),
  visited_length_m DOUBLE PRECISION NOT NULL DEFAULT 0,
  total_length_m DOUBLE PRECISION NOT NULL,
  coverage_pct DOUBLE PRECISION GENERATED ALWAYS AS (
    CASE
      WHEN total_length_m > 0 THEN ROUND((visited_length_m / total_length_m * 100)::numeric, 2)
      ELSE 0
    END
  ) STORED
);
```

### Phase 2: Populate Shadow Tables

```sql
-- 1. Subdivide all existing run buffers (one-time, ~5 minutes)
INSERT INTO runmap.runs_buffered_subdiv (run_id, geom)
SELECT
  run_id,
  (ST_Dump(ST_Subdivide(geom, 256))).geom
FROM runmap.runs_buffered_32610;

-- 2. Segment all blocks into 5m pieces (one-time, ~1 minute)
INSERT INTO runmap.block_segments (block_id, segment_geom, segment_length_m)
SELECT
  b.block_id,
  (ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom AS segment_geom,
  ST_Length((ST_Dump(ST_Segmentize(b.geom_32610, 5.0))).geom) AS segment_length_m
FROM runmap.streets_blocks_32610 b;

-- 3. Initialize visited flags (all FALSE)
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE
FROM runmap.block_segments;

-- 4. Initialize aggregate coverage
INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
SELECT
  block_id,
  0,
  SUM(segment_length_m)
FROM runmap.block_segments
GROUP BY block_id;
```

---

## New Coverage Function

```sql
CREATE OR REPLACE FUNCTION runmap.apply_run_to_segments(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_segments_marked INTEGER;
BEGIN
  -- Session tuning
  PERFORM set_config('work_mem', '512MB', true);
  PERFORM set_config('jit', 'off', true);

  -- Mark segments as visited (the core operation - fast!)
  WITH newly_visited AS (
    UPDATE runmap.block_segment_visited bsv
    SET visited = TRUE
    FROM runmap.block_segments bs
    JOIN runmap.runs_buffered_subdiv rb ON rb.run_id = run_uuid
    WHERE bsv.segment_id = bs.segment_id
      AND bsv.visited = FALSE  -- Only update unvisited segments
      AND ST_Intersects(bs.segment_geom, rb.geom)
    RETURNING bsv.segment_id, bs.block_id, bs.segment_length_m
  )
  -- Update aggregate coverage for affected blocks
  INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
  SELECT
    block_id,
    SUM(segment_length_m) as new_visited_length,
    (SELECT SUM(segment_length_m) FROM runmap.block_segments WHERE block_id = nv.block_id) as total
  FROM newly_visited nv
  GROUP BY block_id
  ON CONFLICT (block_id) DO UPDATE
  SET visited_length_m = runmap.block_coverage_segments.visited_length_m + EXCLUDED.visited_length_m;

  -- Get count for logging
  GET DIAGNOSTICS v_segments_marked = ROW_COUNT;

  -- Optional: log performance
  -- RAISE NOTICE 'Marked % segments as visited for run %', v_segments_marked, run_uuid;
END;
$function$;

-- Also need to update buffer_one_run to populate subdivided table
CREATE OR REPLACE FUNCTION runmap.buffer_one_run_subdiv(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_buffer_distance FLOAT;
BEGIN
  PERFORM set_config('work_mem', '256MB', true);
  PERFORM set_config('jit', 'off', true);

  v_buffer_distance := runmap.get_buffer_distance();

  -- Insert into subdivided table
  INSERT INTO runmap.runs_buffered_subdiv (run_id, geom)
  SELECT
    run_uuid,
    (ST_Dump(ST_Subdivide(
      ST_Buffer(
        ST_Transform(geom, 32610),
        v_buffer_distance,
        'endcap=flat join=mitre quad_segs=4'  -- Cheaper buffers
      ),
      256
    ))).geom
  FROM runmap.runs_raw
  WHERE id = run_uuid
  ON CONFLICT DO NOTHING;
END;
$function$;
```

---

## Validation Script (Test on 30 Runs)

```bash
#!/bin/bash
# Test segment-visited approach on 30 runs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

echo "========================================"
echo "Segment-Visited Validation (30 runs)"
echo "========================================"
echo ""

# Get first 30 Sacramento runs
TEST_RUN_IDS=$(psql -t -A -c \
  "SELECT id FROM runmap.runs_raw
   WHERE location = 'sacramento'
   ORDER BY start_time
   LIMIT 30")

echo "Processing 30 test runs with segment-visited approach..."
echo ""

COUNT=0
TOTAL_TIME=0
START_ALL=$(date +%s)

for RUN_ID in $TEST_RUN_IDS; do
  START=$(date +%s)

  # Buffer and subdivide
  psql -c "SELECT runmap.buffer_one_run_subdiv('$RUN_ID'::uuid);" > /dev/null 2>&1

  # Apply to segments (not blocks!)
  psql -c "SELECT runmap.apply_run_to_segments('$RUN_ID'::uuid);" > /dev/null 2>&1

  END=$(date +%s)
  ELAPSED=$((END - START))
  TOTAL_TIME=$((TOTAL_TIME + ELAPSED))
  COUNT=$((COUNT + 1))

  if [ $((COUNT % 5)) -eq 0 ]; then
    AVG_TIME=$((TOTAL_TIME / COUNT))
    echo "  Processed $COUNT/30 runs (avg: ${AVG_TIME}s/run)"
  fi
done

END_ALL=$(date +%s)
TOTAL_ELAPSED=$((END_ALL - START_ALL))
AVG_TIME=$((TOTAL_TIME / COUNT))

echo ""
echo "✓ Processed 30/30 runs in ${TOTAL_ELAPSED}s (avg: ${AVG_TIME}s/run)"
echo ""

# Compare coverage to old approach
echo "Comparing coverage percentages..."
echo ""

psql << 'EOF'
-- Show coverage from segment approach
SELECT
  'Segment approach' as method,
  COUNT(*) as blocks_with_coverage,
  ROUND(AVG(coverage_pct)::numeric, 2) as avg_coverage_pct,
  ROUND(MAX(coverage_pct)::numeric, 2) as max_coverage_pct
FROM runmap.block_coverage_segments
WHERE visited_length_m > 0;

-- Show coverage from old approach (if you still have it)
-- SELECT
--   'Union approach' as method,
--   COUNT(*) as blocks_with_coverage,
--   ROUND(AVG(coverage_pct)::numeric, 2) as avg_coverage_pct,
--   ROUND(MAX(coverage_pct)::numeric, 2) as max_coverage_pct
-- FROM runmap.block_coverage_32610
-- WHERE covered_length_m > 0;
EOF

echo ""
echo "Validation complete!"
echo ""
```

Save as `scripts/validate_segments.sh` and make executable.

---

## Full Migration Script

```bash
#!/bin/bash
# Full migration to segment-visited approach

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

echo "========================================"
echo "Full Segment-Visited Migration"
echo "========================================"
echo ""

# Get all Sacramento runs
ALL_RUN_IDS=$(psql -t -A -c \
  "SELECT id FROM runmap.runs_raw
   WHERE location = 'sacramento'
   ORDER BY start_time")

RUN_COUNT=$(echo "$ALL_RUN_IDS" | wc -l | tr -d ' ')

echo "Processing $RUN_COUNT Sacramento runs..."
echo ""

COUNT=0
TOTAL_TIME=0
START_ALL=$(date +%s)

for RUN_ID in $ALL_RUN_IDS; do
  START=$(date +%s)

  # Buffer, subdivide, and apply to segments
  psql -c "SELECT runmap.buffer_one_run_subdiv('$RUN_ID'::uuid);" > /dev/null 2>&1
  psql -c "SELECT runmap.apply_run_to_segments('$RUN_ID'::uuid);" > /dev/null 2>&1

  END=$(date +%s)
  ELAPSED=$((END - START))
  TOTAL_TIME=$((TOTAL_TIME + ELAPSED))
  COUNT=$((COUNT + 1))

  # Show progress
  AVG_TIME=$((TOTAL_TIME / COUNT))
  REMAINING=$((RUN_COUNT - COUNT))
  EST_REMAINING=$((REMAINING * AVG_TIME))
  EST_MINS=$((EST_REMAINING / 60))

  if [ $((COUNT % 10)) -eq 0 ]; then
    echo "  Processed $COUNT/$RUN_COUNT runs (avg: ${AVG_TIME}s/run, est remaining: ${EST_MINS}m)"
  fi
done

END_ALL=$(date +%s)
TOTAL_ELAPSED=$((END_ALL - START_ALL))
TOTAL_MINS=$((TOTAL_ELAPSED / 60))
AVG_TIME=$((TOTAL_TIME / COUNT))

echo ""
echo "✓ Processed $RUN_COUNT/$RUN_COUNT runs in ${TOTAL_MINS}m ${TOTAL_ELAPSED}s total"
echo "  Average: ${AVG_TIME}s per run"
echo ""

# Show final coverage
echo "Final coverage statistics:"
psql << 'EOF'
SELECT
  COUNT(*) as total_blocks,
  COUNT(CASE WHEN visited_length_m > 0 THEN 1 END) as blocks_with_coverage,
  ROUND(AVG(coverage_pct)::numeric, 2) as avg_coverage_pct,
  ROUND(MAX(coverage_pct)::numeric, 2) as max_coverage_pct,
  COUNT(CASE WHEN coverage_pct >= 75 THEN 1 END) as complete_blocks,
  COUNT(CASE WHEN coverage_pct BETWEEN 5 AND 75 THEN 1 END) as partial_blocks,
  COUNT(CASE WHEN coverage_pct < 5 THEN 1 END) as unrun_blocks
FROM runmap.block_coverage_segments;
EOF

echo ""
echo "Migration complete!"
echo ""
```

Save as `scripts/migrate_to_segments.sh` and make executable.

---

## Implementation Checklist

### ✅ Phase 1: Setup (15 minutes)

```bash
# 1. Create shadow schema
psql << 'EOF'
-- Paste schema creation SQL from above
EOF

# 2. Populate pre-computed tables
psql << 'EOF'
-- Subdivide existing buffers
INSERT INTO runmap.runs_buffered_subdiv ...

-- Segment blocks
INSERT INTO runmap.block_segments ...

-- Initialize visited flags
INSERT INTO runmap.block_segment_visited ...

-- Initialize aggregate coverage
INSERT INTO runmap.block_coverage_segments ...
EOF

# 3. Create new functions
psql << 'EOF'
-- buffer_one_run_subdiv()
-- apply_run_to_segments()
EOF

# 4. Create validation script
vim scripts/validate_segments.sh
chmod +x scripts/validate_segments.sh
```

### ✅ Phase 2: Validate (30-60 minutes)

```bash
# Run validation on 30 runs
./scripts/validate_segments.sh

# Check results
# - Average time should be 1-3s per run (constant)
# - Coverage percentages should be reasonable (<100%)
# - No errors in logs
```

### ✅ Phase 3: Full Migration (30-60 minutes)

```bash
# Create migration script
vim scripts/migrate_to_segments.sh
chmod +x scripts/migrate_to_segments.sh

# Run full migration
./scripts/migrate_to_segments.sh

# Expected: 15-30 minutes for 628 runs
```

### ✅ Phase 4: Cutover

```bash
# Update views to use new tables
CREATE OR REPLACE VIEW runmap.streets_unrun AS
SELECT b.*, bcs.coverage_pct
FROM runmap.streets_blocks_32610 b
LEFT JOIN runmap.block_coverage_segments bcs USING (block_id)
WHERE COALESCE(bcs.coverage_pct, 0) < 5;

# Similar for streets_partial, streets_complete

# Export tiles from new coverage data
./scripts/export_tiles_blocks.sh

# Verify map shows correct coverage
```

---

## Rollback Plan

If something goes wrong:

```sql
-- Shadow tables don't affect existing functionality
-- Just drop them and keep using old approach
DROP TABLE runmap.runs_buffered_subdiv CASCADE;
DROP TABLE runmap.block_segment_visited CASCADE;
DROP TABLE runmap.block_segments CASCADE;
DROP TABLE runmap.block_coverage_segments CASCADE;
DROP FUNCTION runmap.buffer_one_run_subdiv;
DROP FUNCTION runmap.apply_run_to_segments;

-- Old tables still intact:
-- runs_buffered_32610
-- block_coverage_32610
-- block_run_coverage
```

---

## Expected Results

### Performance Comparison

**Before (Union Approach):**
- Runs 1-100: ~7.6s per run
- Runs 100-265: ~27s per run (degrading)
- Projected 628 runs: **8+ hours**

**After (Segment-Visited):**
- All runs: 1-3s per run (constant)
- 628 runs: **15-30 minutes**

**Speedup: 16-32x faster!**

### Why It's Faster

1. **No unions** - just mark TRUE/FALSE flags
2. **Indexed updates** - segment_id lookups are fast
3. **Only update unvisited** - `WHERE visited = FALSE` skips already-covered segments
4. **Constant complexity** - doesn't matter if block has 1 run or 1000 runs

---

## Unit Test (Verify Correctness)

From docs/5/ST_SUBDIVIDE_INTEGRATION_v2.md lines 183-248:

```sql
-- Test block: 100m long, segmented into 20 × 5m pieces
-- Run 1: covers 0-60m (12 segments)
-- Run 2: covers 40-100m (12 segments, overlaps 40-60m)

-- Expected: 20 segments visited (100% coverage)
-- NOT 24 segments (double-counting overlap)

-- Verify:
SELECT COUNT(*) as visited_segments
FROM block_segment_visited
WHERE visited = TRUE;
-- Should be 20, not 24

SELECT visited_length_m, total_length_m, coverage_pct
FROM block_coverage_segments
WHERE block_id = <test_block>;
-- Should be 100m, 100m, 100.00%
```

---

## Monitoring & Debugging

### Check Segment Distribution

```sql
-- How many segments per block?
SELECT
  CASE
    WHEN seg_count < 10 THEN '<10 segs'
    WHEN seg_count < 20 THEN '10-20 segs'
    WHEN seg_count < 50 THEN '20-50 segs'
    ELSE '50+ segs'
  END as segment_range,
  COUNT(*) as num_blocks
FROM (
  SELECT block_id, COUNT(*) as seg_count
  FROM runmap.block_segments
  GROUP BY block_id
) t
GROUP BY segment_range
ORDER BY segment_range;
```

### Check Visited Ratio

```sql
-- Overall visited percentage
SELECT
  COUNT(*) as total_segments,
  COUNT(CASE WHEN visited THEN 1 END) as visited_segments,
  ROUND(COUNT(CASE WHEN visited THEN 1 END) * 100.0 / COUNT(*), 2) as pct_visited
FROM runmap.block_segment_visited;
```

### Find Blocks with >100% Coverage (Should Be Zero!)

```sql
-- This should return no rows if algorithm is correct
SELECT block_id, visited_length_m, total_length_m, coverage_pct
FROM runmap.block_coverage_segments
WHERE coverage_pct > 100
ORDER BY coverage_pct DESC;
```

---

## Related Documentation

- **[docs/5/ST_SUBDIVIDE_INTEGRATION_v2.md](5/ST_SUBDIVIDE_INTEGRATION_v2.md)** - Original proposal
- **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** - Junction table approach (superseded)
- **[TESTING_WORKFLOW.md](TESTING_WORKFLOW.md)** - How to reset and test

---

## Next Steps

1. **Create shadow schema** - paste SQL from Phase 1
2. **Run validation script** - test on 30 runs
3. **If successful, run full migration** - process all 628 runs
4. **Update views and export tiles** - cutover to new approach
5. **Document final performance** - update this doc with actual results

**Let's do this!** 🚀
