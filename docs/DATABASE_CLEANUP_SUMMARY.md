# Database Cleanup Summary

**Date:** 2025-10-20
**Status:** ✅ Ready to Execute

## What We Did

Created a comprehensive plan to remove obsolete database tables from previous system iterations and updated all references to use current tables.

## Files Created

### 1. Migration Script
**File:** `db/12_cleanup_obsolete_tables.sql`
- Includes safety checks (verifies current system has data)
- Drops 4 obsolete tables
- Provides verification queries
- Shows before/after statistics

### 2. Documentation
**File:** `docs/DATABASE_CLEANUP_PLAN.md`
- Complete step-by-step migration guide
- Pre/post verification queries
- Detailed script update instructions
- Rollback plan
- Risk assessment (LOW risk)

**File:** `docs/DATABASE_CLEANUP_SUMMARY.md` (this file)
- Overview of changes made

## Files Updated

### Scripts
1. **`scripts/bulk_import.sh`**
   - Changed: `runs_buffered_32610` → `runs_buffered_subdiv`
   - Changed: `buffer_one_run()` → `buffer_one_run_subdiv()`
   - Changed: `apply_run_to_block_coverage()` → `apply_run_to_segments()`
   - Changed: Diagnostic queries to use segment-visited tables

2. **`scripts/process_all_runs.sh`**
   - Same changes as bulk_import.sh
   - Updated all buffer/coverage function calls
   - Updated statistics reporting

3. **`scripts/reset_coverage.sh`**
   - Changed: `runs_buffered_32610` → `runs_buffered_subdiv`
   - Changed: `block_coverage_32610` → `block_coverage_segments`
   - Added: Visited segments count

4. **`scripts/delete_recent_20_runs.sh`**
   - Changed: `runs_buffered_32610` → `runs_buffered_subdiv`

### Documentation
1. **`CLAUDE.md`**
   - Updated Performance Monitoring section
   - Changed: `coverage_stats` → `coverage_stats_blocks`
   - Updated verification queries to use current tables

2. **`docs/TODO_AOI_EXPANSION.md`**
   - Updated cascade delete comments
   - Changed: `block_coverage_32610` → `block_coverage_segments`

## Tables Being Removed

| Table | Reason | Size Reclaimed |
|-------|--------|----------------|
| `street_coverage_32610` | Pre-block-splitting system | 24 KB |
| `block_coverage_32610` | Old geometry-union approach | 104 KB |
| `block_run_coverage` | Intermediate junction table | 88 KB |
| `runs_buffered_32610` | Old single-buffer approach | 208 KB |

**Total space reclaimed:** ~424 KB

## Current Active Tables (Unchanged)

| Table | Size | Purpose |
|-------|------|---------|
| `streets_reference` | 1 MB | Original OSM data (WGS84) |
| `streets_reference_32610` | 1 MB | UTM-projected streets |
| `streets_blocks_32610` | 744 KB | Streets split at intersections |
| `block_segments` | 8.6 MB | 5m subdivisions of blocks |
| `block_segment_visited` | 8 MB | Boolean visited flags |
| `block_coverage_segments` | 456 KB | Precomputed coverage % |
| `runs_buffered_subdiv` | 10 MB | Subdivided run buffers |
| `runs_raw` | 17 MB | All GPS tracks |

## System Evolution Context

The system evolved through several approaches:

1. **Street-level geometry unions** (2024)
   - Tables: `street_coverage_32610`
   - Problem: Not granular enough

2. **Block-level with single buffers** (Early 2025)
   - Tables: `runs_buffered_32610`, `block_coverage_32610`
   - Problem: Expensive ST_Union operations

3. **Junction table approach** (Mid 2025)
   - Table: `block_run_coverage`
   - Problem: Still required geometry unions

4. **Segment-visited with subdivided buffers** (Oct 2025) ✅ **CURRENT**
   - Tables: `runs_buffered_subdiv`, `block_segments`, `block_segment_visited`, `block_coverage_segments`
   - Result: 67x speedup, constant-time performance

## Next Steps

To execute the cleanup:

### 1. Review the Plan
```bash
cat docs/DATABASE_CLEANUP_PLAN.md
```

### 2. Backup Database
```bash
pg_dump -h 192.168.68.25 -U runmap_user -d runmap \
  > backup_runmap_before_cleanup_$(date +%Y%m%d_%H%M%S).sql
```

### 3. Run Migration
```bash
PGPASSWORD=fucker psql -h 192.168.68.25 -U runmap_user -d runmap \
  -f db/12_cleanup_obsolete_tables.sql
```

### 4. Deploy Updated Scripts
```bash
bash scripts/deploy.sh
```

### 5. Test
```bash
# Upload a test run
curl -X POST https://runmap.chouinard.me/api/upload -F "file=@test_run.gpx"

# Verify coverage updated
psql -h 192.168.68.25 -U runmap_user -d runmap \
  -c "SELECT * FROM runmap.coverage_stats_blocks;"
```

## Benefits

1. ✅ **Clearer codebase** - No confusion about which tables are active
2. ✅ **Easier maintenance** - Fewer tables to manage
3. ✅ **Better documentation** - All references point to current system
4. ✅ **Space savings** - ~424 KB reclaimed
5. ✅ **Migration readiness** - Clean state for AOI expansion

## Risk Assessment

**Risk Level: LOW**

- ✅ Obsolete tables have no foreign key dependencies
- ✅ Current system is fully independent
- ✅ Easy rollback via backup
- ✅ Scripts fail gracefully (table doesn't exist error is clear)

## Questions?

- **Q: Will this affect the live map?**
  - A: No. The map uses views based on active tables only.

- **Q: What if I need to rollback?**
  - A: Restore from backup. All data is preserved in the backup file.

- **Q: Can I run this on production?**
  - A: Yes, but backup first. The migration includes safety checks.

## References

- [DATABASE_CLEANUP_PLAN.md](DATABASE_CLEANUP_PLAN.md) - Full migration guide
- [SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md) - Why we switched to segment-visited
- [db/12_cleanup_obsolete_tables.sql](../db/12_cleanup_obsolete_tables.sql) - Migration script
