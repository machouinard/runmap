# Testing Workflow: Fast Iteration on Coverage Algorithms

**Purpose:** Separate GPX import (slow) from coverage processing (fast) to enable rapid testing cycles.

**Created:** 2025-10-20
**Related:** [PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)

## Problem

When testing coverage algorithm changes, the full workflow takes 30-45 minutes:
1. Import 628 GPX files: ~10-15 minutes (parsing GPX, calculating metadata)
2. Process coverage: ~20-30 minutes (buffering + coverage calculation)

This makes testing iterations slow since GPX import doesn't change between tests.

## Solution

Three-script workflow that separates import from processing:

### 1. One-Time Import (10-15 minutes)

Import all GPX files without processing coverage:

```bash
./scripts/bulk_import_no_process.sh /path/to/gpx/directory
```

**What it does:**
- Parses all GPX files
- Inserts into `runs_raw`, `walks_raw`, `cycling_raw`
- Calculates metadata (distance, pace, moving time)
- Detects location (sacramento/portland/other)
- Disables auto-process trigger for speed
- **Skips** buffering and coverage calculation

**Output:**
```
Found 628 GPX files

✓ SUCCESS: route_2024-06-12_9.48am.gpx (run)
✓ SUCCESS: route_2024-06-13_10.15am.gpx (walk)
...

✓ Imported: 628 total
  - Runs: 605
  - Walks: 20
  - Cycling: 3
⚠️  Duplicates: 0
✗ Errors: 0

Next Steps:
  To process coverage for all imported runs:
    ./scripts/process_all_runs.sh
```

### 2. Process Coverage (20-30 minutes per test)

Process all unprocessed Sacramento runs:

```bash
./scripts/process_all_runs.sh
```

**What it does:**
- Finds all Sacramento runs without buffers
- Buffers each run (10m radius)
- Applies coverage to blocks
- Shows diagnostic timing (same as `bulk_import.sh`)
- Refreshes coverage stats
- Exports tiles

**Output:**
```
Found 605 unprocessed Sacramento runs
This will take approximately 20 minutes...

Processed 10/605 runs (avg: 2s/run, est remaining: 19m)
⚠️  Run 16: 12s total (buffer:11s, coverage:1s)
    File: route_2024-06-12_9.48am.gpx
    Distance: 10500m, Points: 4981, Buffer pts: 2127, Blocks: 27
    Total coverage geometry points: 0
...

Processed 605/605 runs in 20m 15s total

Refreshing coverage statistics...
Exporting tiles...
✓ Processing complete!
```

### 3. Reset Processing (instant)

Clear coverage processing but keep imported runs:

```bash
source scripts/common/env.sh
psql -c "SELECT runmap.reset_coverage_processing();"
```

**What it does:**
- Truncates `runs_buffered_32610` (deletes all buffers)
- Truncates `block_coverage_32610` (deletes all coverage)
- Truncates `block_run_coverage` (deletes junction table)
- **Preserves** all data in `runs_raw`, `walks_raw`, `cycling_raw`

**Output:**
```
NOTICE:  Coverage processing reset complete. Run data preserved.
NOTICE:  Runs: 605 | Walks: 20 | Cycling: 3
 reset_coverage_processing
---------------------------

(1 row)
```

## Complete Testing Cycle

### Initial Setup (once)
```bash
# 1. Import all GPX files (10-15 min)
./scripts/bulk_import_no_process.sh ~/Downloads/apple_health_export/workout-routes

# 2. Process coverage (20-30 min)
./scripts/process_all_runs.sh
```

### Iterative Testing (per algorithm change)
```bash
# 1. Make changes to coverage algorithm
vim db/03_incremental_coverage.sql

# 2. Update function in database
source scripts/common/env.sh
psql -f db/03_incremental_coverage.sql

# 3. Reset processing (instant)
psql -c "SELECT runmap.reset_coverage_processing();"

# 4. Reprocess with new algorithm (20-30 min)
./scripts/process_all_runs.sh

# 5. Compare results, repeat as needed
```

## Time Savings

**Old workflow (full rebuild each test):**
- Import + Process: 30-45 minutes per test
- 5 iterations: ~2.5-4 hours

**New workflow (separate import/process):**
- Initial import: 10-15 minutes (once)
- Process per test: 20-30 minutes
- 5 iterations: 10-15 min + (5 × 20-30 min) = ~2-2.75 hours

