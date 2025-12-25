# Function Audit Results

**Date:** 2025-11-18
**Source:** Production schema dump (sql/runmap.sql)

---

## Summary

Production database contains **25 functions** in the runmap schema:
- **7 documented** - Current segment-visited system
- **10 obsolete** - From old coverage systems, should be removed
- **3 RouteGen** - Route planning integration (user reports not working correctly)
- **4 utility** - Administrative/setup functions
- **1 duplicate** - apply_run_to_chunk_coverage appears twice in schema dump

---

## ✅ Current/Documented Functions (7)

These are part of the active segment-visited coverage system and are documented in CLAUDE.md:

| Function | Purpose | Used By |
|----------|---------|---------|
| `apply_run_to_segments(uuid)` | Marks 5m segments as visited | Auto-process trigger |
| `auto_process_new_run_segments()` | Trigger function for new runs | trigger_auto_process_run_segments |
| `buffer_one_run_subdiv(uuid)` | Creates subdivided 10m buffer | apply_run_to_segments |
| `cleanup_coverage_on_delete()` | Recalculates coverage on deletion | trigger_cleanup_coverage_on_delete |
| `detect_location(geometry)` | Detects sacramento/portland/other | set_location_on_insert trigger |
| `get_buffer_distance()` | Returns buffer_distance_m setting | buffer_one_run_subdiv |
| `get_completion_threshold()` | Returns completion_threshold_pct | streets_partial, streets_complete views |

---

## 🔴 Obsolete Functions (10) - Should Remove

### From Block-Percentage System (never fully deployed):
| Function | Reason | Safe to Delete? |
|----------|--------|-----------------|
| `apply_run_to_block_coverage(uuid)` | Wrong coverage algorithm | ✅ Yes |
| `auto_process_new_run()` | Wrong trigger function | ✅ Yes |
| `rebuild_block_coverage()` | Unused rebuild function | ✅ Yes |

### From Chunk-Based System (very old):
| Function | Reason | Safe to Delete? |
|----------|--------|-----------------|
| `apply_run_to_chunk_coverage(uuid)` | Very old system | ✅ Yes |
| `rebuild_chunk_coverage()` | Very old system | ✅ Yes |
| `subdivide_blocks_to_chunks(float8)` | Chunk subdivision | ✅ Yes |

### From Old Incremental System:
| Function | Reason | Safe to Delete? |
|----------|--------|-----------------|
| `apply_run_to_coverage(uuid)` | Replaced by segments | ✅ Yes |
| `buffer_one_run(uuid)` | Replaced by subdiv version | ✅ Yes |

