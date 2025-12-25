# Database Cleanup Guide

**Date:** 2025-11-18
**Purpose:** Remove obsolete database objects from old coverage systems
**Status:** Ready to execute (after backup)

---

## Overview

Your production database contains objects from **3 different coverage systems**:

1. ✅ **Segment-visited** (CURRENT) - migrated 2025-10-20
2. ❌ **Block-percentage** (never fully deployed) - obsolete functions exist
3. ❌ **Chunk-based** (very old) - may have remnant objects

The cleanup script removes all obsolete objects while preserving the current segment-visited system.

---

## What Will Be Removed

### 🔴 Obsolete Functions

| Function | System | Reason |
|----------|--------|--------|
| `apply_run_to_chunk_coverage()` | Chunk-based | Very old system |
| `apply_run_to_coverage()` | Early incremental | Replaced by segment system |
| `apply_run_to_block_coverage()` | Block-percentage | Never deployed |
| `buffer_one_run()` | Old buffer | Replaced by `buffer_one_run_subdiv()` |
| `auto_process_new_run()` | Block-percentage | Wrong trigger function |
| `rebuild_block_coverage()` | Block-percentage | Unused |
| `rebuild_chunk_coverage()` | Chunk-based | Very old |

### 🔴 Obsolete Views

| View | System | Reason |
|------|--------|--------|
| `chunks_incomplete` | Chunk-based | Very old |
| `chunks_complete` | Chunk-based | Very old |
| `streets_most_complete` | Old utility | May be unused |
| `streets_least_complete` | Old utility | May be unused |

**Note:** `streets_unrun`, `streets_partial`, and `streets_complete` are NOT obsolete! They are part of the current segment-visited system and query `block_coverage_segments`.

### 🔴 Obsolete Materialized Views

| View | System | Reason |
|------|--------|--------|
| `coverage_stats` | Street-level | Replaced by `coverage_stats_blocks` |
| `coverage_stats_chunks` | Chunk-based | Very old |

### 🔴 Obsolete Tables (if they exist)

| Table | System | Reason |
|-------|--------|--------|
| `streets_chunks_32610` | Chunk-based | Very old |
| `chunk_coverage_32610` | Chunk-based | Very old |
| `block_coverage_32610` | Block-percentage | Never deployed (good!) |
| `block_run_coverage` | Block-percentage | Never deployed (good!) |
| `runs_buffered_32610` | Old buffer | Replaced by `runs_buffered_subdiv` |
| `street_coverage_32610` | Street-level | Very old |

### 🔴 Obsolete Triggers

| Trigger | Reason |
|---------|--------|
| `trigger_auto_process_run` | Wrong name, replaced by `trigger_auto_process_run_segments` |

**Note:** `trigger_set_location_before_insert` is NOT obsolete - it's part of the current system (created by 04_segment_schema.sql).

---

## What Will Be KEPT (Current Production)

### ✅ Tables (Segment-Visited System)

- `runs_raw`, `walks_raw`, `cycling_raw` - Activity tracks
- `streets_reference`, `streets_reference_32610` - OSM baseline
- `streets_blocks_32610` - Block segmentation
- **`runs_buffered_subdiv`** - Subdivided buffers (current)
- **`block_segments`** - Pre-segmented 5m pieces (current)
- **`block_segment_visited`** - Binary visited flags (current)
- **`block_coverage_segments`** - Aggregate coverage (current)
- `performance_log`, `processing_errors` - Logging
- `settings`, `aoi` - Configuration

### ✅ Functions (Segment-Visited System)

- **`buffer_one_run_subdiv(uuid)`** - Buffer + subdivide
- **`apply_run_to_segments(uuid)`** - Mark segments visited
- **`auto_process_new_run_segments()`** - Trigger function
- `detect_location(geometry)` - Location detection
- `get_buffer_distance()` - Get buffer setting

### ✅ Views (Segment-Visited System)

- **`streets_unrun`** - <5% coverage (grey on map)
- **`streets_partial`** - 5-75% coverage (purple on map)
- **`streets_complete`** - ≥75% coverage (green on map)
- Utility views: `activity_stats`, `all_activities`, `blocks_per_street`, `blocks_stats`, `failed_runs`

### ✅ Materialized Views

- **`coverage_stats_blocks`** - Overall statistics

### ✅ Triggers

- **`trigger_auto_process_run_segments`** - Auto-process new runs
- **`trigger_set_location_before_insert`** - Auto-detect location
- **`trigger_cleanup_coverage_on_delete`** - Recalculate coverage on delete

---

## Safety Checklist

**BEFORE running the cleanup:**

1. ✅ **Backup database:**
   ```bash
   pg_dump -U runmap_user -h 192.168.68.25 runmap > backup_before_cleanup_$(date +%Y%m%d).sql
   ```

2. ✅ **Verify segment-visited system is active:**
   ```bash
   psql -U runmap_user -h 192.168.68.25 -d runmap -c "SELECT COUNT(*) FROM runmap.block_segments;"
   # Should return ~50,000+ segments
   ```

