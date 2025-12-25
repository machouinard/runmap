# Documentation Synchronization Plan

**Date:** 2025-11-18
**Purpose:** Sync documentation with actual production system (segment-visited coverage)
**Status:** AWAITING APPROVAL

---

## Executive Summary

**Current Production System:** Segment-Visited Coverage (migrated 2025-10-20)

**Problem:** Documentation describes 3 different systems:
1. Old incremental (archived but referenced)
2. Block-percentage (never fully deployed, trigger file wrong)
3. Segment-visited (ACTUAL production, under-documented)

**Solution:** Update all docs to accurately describe segment-visited system only.

---

## Production Schema (VERIFIED)

### Tables (15 total)
- ✅ `block_coverage_segments` - Aggregate coverage (segment-visited)
- ✅ `block_segment_visited` - Binary flags (segment-visited)
- ✅ `block_segments` - 5m pre-segmented streets (segment-visited)
- ✅ `runs_buffered_subdiv` - Subdivided buffers (segment-visited)
- ✅ `streets_blocks_32610` - Street blocks
- ✅ `streets_reference` - OSM baseline (WGS84)
- ✅ `streets_reference_32610` - OSM baseline (UTM)
- ✅ `streets_reference_vertices_pgr` - pgRouting vertices
- ✅ `runs_raw` - Activity tracks
- ✅ `walks_raw` - Walk tracks
- ✅ `cycling_raw` - Cycling tracks
- ✅ `settings` - Configuration
- ✅ `performance_log` - Performance tracking
- ✅ `processing_errors` - Error log
- ✅ `aoi` - Areas of interest

### Active Trigger
```sql
trigger_auto_process_run_segments
  → runmap.auto_process_new_run_segments()
```

### Active Functions
- `buffer_one_run_subdiv(uuid)` - Buffer + subdivide run
- `apply_run_to_segments(uuid)` - Mark segments as visited

### Old Functions (exist but unused)
- `buffer_one_run(uuid)` - Old buffer function
- `apply_run_to_block_coverage(uuid)` - Old coverage function
- `apply_run_to_chunk_coverage(*)` - Very old

---

## Changes Proposed

### 🔴 CRITICAL: File 1 - `11_auto_process_trigger.sql`

**Status:** COMPLETELY WRONG - describes system that's not deployed

**Current Content:**
```sql
CREATE OR REPLACE FUNCTION runmap.auto_process_new_run()
RETURNS TRIGGER AS $$
BEGIN
  PERFORM runmap.buffer_one_run(NEW.id);           -- ❌ WRONG
  PERFORM runmap.apply_run_to_block_coverage(NEW.id); -- ❌ WRONG
  REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_auto_process_run               -- ❌ WRONG NAME
  AFTER INSERT ON runmap.runs_raw
  FOR EACH ROW
  EXECUTE FUNCTION runmap.auto_process_new_run();     -- ❌ WRONG FUNCTION
```

**ACTUAL Production Trigger:**
```sql
trigger_auto_process_run_segments                     -- ✅ ACTUAL NAME
  → runmap.auto_process_new_run_segments()            -- ✅ ACTUAL FUNCTION
```

**Proposed Action:**
- **OPTION A:** Replace file with actual production trigger code (need to extract from DB)
- **OPTION B:** Add deprecation notice and note this is NOT the deployed trigger
- **OPTION C:** Rename to `11_auto_process_trigger_OLD.sql` and create correct version

**Recommendation:** OPTION A - Replace with actual production code

---

### 🔴 CRITICAL: File 2 - `CLAUDE.md`

**Changes Needed:** 21 corrections

#### Section: Database Schema