### References Obsolete Tables:
| Function | Reason | Safe to Delete? |
|----------|--------|-----------------|
| `reset_coverage_processing()` | References obsolete tables:<br>- runs_buffered_32610<br>- block_coverage_32610<br>- block_run_coverage | ✅ Yes (after verifying tables don't exist) |

### Replaced Trigger Function:
| Function | Reason | Safe to Delete? |
|----------|--------|-----------------|
| `set_location_on_insert()` | Old trigger function, replaced by<br>`set_location_before_insert()` which calls `detect_location()` | ⚠️  Check trigger first |

**Note:** User confirmed we have database backups, so cleanup is safe.

---

## 🛣️ RouteGen Functions (3) - Route Planning Integration

User reports: "RouteGen is a separate project running on the server, but it's not working correctly."

| Function | Purpose | Keep? |
|----------|---------|-------|
| `calculate_route_efficiency(geometry, text, numeric)` | Calculates efficiency of a proposed route | ✅ Keep - RouteGen depends on it |
| `get_coverage_areas(text, text)` | Returns coverage areas by type<br>(complete/partial/unrun) and location | ✅ Keep - RouteGen depends on it |
| `get_all_coverage_areas(text)` | Wrapper that returns all coverage types<br>for a location (calls get_coverage_areas) | ✅ Keep - RouteGen depends on it |

**Recommendation:** Keep these functions since RouteGen is actively used (even if not working perfectly). Document them in CLAUDE.md under "RouteGen Integration Functions".

---

## 🔧 Utility/Administrative Functions (4)

| Function | Purpose | Keep? | Document? |
|----------|---------|-------|-----------|
| `get_buffer_config()` | Returns per-highway-type buffer distances<br>(advanced feature not currently used) | ⚠️  Maybe | Only if used |
| `retry_run_processing(uuid)` | Retry processing for failed runs<br>(sets status to 'processing' and reruns) | ✅ Yes | Yes - useful utility |
| `set_buffer_distance(text, float8)` | Set per-highway-type buffer distances<br>(for future variable buffer feature) | ⚠️  Maybe | Only if used |
| `split_streets_at_intersections()` | **One-time setup function**<br>Creates blocks from streets by splitting at intersections | ✅ Yes | Yes - critical for setup |

**Recommendations:**
1. **Keep and document:** `retry_run_processing`, `split_streets_at_intersections`
2. **Evaluate:** `get_buffer_config`, `set_buffer_distance` - These support per-highway-type buffers (e.g., 15m for highways, 10m for residential). Ask user: "Do you plan to use variable buffer distances by street type?"

---

## Action Items

### 1. Update Cleanup Script

Add these 10 obsolete functions to `db/cleanup_obsolete_objects.sql`:

```sql
-- Obsolete functions from old coverage systems
DROP FUNCTION IF EXISTS runmap.apply_run_to_block_coverage(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.apply_run_to_chunk_coverage(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.apply_run_to_coverage(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.auto_process_new_run() CASCADE;
DROP FUNCTION IF EXISTS runmap.buffer_one_run(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.rebuild_block_coverage() CASCADE;
DROP FUNCTION IF EXISTS runmap.rebuild_chunk_coverage() CASCADE;
DROP FUNCTION IF EXISTS runmap.subdivide_blocks_to_chunks(float8) CASCADE;
DROP FUNCTION IF EXISTS runmap.reset_coverage_processing() CASCADE;
DROP FUNCTION IF EXISTS runmap.set_location_on_insert() CASCADE;
```

### 2. Document RouteGen Functions

Add to CLAUDE.md:

```markdown
### RouteGen Integration Functions

`runmap.calculate_route_efficiency(route_geom, location, buffer_m)` - Calculate efficiency of proposed route
`runmap.get_coverage_areas(location, coverage_type)` - Get areas by coverage type (complete/partial/unrun)
`runmap.get_all_coverage_areas(location)` - Get all coverage areas for a location
```

### 3. Document Utility Functions

Add to CLAUDE.md:

```markdown
### Utility/Administrative Functions

`runmap.retry_run_processing(run_id)` - Retry processing for a failed run
`runmap.split_streets_at_intersections()` - One-time setup: split streets into blocks at intersections
```

### 4. Questions for User

1. **Variable buffer distances:** Do you plan to use different buffer distances for different street types (e.g., 15m for highways, 10m for residential)? If yes, keep `get_buffer_config()` and `set_buffer_distance()`. If no, they can be removed.

2. **RouteGen status:** Since RouteGen isn't working correctly, do you want help debugging it? The functions are there and look correct.

---

## Verification Queries

Before cleanup, verify these objects don't exist (reset_coverage_processing references them):

```sql
-- Check for obsolete tables
SELECT tablename FROM pg_tables
WHERE schemaname = 'runmap'
  AND tablename IN ('runs_buffered_32610', 'block_coverage_32610', 'block_run_coverage');
-- Should return 0 rows

-- Check which trigger uses set_location_on_insert
SELECT tgname, tgrelid::regclass
FROM pg_trigger
WHERE tgname LIKE '%location%';
```

---

## Current Function Count by Category

```
Total Functions: 25

✅ Current (documented): 7
🔴 Obsolete (to remove): 10
🛣️  RouteGen (keep): 3
🔧 Utility (keep 2, evaluate 2): 4
📝 Duplicate entry: 1 (apply_run_to_chunk_coverage listed twice)
```

After cleanup: **15 functions** (7 current + 3 RouteGen + 2 utility + maybe 2 buffer config)
