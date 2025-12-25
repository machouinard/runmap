# Database Cleanup Plan: Remove Obsolete Tables

**Date:** 2025-10-20
**Status:** Ready to execute
**Impact:** Low risk - only removes unused tables

## Overview

The RunMap database contains several obsolete tables from previous system iterations. These tables are no longer used but still reference old approaches in scripts and documentation.

## System Evolution

The coverage tracking system evolved through several approaches:

1. **Street-level geometry unions** (2024)
   - Table: `street_coverage_32610`
   - Problem: Not granular enough for block-level tracking

2. **Block-level with single buffers** (Early 2025)
   - Tables: `runs_buffered_32610`, `block_coverage_32610`
   - Problem: Expensive ST_Union operations, performance degraded with more runs

3. **Junction table approach** (Mid 2025)
   - Table: `block_run_coverage`
   - Problem: Still required geometry unions per block

4. **Segment-visited with subdivided buffers** (Oct 2025) ✅ **CURRENT**
   - Tables: `runs_buffered_subdiv`, `block_segments`, `block_segment_visited`, `block_coverage_segments`
   - Result: 67x speedup, constant-time performance

## Tables to Remove

| Table | Size | Rows | Last Used | Replaced By |
|-------|------|------|-----------|-------------|
| `street_coverage_32610` | 24 KB | 0 | N/A | Block-based architecture |
| `block_coverage_32610` | 104 KB | 201 | Testing only | `block_coverage_segments` |
| `block_run_coverage` | 88 KB | 214 | Testing only | `block_segment_visited` |
| `runs_buffered_32610` | 208 KB | 2 | Old runs only | `runs_buffered_subdiv` |

**Total space to reclaim:** ~424 KB

## Current Active Tables (Will NOT Be Removed)

| Table | Size | Purpose |
|-------|------|---------|
| `streets_reference` | 1 MB | Original OSM data (WGS84) |
| `streets_reference_32610` | 1 MB | UTM-projected streets (derived from above) |
| `streets_blocks_32610` | 744 KB | Streets split at intersections |
| `block_segments` | 8.6 MB | 5m subdivisions of blocks |
| `block_segment_visited` | 8 MB | Boolean visited flags |
| `block_coverage_segments` | 456 KB | Precomputed coverage % per block |
| `runs_buffered_subdiv` | 10 MB | Subdivided run buffers |
| `runs_raw` | 17 MB | All GPS tracks |
| `walks_raw` | 19 MB | Walking tracks |
| `cycling_raw` | 264 KB | Cycling tracks |

## Migration Steps

### 1. Pre-Migration Verification

```bash
# Verify current system has data
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT
  (SELECT COUNT(*) FROM runmap.runs_buffered_subdiv) as subdiv_buffers,
  (SELECT COUNT(*) FROM runmap.block_segments) as segments,
  (SELECT COUNT(*) FROM runmap.block_segment_visited) as visited_flags,
  (SELECT COUNT(*) FROM runmap.block_coverage_segments) as coverage_records;
EOF
```

**Expected output:**
- `subdiv_buffers`: ~4,000+ (subdivided polygons)
- `segments`: ~52,000+ (5m segments)
- `visited_flags`: ~52,000+ (one per segment)
- `coverage_records`: ~2,000+ (blocks with coverage)

**If ANY value is 0, DO NOT proceed!**

### 2. Backup Database

```bash
# Full backup
pg_dump -h 192.168.68.25 -U runmap_user -d runmap \
  > backup_runmap_before_cleanup_$(date +%Y%m%d_%H%M%S).sql

# Or backup just the obsolete tables (for rollback)
pg_dump -h 192.168.68.25 -U runmap_user -d runmap \
  -t runmap.street_coverage_32610 \
  -t runmap.block_coverage_32610 \
  -t runmap.block_run_coverage \
  -t runmap.runs_buffered_32610 \
  > backup_obsolete_tables_$(date +%Y%m%d).sql
```

### 3. Run Cleanup Migration

```bash
# Execute the cleanup script
PGPASSWORD=fucker psql -h 192.168.68.25 -U runmap_user -d runmap \
  -f db/12_cleanup_obsolete_tables.sql
```

