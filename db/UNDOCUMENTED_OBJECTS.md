# Undocumented Database Objects

**Date:** 2025-11-18
**Source:** Production database audit (scripts/audit_production_database.sh)
**Status:** Needs review and documentation

---

## Summary

The audit revealed **18 undocumented functions** and **8 utility views** in production that are not mentioned in primary documentation (CLAUDE.md, db/README.md).

These objects fall into three categories:
1. **Obsolete functions** (10) - Should be removed
2. **Utility functions** (8) - Should be documented or evaluated
3. **Utility views** (5+3) - Some documented in sql/runmap.sql, need to add to main docs

---

## Undocumented Functions (18 total)

### 🔴 Obsolete Functions to Remove (10)

These are from old coverage systems and should be dropped:

| Function | System | Reason | Action |
|----------|--------|--------|--------|
| `apply_run_to_block_coverage` | Block-percentage | Never deployed | DROP |
| `apply_run_to_chunk_coverage` | Chunk-based | Very old system | DROP |
| `apply_run_to_coverage` | Early incremental | Replaced by segments | DROP |
| `auto_process_new_run` | Block-percentage | Wrong trigger function | DROP |
| `buffer_one_run` | Old buffer | Replaced by subdiv version | DROP |
| `rebuild_block_coverage` | Block-percentage | Unused rebuild function | DROP |
| `rebuild_chunk_coverage` | Chunk-based | Very old rebuild | DROP |
| `set_location_on_insert` | Old trigger | Replaced by detect_location | DROP |
| *(2 more to identify from audit)* | | | |

**Status:** Need to update cleanup script to include these

---

### ⚠️ Utility Functions - Need Documentation (8)

These appear to be used for RouteGen integration or other utilities. Need to determine if they're still needed:

| Function | Likely Purpose | Questions |
|----------|----------------|-----------|
| `calculate_route_efficiency` | Route planning optimization | Is RouteGen still used? |
| `get_coverage_areas` | Query coverage data | Is this API-facing? |
| `find_unvisited_blocks` | Identify gaps in coverage | Still needed? |
| `get_adjacent_blocks` | Graph traversal for routes | Part of RouteGen? |
| `calculate_block_priority` | Prioritize which blocks to run | Active feature? |
| `get_route_suggestions` | Suggest efficient routes | User-facing? |
| `validate_gpx_track` | GPX validation | Used by upload API? |
| `get_completion_threshold` | Query threshold setting | Should document |

**Actions needed:**
1. Ask user: "Are you using RouteGen for route planning?"
2. Ask user: "Which of these utility functions are actively used?"
3. Document active functions in CLAUDE.md
4. Add unused functions to cleanup script

---

## Undocumented Views (8 total)

### ✅ Current Utility Views - Need Documentation (5)

These exist in production and appear to be useful utilities:

| View | Purpose | Should Document? |
|------|---------|------------------|
| `activity_stats` | Overall activity statistics | Yes - useful for dashboards |
| `all_activities` | Union of runs/walks/cycling | Yes - query convenience |
| `blocks_per_street` | Block count per street name | Maybe - depends on use |
| `blocks_stats` | Block statistics summary | Yes - useful for analysis |
| `failed_runs` | Runs with processing errors | Yes - debugging tool |

**Action:** Add these to CLAUDE.md under "Utility Views" section

---

### 🔴 Old Views - Should Be Removed (3)

According to cleanup script, but NOT actually present in audit:

| View | Status | Notes |
|------|--------|-------|
| `chunks_incomplete` | ❓ Not found in audit | May already be removed |
| `chunks_complete` | ❓ Not found in audit | May already be removed |
| `streets_most_complete` | ❓ Not found in audit | May already be removed |
| `streets_least_complete` | ❓ Not found in audit | May already be removed |

**Note:** Audit may not have found these because they don't exist. Cleanup script is safe (uses IF EXISTS).

---

## Findings Already Fixed ✅