**Savings: 30-75 minutes over multiple iterations**

## Scripts Reference

### `bulk_import_no_process.sh`
**Location:** `scripts/bulk_import_no_process.sh`
**Purpose:** Import GPX files without processing
**Time:** ~10-15 minutes for 628 files
**Output:** Populated `runs_raw`, `walks_raw`, `cycling_raw`

### `process_all_runs.sh`
**Location:** `scripts/process_all_runs.sh`
**Purpose:** Process coverage for all unprocessed runs
**Time:** ~20-30 minutes for 605 runs
**Output:** Populated `runs_buffered_32610`, `block_coverage_32610`, `block_run_coverage`, updated tiles

### `reset_coverage_processing()`
**Location:** Database function (created in `db/03_incremental_coverage.sql`)
**Purpose:** Clear processing results, keep imported data
**Time:** Instant
**Output:** Empty `runs_buffered_32610`, `block_coverage_32610`, `block_run_coverage`

## Database State

### After Import (no processing)
```
runs_raw:                628 rows ✓
walks_raw:               20 rows ✓
cycling_raw:             3 rows ✓
runs_buffered_32610:     0 rows (empty)
block_coverage_32610:    0 rows (empty)
block_run_coverage:      0 rows (empty)
```

### After Processing
```
runs_raw:                628 rows ✓
walks_raw:               20 rows ✓
cycling_raw:             3 rows ✓
runs_buffered_32610:     605 rows ✓ (Sacramento runs only)
block_coverage_32610:    ~1000 rows ✓ (blocks with coverage)
block_run_coverage:      ~15000 rows ✓ (run-block pairs)
```

### After Reset
```
runs_raw:                628 rows ✓ (preserved)
walks_raw:               20 rows ✓ (preserved)
cycling_raw:             3 rows ✓ (preserved)
runs_buffered_32610:     0 rows (cleared)
block_coverage_32610:    0 rows (cleared)
block_run_coverage:      0 rows (cleared)
```

## Use Cases

### 1. Testing Coverage Algorithm Changes
Modify `apply_run_to_block_coverage()` function, reset, reprocess.

### 2. Testing Different Buffer Distances
```bash
# Change buffer distance
psql -c "UPDATE runmap.settings SET value = '15'::jsonb WHERE key = 'buffer_distance_m';"

# Update buffer_one_run() to use new distance
# Then reset and reprocess
psql -c "SELECT runmap.reset_coverage_processing();"
./scripts/process_all_runs.sh
```

### 3. Testing Threshold Changes
Modify completion threshold in views, reset, reprocess to see new block classifications.

### 4. Performance Testing
Reset and reprocess multiple times to verify consistent performance (no slowdown over time).

## Common Issues

### "No unprocessed Sacramento runs found"
All runs already processed. Run `SELECT runmap.reset_coverage_processing();` first.

### "psql: error: connection to server on socket"
Need to source environment first:
```bash
source scripts/common/env.sh
psql -c "SELECT runmap.reset_coverage_processing();"
```

### Import shows duplicates
GPX files already imported. Either skip re-import or truncate `runs_raw` first:
```bash
source scripts/common/env.sh
psql << 'EOF'
TRUNCATE TABLE runmap.runs_raw CASCADE;
TRUNCATE TABLE runmap.walks_raw CASCADE;
TRUNCATE TABLE runmap.cycling_raw CASCADE;
EOF
./scripts/bulk_import_no_process.sh /path/to/gpx
```

## Related Documentation

- [PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md) - Why we separated import from processing
- [USAGE_GUIDE.md](USAGE_GUIDE.md) - Day-to-day operations for production use
- [BLOCK_PERCENTAGE_MIGRATION.md](BLOCK_PERCENTAGE_MIGRATION.md) - Block-based coverage architecture

## Future Improvements

### Potential Optimizations
1. **Parallel processing**: Process multiple runs concurrently (requires worker pool)
2. **Incremental export**: Only re-export changed blocks instead of all tiles
3. **Checkpoint/resume**: Save progress during processing to resume after interruption
4. **Batch processing**: Process runs in batches of 50 for progress visibility

### Metrics to Track
- Import time per GPX file (identify slow parsers)
- Buffer time vs. run complexity (points, distance)
- Coverage time vs. blocks affected
- Total geometry complexity growth (should stay at 0 with current architecture)