**Expected output:**
```
======================================
Database Cleanup: Obsolete Tables
======================================

✓ Safety check passed:
  - runs_buffered_subdiv: 4419 rows
  - block_segments: 52295 rows
  - block_segment_visited: 52295 rows

Analyzing obsolete tables...

       table_name        | row_count | size  |          reason
-------------------------+-----------+-------+---------------------------
 runs_buffered_32610     |         2 | 208KB | Old single-buffer approach
 block_coverage_32610    |       201 | 104KB | Old geometry-union approach
 block_run_coverage      |       214 | 88KB  | Intermediate junction table
 street_coverage_32610   |         0 | 24KB  | Pre-block-splitting system

Dropping obsolete tables...

1. Dropping street_coverage_32610...
2. Dropping block_coverage_32610...
3. Dropping block_run_coverage...
4. Dropping runs_buffered_32610...

======================================
Cleanup Complete!
======================================
```

### 4. Update Scripts

The following scripts reference obsolete tables and need updating:

#### A. `scripts/bulk_import.sh`

**Lines to update:**
- Line 103: Change `runs_buffered_32610` → `runs_buffered_subdiv`
- Line 132: Change `runs_buffered_32610` → `runs_buffered_subdiv`
- Line 168: Change `block_coverage_32610` → `block_coverage_segments`

**Original:**
```bash
WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_32610 rb WHERE rb.run_id = r.id)
```

**Updated:**
```bash
WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_subdiv rb WHERE rb.run_id = r.id)
```

#### B. `scripts/process_all_runs.sh`

**Lines to update:**
- Lines 20, 40: Change `runs_buffered_32610` → `runs_buffered_subdiv`
- Lines 69, 105: Change buffer check queries

**Original:**
```bash
WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_32610 rb WHERE rb.run_id = r.id)
```

**Updated:**
```bash
WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_subdiv rb WHERE rb.run_id = r.id)
```

#### C. `scripts/reset_coverage.sh`

**Lines to update:**
- Lines 28, 30: Change table references

**Original:**
```sql
SELECT 'Buffered runs: ' || COUNT(*) FROM runmap.runs_buffered_32610
SELECT 'Blocks with coverage: ' || COUNT(*) FROM runmap.block_coverage_32610
```

**Updated:**
```sql
SELECT 'Buffered runs: ' || COUNT(*) FROM runmap.runs_buffered_subdiv
SELECT 'Blocks with coverage: ' || COUNT(*) FROM runmap.block_coverage_segments
```

#### D. `scripts/delete_recent_20_runs.sh`

**Line to update:**
- Line 45: Change `runs_buffered_32610` → `runs_buffered_subdiv`

### 5. Update Documentation

#### A. `CLAUDE.md`

**Section: "Performance Monitoring" (lines 329-330)**

**Original:**
```bash
psql << 'EOF'
SELECT
  (SELECT COUNT(*) FROM runmap.runs_raw) as total_runs,
  (SELECT COUNT(*) FROM runmap.runs_buffered_32610) as buffered_runs,
  (SELECT COUNT(*) FROM runmap.street_coverage_32610 WHERE covered_length_m > 0) as streets_with_coverage;
EOF
```

**Updated:**
```bash
psql << 'EOF'
SELECT
  (SELECT COUNT(*) FROM runmap.runs_raw) as total_runs,
  (SELECT COUNT(*) FROM runmap.runs_buffered_subdiv) as buffered_runs,
  (SELECT COUNT(*) FROM runmap.block_segments) as total_segments,
  (SELECT COUNT(*) FROM runmap.block_segment_visited WHERE visited = true) as visited_segments;
EOF
```

**Section: "Coverage Calculation Issues" (lines 275-292)**

Remove references to `street_coverage_32610` and `block_coverage_32610`. Replace with:

```bash
# Check block coverage distribution
psql << 'EOF'
SELECT
  CASE
    WHEN coverage_pct < 5 THEN 'Unrun (0-5%)'
    WHEN coverage_pct < 90 THEN 'Partial (5-90%)'
    ELSE 'Complete (90%+)'
  END as status,
  COUNT(*) as blocks,
  ROUND(AVG(coverage_pct)::numeric, 1) as avg_coverage_pct
FROM runmap.block_coverage_segments
GROUP BY
  CASE
    WHEN coverage_pct < 5 THEN 'Unrun (0-5%)'
    WHEN coverage_pct < 90 THEN 'Partial (5-90%)'
    ELSE 'Complete (90%+)'
  END
ORDER BY avg_coverage_pct;
EOF
```