**REMOVE these tables (don't exist in production):**
```diff
-`runmap.runs_buffered_32610` - Per-run buffers (MultiPolygon, 32610)
-- Fields: `run_id`, `geom` (buffer around single run)
-- No global union needed - incremental approach

-`runmap.block_coverage_32610` - Incremental block coverage state
-- Fields: `block_id`, `covered_geom`, `covered_length_m`, `total_length_m`, `coverage_pct`
-- Updated only for blocks touched by each new run
-- **Note:** `covered_geom` is NULL (not stored to prevent geometry accumulation)
-- Coverage calculated by unioning run buffers on-demand

-`runmap.block_run_coverage` - Junction table tracking which runs affect which blocks
-- Fields: `block_id`, `run_id`, `coverage_length_m`
-- Enables rebuild/recalculation without reprocessing GPX files
-- Prevents double-counting when same block is run multiple times
```

**ADD these tables (actual production):**
```diff
+`runmap.runs_buffered_subdiv` - Subdivided run buffers (Polygon, 32610)
+- Fields: `run_id`, `geom` (subdivided polygons from ST_Subdivide)
+- Multiple polygons per run for faster intersection tests
+- Used by segment-visited coverage system

+`runmap.block_segments` - Pre-segmented 5m street pieces (LineString, 32610)
+- Fields: `segment_id`, `block_id`, `segment_geom`, `segment_length_m`
+- One-time computation, ~5m pieces for granular coverage tracking
+- Enables constant-time coverage updates

+`runmap.block_segment_visited` - Binary visited flags for segments
+- Fields: `segment_id`, `visited` (boolean)
+- Core of the optimization - just mark TRUE/FALSE, no geometry unions
+- Constant-time updates regardless of run count

+`runmap.block_coverage_segments` - Aggregate coverage per block
+- Fields: `block_id`, `visited_length_m`, `total_length_m`, `coverage_pct`
+- Computed from count of visited segments
+- Replaces geometry-based coverage calculation

+`runmap.performance_log` - Performance tracking
+- Fields: `id`, `logged_at`, `operation`, `run_count`, `avg_seconds`, `total_seconds`, `optimization`, `notes`
+- Tracks optimization results and performance metrics

+`runmap.processing_errors` - Error log for failed processing
+- Tracks runs that failed to process with error details

+`runmap.aoi` - Areas of Interest
+- Defines Sacramento/Portland boundaries for location detection
```

#### Section: Critical Functions

**REMOVE (old functions):**
```diff
-`runmap.buffer_one_run(run_id)` - Creates 10m buffer for single run in UTM
-`runmap.apply_run_to_coverage(run_id)` - Incrementally updates coverage for streets intersecting run buffer
```

**ADD (current functions):**
```diff
+`runmap.buffer_one_run_subdiv(run_id)` - Creates 10m buffer and subdivides for fast intersection
+`runmap.apply_run_to_segments(run_id)` - Marks segments as visited (constant-time operation)
+`runmap.auto_process_new_run_segments()` - Trigger function that processes new runs automatically
```

#### Section: Incremental Coverage Algorithm

**REPLACE entire section:**

**OLD (lines 189-199):**
```markdown
1. **On GPX Upload:**
   - Insert to `runs_raw` (assigned auto-increment `gid`)
   - Call `buffer_one_run(gid)` → creates UTM buffer in `runs_buffered_32610`
   - Call `apply_run_to_coverage(gid)` → updates only intersecting streets:
     - For each street intersecting buffer: `ST_Intersection(street, buffer)`
     - If first coverage: store intersection as `covered_geom`
     - If already partial: `ST_Difference(new_intersection, existing_covered_geom)` → union with existing
   - Refresh `coverage_stats` materialized view
   - Export tiles
```

**NEW:**
```markdown
1. **On GPX Upload:**
   - Insert to `runs_raw` (UUID primary key, auto-generated)
   - **Trigger automatically fires:** `trigger_auto_process_run_segments`
   - Call `buffer_one_run_subdiv(id)` → creates UTM buffer + subdivides in `runs_buffered_subdiv`
   - Call `apply_run_to_segments(id)` → marks intersecting segments as visited:
     - Find segments intersecting run buffer
     - Set `visited = TRUE` for those segments (one-time, idempotent)
     - Update aggregate coverage in `block_coverage_segments`
   - Refresh `coverage_stats_blocks` materialized view
   - Export tiles
```

#### Section: Memory Usage

**UPDATE to reflect segment-visited performance:**
```diff
 ### Memory Usage

-- **Old system (full recalculation):** O(all runs × all streets) → 112GB RAM with 11 runs, crashes
-- **New system (incremental):** O(streets touched by new run) → ~3GB RAM regardless of run count
+- **Very old system (full recalculation):** O(all runs × all streets) → 112GB RAM, crashed with 11 runs
+- **Old system (incremental unions):** O(runs touching same block) → degraded to 27s/run with 265 runs
+- **Current system (segment-visited):** O(segments touched) → constant 0.4s/run regardless of run count
+- **Speedup:** 67x faster than union approach, truly constant time
 - Server (20GB RAM) can now process uploads without Mac Studio
```

#### Section: Views

**UPDATE view names:**
```diff
 **Views:**

-`runmap.streets_unrun` - Streets with <5% coverage (grey on map)
-`runmap.streets_partial` - Streets with 5-75% coverage (purple on map)
-`runmap.streets_complete` - Streets with ≥75% coverage (green on map)
-`runmap.coverage_stats` - Materialized view with overall coverage percentage
+`runmap.blocks_incomplete` - Blocks with <90% coverage (grey/purple on map)
+`runmap.blocks_complete` - Blocks with ≥90% coverage (green on map)
+`runmap.coverage_stats_blocks` - Materialized view with overall coverage statistics
```

#### Section: Common Commands - Database Operations

**UPDATE function calls:**
```diff
-# Run schema setup
-psql -U runmap_user -d runmap -h localhost -f db/01_create_tables.sql
-psql -U runmap_user -d runmap -h localhost -f db/03_incremental_coverage.sql
+# Initial setup (fresh database)
+psql -U runmap_user -d runmap -h localhost -f db/01_create_tables.sql
+psql -U runmap_user -d runmap -h localhost -f db/04_segment_schema.sql
+# Note: Trigger is created automatically by 04_segment_schema.sql
```

**UPDATE stats query:**
```diff
 # Check coverage stats
-psql -U runmap_user -d runmap -h localhost -c "SELECT * FROM runmap.coverage_stats;"
+psql -U runmap_user -d runmap -h localhost -c "SELECT * FROM runmap.coverage_stats_blocks;"
```

**UPDATE rebuild command:**
```diff
 # Full rebuild after buffer change (reprocess all runs)
-bash scripts/rebuild_all_coverage.sh
+bash scripts/rebuild_all_coverage.sh  # Uses segment-visited system
```

#### Section: Performance Monitoring

**REPLACE verification query:**
```diff
-# Verify segment-visited system is populated
-psql -U runmap_user -d runmap -h localhost << 'EOF'
-SELECT
-  (SELECT COUNT(*) FROM runmap.runs_raw) as total_runs,
-  (SELECT COUNT(DISTINCT run_id) FROM runmap.runs_buffered_subdiv) as buffered_runs,
-  (SELECT COUNT(*) FROM runmap.block_segments) as total_segments,
-  (SELECT COUNT(*) FROM runmap.block_segment_visited WHERE visited = true) as visited_segments,
-  (SELECT COUNT(*) FROM runmap.block_coverage_segments WHERE coverage_pct >= 90) as complete_blocks;
-EOF
+# Verify segment-visited system is populated
+psql -U runmap_user -d runmap -h localhost << 'EOF'
+SELECT
+  (SELECT COUNT(*) FROM runmap.runs_raw WHERE location = 'sacramento') as sac_runs,
+  (SELECT COUNT(DISTINCT run_id) FROM runmap.runs_buffered_subdiv) as buffered_runs,
+  (SELECT COUNT(*) FROM runmap.block_segments) as total_segments,
+  (SELECT COUNT(*) FROM runmap.block_segment_visited WHERE visited = true) as visited_segments,
+  (SELECT COUNT(*) FROM runmap.block_coverage_segments WHERE coverage_pct >= 90) as complete_blocks,
+  (SELECT ROUND(AVG(coverage_pct)::numeric, 2) FROM runmap.block_coverage_segments WHERE visited_length_m > 0) as avg_coverage_pct;
+EOF
```

#### Section: Migration Notes

**REPLACE section:**
```diff
-## Migration Notes
-
-**From full recalculation to incremental:**
-- Run `db/03_incremental_coverage.sql` to create new schema
-- Reprocess all existing runs: `for id in $(psql -t -c "SELECT gid FROM runmap.runs_raw"); do psql -c "SELECT runmap.buffer_one_run($id::bigint); SELECT runmap.apply_run_to_coverage($id::bigint);"; done`
-- Update API to call incremental functions instead of materialized view refreshes
-- See [docs/INCREMENTAL_MIGRATION.md](docs/INCREMENTAL_MIGRATION.md) for details
+## Migration Notes
+
+**Current System:** Segment-visited coverage (migrated 2025-10-20)
+- See [docs/SEGMENT_VISITED_MIGRATION.md](docs/SEGMENT_VISITED_MIGRATION.md) for migration details
+- Old systems archived in [docs/archive/](docs/archive/)
+
+**To rebuild coverage from scratch:**
+```bash
+bash scripts/rebuild_all_coverage.sh
+# Uses buffer_one_run_subdiv() + apply_run_to_segments()
+# Processes ~300 runs in ~2 minutes (constant time per run)
+```
```

---

### 🟡 MEDIUM: File 3 - `docs/README.md`

**Changes Needed:** Fix broken links, update system references

#### Lines 22-32: Architecture Section - BROKEN LINKS

**CURRENT:**
```markdown
- **[BLOCK_PERCENTAGE_MIGRATION.md](BLOCK_PERCENTAGE_MIGRATION.md)** - Block-based coverage architecture
- **[BLOCK_PERCENTAGE_PROPOSAL.md](BLOCK_PERCENTAGE_PROPOSAL.md)** - Original proposal for block-based coverage
```

**PROPOSED:**
```markdown
- **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** ⭐ **Current System** - Segment-visited coverage (2025-10-20)
  - Binary visited flags instead of geometry unions
  - Constant-time performance (0.4s/run regardless of total runs)
  - 67x speedup over previous approach
  - Migration summary and performance results
```

#### Lines 45-48: Data Processing - BROKEN LINK

**CURRENT:**
```markdown
- **[INCREMENTAL_MIGRATION.md](INCREMENTAL_MIGRATION.md)** - Incremental processing system
  - How runs are processed one at a time
  - Buffering and coverage application
  - Memory usage optimization (O(blocks touched) instead of O(all runs × all streets))
```

**PROPOSED:**
```markdown
- **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** - Current processing system
  - How runs are processed incrementally
  - Segment-based coverage tracking
  - Constant-time performance (O(segments touched), independent of run count)
```

#### Lines 156-157: Use Case - Wrong Link

**CURRENT:**
```markdown
### "I want to upload runs and view coverage"
→ **[USAGE_GUIDE.md](USAGE_GUIDE.md)**
```

**KEEP** (this is correct)

#### Lines 159-161: Use Case - UPDATE

**CURRENT:**
```markdown
### "I want to understand how coverage is calculated"
→ **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** (for algorithm details)
→ **[BLOCK_PERCENTAGE_MIGRATION.md](BLOCK_PERCENTAGE_MIGRATION.md)** (for architecture)
```

**PROPOSED:**
```markdown
### "I want to understand how coverage is calculated"
→ **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** (for current system)
→ **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** (for older system details - archived)
```

#### Lines 172-175: Use Case - UPDATE

**CURRENT:**
```markdown
### "I want to know why the system is designed this way"
→ **[BLOCK_PERCENTAGE_PROPOSAL.md](BLOCK_PERCENTAGE_PROPOSAL.md)** (blocks vs streets)
→ **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** (geometry handling)
→ **[SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md)** (memory/performance)
```

**PROPOSED:**
```markdown
### "I want to know why the system is designed this way"
→ **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** (segment-visited approach)
→ **[archive/PERFORMANCE_OPTIMIZATION.md](archive/PERFORMANCE_OPTIMIZATION.md)** (why unions failed)
→ **[SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md)** (memory/performance analysis)
```

#### Lines 186-198: Key Concepts Section - UPDATE

**CURRENT:**
```markdown
### Coverage Calculation

**How it works:**

1. **Buffering** (`buffer_one_run`): Create 10m buffer around GPS track in UTM projection
2. **Intersection**: Find blocks that intersect the buffer
3. **Coverage calculation** (`apply_run_to_block_coverage`):
   - Store per-run coverage in `block_run_coverage` junction table
   - Recompute total coverage by unioning ALL run buffers for each affected block
   - Calculate coverage length and percentage
   - **Don't store** the accumulated geometry (prevents complexity growth)

**Detailed explanation:** [PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)
```

**PROPOSED:**
```markdown
### Coverage Calculation

**How it works (Segment-Visited System):**

1. **Buffering** (`buffer_one_run_subdiv`): Create 10m buffer around GPS track, then subdivide into smaller polygons
2. **Intersection**: Find 5m street segments that intersect the subdivided buffer
3. **Mark visited** (`apply_run_to_segments`):
   - Set `visited = TRUE` for intersecting segments (one-time, idempotent)
   - Update aggregate coverage by counting visited segments
   - **No geometry unions** - just boolean flags (constant time)
   - Calculate coverage percentage: `(visited_segments × 5m) / total_block_length`

**Detailed explanation:** [SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)
```

#### Lines 210-217: Incremental Processing - UPDATE

**CURRENT:**
```markdown
### Incremental Processing

Each new run only updates blocks it touches - no full recalculation needed.

**Memory usage:** O(blocks touched) instead of O(all runs × all blocks)

**Detailed explanation:** [INCREMENTAL_MIGRATION.md](INCREMENTAL_MIGRATION.md)
```

**PROPOSED:**
```markdown
### Incremental Processing

Each new run only marks new segments as visited - no geometry recalculation needed.

**Performance:** Constant time (~0.4s/run) regardless of total run count

**Memory usage:** O(segments touched) - independent of total runs in database

**Detailed explanation:** [SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)
```

#### Add New Section: Archive Notice

**ADD at end of file:**
```markdown
---

## Archived Documentation

Historical documentation for previous coverage systems:

- **[archive/BLOCK_PERCENTAGE_MIGRATION.md](archive/BLOCK_PERCENTAGE_MIGRATION.md)** - Block-percentage coverage (superseded 2025-10-20)
- **[archive/BLOCK_PERCENTAGE_PROPOSAL.md](archive/BLOCK_PERCENTAGE_PROPOSAL.md)** - Original block-based proposal
- **[archive/INCREMENTAL_MIGRATION.md](archive/INCREMENTAL_MIGRATION.md)** - Early incremental system
- **[archive/PERFORMANCE_OPTIMIZATION.md](archive/PERFORMANCE_OPTIMIZATION.md)** - Junction table approach

These documents are kept for historical reference. The current production system is segment-visited coverage.
```

---

### 🟡 MEDIUM: File 4 - `db/README.md`

**Changes Needed:** Fix missing file references

#### Lines 20-28: Initial Setup - BROKEN REFERENCES

**CURRENT:**
```markdown
# 1. Create core tables (runs, streets, settings)
psql -U runmap_user -d runmap -h localhost -f db/01_create_tables.sql

# 2. Create block-based street segmentation
psql -U runmap_user -d runmap -h localhost -f db/02_create_blocks.sql

# 3. Create segment-based coverage system (recommended - replaces old buffer system)
psql -U runmap_user -d runmap -h localhost -f db/04_segment_schema.sql

# 4. Create auto-processing triggers
psql -U runmap_user -d runmap -h localhost -f db/05_triggers.sql
```

**PROPOSED:**
```markdown
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

#### Lines 39-44: Block Schema - REMOVE WRONG FILE

**CURRENT:**
```markdown
- **`02_create_blocks.sql`** - Street block segmentation
  - `streets_blocks_32610` - Groups of connected street segments
  - `block_segments` - Pre-segmented 5m street pieces for fast coverage calculation
  - More granular than individual streets
```

**PROPOSED:**
```markdown
(Removed - block creation is part of 04_segment_schema.sql)
```

#### Lines 54-60: Triggers - FIX FILE REFERENCE

**CURRENT:**
```markdown
### Triggers

- **`05_triggers.sql`** - Automatic processing triggers
  - `trigger_auto_process_run_segments` - Auto-buffer and update coverage on insert
  - `trigger_cleanup_coverage_on_delete` - Recalculate coverage when runs deleted
  - `trigger_set_location_before_insert` - Auto-detect location (Sacramento/Portland/other)
```

**PROPOSED:**
```markdown
### Triggers

Triggers are created by `04_segment_schema.sql`:
  - `trigger_auto_process_run_segments` - Auto-buffer and update coverage on insert
  - `trigger_set_location_before_insert` - Auto-detect location (Sacramento/Portland/other)

**Note:** Cleanup triggers are NOT currently implemented. Deleting runs requires manual coverage rebuild.
```

#### Lines 62-71: Obsolete Files - UPDATE LIST

**CURRENT:**
```markdown
## Obsolete Files (For Reference Only)

These files represent old approaches that have been replaced:

- `03_incremental_coverage.sql` - Old incremental coverage (replaced by segment system)
- `03_incremental_coverage_fixed.sql` - Fixed version (still replaced)
- `06_cleanup_old_system.sql` - Removes old buffer tables
- `07_highway_specific_buffers.sql` - Old buffer configuration
- `10_fix_buffer_function.sql` - Old buffer function fixes

**Do not run these on new databases.**
```

**PROPOSED:**
```markdown
## Obsolete Files (For Reference Only)

These files represent old approaches that have been replaced:

- `03_incremental_coverage.sql` - Very old incremental coverage
- `03_incremental_coverage_fixed.sql` - Fixed version of old system
- `09_block_percentage_coverage.sql` - Block-percentage system (never fully deployed)
- `10_fix_buffer_function.sql` - Old buffer function fixes
- `11_auto_process_trigger.sql` - **WRONG** - Documents non-existent trigger (see issue #XXX)

**Do not run these on new databases.** The current system is defined in `04_segment_schema.sql`.
```

---

### 🟢 LOW: File 5 - `docs/SEGMENT_VISITED_MIGRATION.md`

**Changes Needed:** Add production confirmation banner

**ADD at top (after line 6):**
```diff
 **Status:** ✅ COMPLETE - Successfully deployed to production

+---
+
+## ⭐ **THIS IS THE CURRENT PRODUCTION SYSTEM** ⭐
+
+This document describes the **actively deployed** coverage system as of 2025-10-20.
+All other coverage approaches (incremental unions, block-percentage, chunk-based)
+have been superseded and archived.
+
+**Verified production deployment:**
+- ✅ Tables: `block_segments`, `block_segment_visited`, `block_coverage_segments`, `runs_buffered_subdiv`
+- ✅ Trigger: `trigger_auto_process_run_segments` → `auto_process_new_run_segments()`
+- ✅ Functions: `buffer_one_run_subdiv()`, `apply_run_to_segments()`
+
+---
+
 ## Final Results
```

---

## Summary of Changes

| File | Priority | Changes | Lines Affected |
|------|----------|---------|----------------|
| `CLAUDE.md` | 🔴 CRITICAL | 21 corrections | ~150 lines |
| `11_auto_process_trigger.sql` | 🔴 CRITICAL | Replace entire file | ~74 lines |
| `docs/README.md` | 🟡 MEDIUM | Fix 8 broken links | ~50 lines |
| `db/README.md` | 🟡 MEDIUM | Fix file refs | ~30 lines |
| `docs/SEGMENT_VISITED_MIGRATION.md` | 🟢 LOW | Add banner | +15 lines |

**Total:** ~320 lines changed across 5 files

---

## Next Steps

**Awaiting user approval to proceed with:**

1. ✅ Apply changes to `CLAUDE.md` (most important for AI context)
2. ✅ Fix `11_auto_process_trigger.sql` (currently misleading)
3. ✅ Fix `docs/README.md` broken links
4. ✅ Fix `db/README.md` file references
5. ✅ Add banner to `SEGMENT_VISITED_MIGRATION.md`

**OR:**

- Request changes to this plan
- See detailed diff for specific file first
- Apply changes incrementally (one file at a time)

---

**END OF PLAN**