3. ✅ **Check current triggers:**
   ```bash
   psql -U runmap_user -h 192.168.68.25 -d runmap -c "SELECT tgname FROM pg_trigger WHERE tgrelid = 'runmap.runs_raw'::regclass AND tgname LIKE 'trigger_%';"
   # Should show:
   #   trigger_auto_process_run_segments
   #   trigger_set_location_before_insert
   #   trigger_cleanup_coverage_on_delete
   ```

4. ✅ **Test on a copy first** (optional but recommended):
   ```bash
   createdb -U runmap_user runmap_test
   pg_restore -U runmap_user -d runmap_test backup.sql
   psql -U runmap_user -d runmap_test -f db/cleanup_obsolete_objects.sql
   ```

---

## Running the Cleanup

### Option 1: Interactive Review (Recommended)

```bash
# Run with transaction safety - will rollback if you cancel
psql -U runmap_user -h 192.168.68.25 -d runmap << 'EOF'
BEGIN;
\i db/cleanup_obsolete_objects.sql
-- Review the output, then either:
-- COMMIT;   -- to keep changes
-- ROLLBACK; -- to cancel
EOF
```

### Option 2: Direct Execution

```bash
PGPASSWORD=fucker psql -U runmap_user -h 192.168.68.25 -d runmap -f db/cleanup_obsolete_objects.sql
```

### Option 3: From Server

```bash
ssh -p 8023 mark@192.168.68.25
cd /home/mark/runmap
psql -U runmap_user -d runmap -f db/cleanup_obsolete_objects.sql
```

---

## Expected Output

The script will:

1. Drop obsolete functions (if they exist)
2. Drop obsolete views
3. Drop obsolete materialized views
4. Drop obsolete tables (if they exist)
5. Drop obsolete triggers (if they exist)
6. Show verification queries listing remaining objects

**Expected result:** Only segment-visited system objects remain.

---

## Verification After Cleanup

Run these queries to confirm cleanup:

```sql
-- Should only show segment-visited functions
SELECT proname, pg_get_function_identity_arguments(oid)
FROM pg_proc
WHERE pronamespace = 'runmap'::regnamespace
  AND (proname LIKE '%buffer%' OR proname LIKE '%apply%' OR proname LIKE '%process%')
ORDER BY proname;

-- Expected functions:
--   apply_run_to_segments(uuid)
--   auto_process_new_run_segments()
--   buffer_one_run_subdiv(uuid)

-- Should show coverage views + utility views
SELECT viewname FROM pg_views WHERE schemaname = 'runmap';

-- Expected views:
--   streets_unrun (<5% coverage)
--   streets_partial (5-75% coverage)
--   streets_complete (>=75% coverage)
--   activity_stats, all_activities, blocks_per_street, blocks_stats, failed_runs

-- Should only show one matview
SELECT matviewname FROM pg_matviews WHERE schemaname = 'runmap';

-- Expected:
--   coverage_stats_blocks
```

---

## Rollback Plan

If something goes wrong:

1. **If you used BEGIN/COMMIT:**
   ```sql
   ROLLBACK;  -- Cancels all changes
   ```

2. **If cleanup completed:**
   ```bash
   # Restore from backup
   dropdb runmap
   createdb runmap
   pg_restore -d runmap backup_before_cleanup_YYYYMMDD.sql
   ```

3. **If specific function needed:**
   - Check `db/03_incremental_coverage.sql` or other schema files
   - Extract and re-run the CREATE FUNCTION statement

---

## Disk Space Savings

Estimated savings: **Minimal** (functions/views don't use much space)

The main benefit is **clarity** - removing confusing obsolete objects that don't match documentation.

---

## Post-Cleanup Actions

After successful cleanup:

1. ✅ Update `db/README.md` obsolete files list (if needed)
2. ✅ Commit the cleanup script to git
3. ✅ Document the cleanup in project notes

---

## Troubleshooting

### "ERROR: cannot drop ... because other objects depend on it"

The script uses `CASCADE`, so this shouldn't happen. If it does:
- Note which object
- Check what depends on it: `\d+ object_name`
- May indicate an object is still in use

### "ERROR: relation ... does not exist"

This is fine! It means the obsolete object was already cleaned up.

### "Still seeing old functions in \df"

Check the schema: `\df runmap.*` vs `\df public.*`
- Old functions might be in `public` schema instead of `runmap`

---

## Questions?

**Q: Can I run this multiple times?**
A: Yes, the script uses `IF EXISTS`, so it's safe to re-run.

**Q: Will this affect my data?**
A: No, only functions/views/triggers are dropped. Tables with data (`runs_raw`, etc.) are preserved.

**Q: What if I need an old function back?**
A: Check the schema files in `db/` - old definitions are preserved there.

**Q: Should I clean up the obsolete `.sql` files too?**
A: Yes, but keep them in git for historical reference. See `db/README.md` for the list.

---

## Related Documentation

- [SEGMENT_VISITED_MIGRATION.md](../docs/SEGMENT_VISITED_MIGRATION.md) - Current system
- [db/README.md](README.md) - Obsolete files list
- [CLAUDE.md](../CLAUDE.md) - Current schema reference