1. **Fixed:** CLAUDE.md incorrectly documented `blocks_incomplete` and `blocks_complete` (don't exist)
   - Corrected to: `streets_unrun`, `streets_partial`, `streets_complete`

2. **Fixed:** CLAUDE.md used wrong thresholds (90% instead of 75%)
   - Corrected to: <5% unrun, 5-75% partial, ≥75% complete

3. **Fixed:** Cleanup script would have incorrectly dropped current views
   - Removed: DROP statements for streets_unrun, streets_partial, streets_complete

4. **Fixed:** CLEANUP_GUIDE.md listed current views as obsolete
   - Updated: Marked streets_* views as current, not obsolete

---

## Recommended Next Steps

### Priority 1: Clarify Function Usage

Ask user to identify which functions are actively used:

```sql
-- Query production to see if functions are referenced in triggers or other functions
SELECT
  p.proname as function_name,
  pg_get_functiondef(p.oid) as definition
FROM pg_proc p
WHERE p.pronamespace = 'runmap'::regnamespace
  AND p.proname IN (
    'calculate_route_efficiency',
    'get_coverage_areas',
    'find_unvisited_blocks',
    'get_adjacent_blocks',
    'calculate_block_priority',
    'get_route_suggestions',
    'validate_gpx_track',
    'get_completion_threshold'
  );
```

Questions for user:
- "Do you use RouteGen for route planning?"
- "Are any of these utility functions called by the API?"
- "Which functions can be safely removed?"

### Priority 2: Document Active Utilities

Add to CLAUDE.md:

```markdown
### Utility Views

`runmap.activity_stats` - Overall statistics across all activity types
`runmap.all_activities` - Union view of runs, walks, and cycling
`runmap.blocks_stats` - Summary statistics for block segmentation
`runmap.failed_runs` - Runs that failed processing (debugging)

### Utility Functions

`runmap.get_completion_threshold()` - Returns current completion threshold from settings
[Add others based on user feedback]
```

### Priority 3: Update Cleanup Script

Add obsolete functions found in audit:

```sql
-- Add to db/cleanup_obsolete_objects.sql
DROP FUNCTION IF EXISTS runmap.apply_run_to_block_coverage(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.apply_run_to_chunk_coverage(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.apply_run_to_coverage(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.auto_process_new_run() CASCADE;
DROP FUNCTION IF EXISTS runmap.buffer_one_run(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.rebuild_block_coverage() CASCADE;
DROP FUNCTION IF EXISTS runmap.rebuild_chunk_coverage() CASCADE;
DROP FUNCTION IF EXISTS runmap.set_location_on_insert() CASCADE;
```

### Priority 4: Export Manual Objects to Schema Files

Currently, some objects exist only in production (not in git-tracked schema files):

**Missing from schema files:**
- `trigger_cleanup_coverage_on_delete` + `cleanup_coverage_on_delete()` function
- Utility views: activity_stats, all_activities, blocks_stats, failed_runs, blocks_per_street
- Utility functions (if actively used)

**Recommendation:** Create schema files:
- `db/05_utility_views.sql` - For utility views
- `db/06_cleanup_trigger.sql` - For cleanup trigger (export from production)
- `db/07_utility_functions.sql` - For any utility functions to keep

---

## Questions for User

Before continuing documentation work:

1. **RouteGen Functions:**
   - Are you using route planning features?
   - Which of the 8 utility functions are actually needed?

2. **Utility Views:**
   - Are all 5 utility views useful? (activity_stats, all_activities, blocks_stats, failed_runs, blocks_per_street)
   - Should I create schema files for them?

3. **Cleanup:**
   - Should I run the cleanup script to remove obsolete functions?
   - Should I export current triggers/functions to schema files first?

---

## Related Files

- [scripts/audit_production_database.sh](../scripts/audit_production_database.sh) - Audit script that found these
- [db/AUDIT_FINDINGS.md](AUDIT_FINDINGS.md) - Initial audit notes
- [db/cleanup_obsolete_objects.sql](cleanup_obsolete_objects.sql) - Cleanup script (needs updating)
- [CLAUDE.md](../CLAUDE.md) - Main documentation (partially fixed)
- [sql/runmap.sql](../sql/runmap.sql) - Full schema dump showing actual production state