#### B. `PRE_BULK_IMPORT_CHECKLIST.md`

Update all references to:
- `runs_buffered_32610` → `runs_buffered_subdiv`
- `block_coverage_32610` → `block_coverage_segments`

#### C. Add to `docs/archive/`

Move obsolete documentation that still references old tables:
- `docs/archive/INCREMENTAL_MIGRATION.md` (already there)
- `db/03_incremental_coverage.sql` → `db/archive/`
- `db/03_incremental_coverage_fixed.sql` → `db/archive/`
- `db/09_block_percentage_coverage.sql` → `db/archive/` (superseded by segment-visited)

### 6. Post-Migration Verification

```bash
# Verify obsolete tables are gone
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT tablename
FROM pg_tables
WHERE schemaname = 'runmap'
  AND tablename IN ('street_coverage_32610', 'block_coverage_32610', 'block_run_coverage', 'runs_buffered_32610');
EOF
```

**Expected output:** 0 rows (all tables dropped)

```bash
# Verify active system still works
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT * FROM runmap.coverage_stats_blocks;
EOF
```

**Expected output:** Valid coverage statistics

```bash
# Test upload a run
curl -X POST https://runmap.chouinard.me/api/upload -F "file=@test_run.gpx"
```

**Expected output:** Success message with segment count

## Rollback Plan

If something goes wrong:

```bash
# Restore from backup
psql -h 192.168.68.25 -U runmap_user -d runmap < backup_obsolete_tables_YYYYMMDD.sql

# Or restore full database
psql -h 192.168.68.25 -U runmap_user -d runmap < backup_runmap_before_cleanup_YYYYMMDD_HHMMSS.sql
```

## Benefits

1. **Clearer codebase** - No confusion about which tables are active
2. **Easier maintenance** - Fewer tables to manage
3. **Better documentation** - References point to current system only
4. **Space savings** - ~424 KB reclaimed
5. **Migration readiness** - Clean state for future changes

## Risks

**Risk Level: LOW**

- Obsolete tables have no foreign key dependencies (nothing points to them)
- Current system is fully independent
- Scripts that reference old tables will fail gracefully (table doesn't exist)
- Easy rollback via backup

## Timeline

**Total time:** ~30 minutes

1. Backup: 2-3 minutes
2. Run migration: 1 minute
3. Update scripts: 10 minutes
4. Update documentation: 10 minutes
5. Testing: 5 minutes
6. Deploy updated scripts: 2 minutes

## Checklist

- [ ] Run pre-migration verification queries
- [ ] Create database backup
- [ ] Execute `db/12_cleanup_obsolete_tables.sql`
- [ ] Update `scripts/bulk_import.sh`
- [ ] Update `scripts/process_all_runs.sh`
- [ ] Update `scripts/reset_coverage.sh`
- [ ] Update `scripts/delete_recent_20_runs.sh`
- [ ] Update `CLAUDE.md` diagnostic queries
- [ ] Update `PRE_BULK_IMPORT_CHECKLIST.md`
- [ ] Move obsolete SQL files to `db/archive/`
- [ ] Run post-migration verification
- [ ] Test run upload
- [ ] Deploy updated scripts to server
- [ ] Update `docs/TODO_AOI_EXPANSION.md` (references old tables)

## Questions?

- **Q: What if a script breaks after cleanup?**
  - A: Just update the table name in the script. All functionality is preserved in the new tables.

- **Q: Will this affect the live map?**
  - A: No. The map uses views (`streets_unrun`, `streets_partial`, `streets_complete`) which are based on active tables.

- **Q: Can I delay the script updates?**
  - A: Yes, but scripts will fail when they try to query dropped tables. Best to update immediately after migration.

- **Q: What about the TODO_AOI_EXPANSION.md plan?**
  - A: Will update it to reference current tables only. The process remains the same.
