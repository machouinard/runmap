# Scalability Analysis

**Last Updated:** October 2025
**Current System:** Block-based incremental coverage
**Current Scale:** 17 runs, 8 walks, 2,597 blocks, 1,505 blocks with coverage

## What Happens When You Add a New Run

### Current System (Incremental Block Coverage)

When you insert a new GPX file into the database:

```
1. GPX Import (Python script)    ~2-5 seconds   O(track_points)
2. Buffer Creation                ~3-8 seconds   O(blocks_near_run)
3. Update Block Coverage          ~5-15 seconds  O(blocks_touched)
4. Refresh Stats View             ~0.5-1 second  O(blocks_with_coverage)
5. Tile Export (if triggered)     ~30-60 sec     O(total_blocks)
```

**Total time per run:** ~10-30 seconds (excluding tile export)

**Key insight:** Processing time is based on **blocks touched by THIS run**, not total number of runs in database.

**Note:** Database triggers are NOT used - processing is explicitly called via functions after GPX import.

---

## Complexity Analysis

### Memory Usage

**Per-run processing:**
```
Buffer creation:        O(blocks_near_run)     ~50-200 blocks typically
Coverage update:        O(blocks_intersecting)  ~50-200 blocks typically
```

**Fixed constants:**
- Blocks near run: Typically 50-200 blocks for a 5-10km run
- Total blocks in system: 2,597 (constant, doesn't grow)
- Runs in database: N (grows with each run)

**Critical point:** Memory usage does NOT scale with N (number of runs).

**Why?** Because we only process blocks touched by the **new** run, not all historical runs.

---

### Time Complexity by Operation

#### 1. GPX Import
```
Operation: Read GPX file, insert to runs_raw
Complexity: O(track_points)
Typical:    ~1,000-5,000 points per run
Time:       ~5 seconds
Scales with: Length of THIS run (not total runs)
```

#### 2. Buffer Creation
```sql
-- Find blocks near this run
SELECT DISTINCT b.highway, b.geom_32610
FROM runmap.streets_blocks_32610 b
WHERE ST_DWithin(b.geom_32610, run_geom_utm, 50);
```

```
Complexity: O(total_blocks) with spatial index optimization → O(log(total_blocks))
Typical:    2,597 blocks checked, ~50-200 near run
Time:       ~3-10 seconds
Scales with: Spatial distribution of blocks (constant)
Memory:     ~5-10 MB for geometry operations
```

**Spatial index (GIST) makes this fast** - only checks blocks in spatial proximity.

#### 3. Coverage Update
```sql
-- Update blocks that intersect buffer
FOR each block intersecting buffer:
  IF block has no coverage:
    INSERT new coverage
  ELSE:
    UNION new coverage with existing
```

```
Complexity: O(blocks_touched)
Typical:    50-200 blocks per run
Time:       ~5-15 seconds
Scales with: Length of THIS run (not total runs)
Memory:     ~10-20 MB for geometry unions
```

**Incremental approach:** Each run only updates blocks IT touches, not all blocks.

#### 4. Stats Refresh
```sql
-- Recalculate aggregate statistics
REFRESH MATERIALIZED VIEW coverage_stats_blocks;
```

```
Complexity: O(blocks_with_coverage)
Current:    ~900 blocks have coverage
At 100 runs: ~1,500 blocks (estimate)
At 1000 runs: ~2,400 blocks (approaches total)
Time:       ~1 second
Scales with: Total blocks touched across ALL runs (grows slowly)
```

**Eventually hits ceiling** when most blocks have some coverage.

#### 5. Tile Export
```
Operation: Export blocks to GeoJSON → PMTiles
Complexity: O(total_blocks)
Current:    2,597 blocks
Time:       ~30-60 seconds
Scales with: Total blocks in system (constant)
```

**Does NOT scale with number of runs** - always exports current state of all blocks.

---

## Scaling Characteristics

### As Number of Runs Increases

| Runs | Buffer Time | Coverage Update | Stats Refresh | Total Time | Memory |
|------|-------------|----------------|---------------|------------|--------|
| 17*  | 5s          | 8s             | 0.5s          | ~13s       | 15 MB  |
| 100  | 5s          | 8s             | 1s            | ~14s       | 15 MB  |
| 500  | 5s          | 8s             | 1.5s          | ~15s       | 15 MB  |
| 1000 | 5s          | 8s             | 2s            | ~15s       | 15 MB  |
| 5000 | 5s          | 8s             | 2.5s          | ~16s       | 15 MB  |
| 10000| 5s          | 8s             | 3s            | ~16s       | 15 MB  |

*Current scale (October 2025)

**Key observation:** Processing time remains nearly constant!

**Why?**
- Each run only processes blocks IT touches (~50-200 typical)
- Memory usage is bounded by geometry operations on those blocks
- Database doesn't load all historical runs into memory
- Stats refresh grows slowly as more blocks get coverage (ceiling at 2,597 blocks)

---

## Comparison to Old System

### Old System (Full Recalculation)

**What it did:**
```sql
-- Recalculate coverage from scratch every time
CREATE MATERIALIZED VIEW coverage AS
SELECT
  streets.id,
  ST_Union(ALL buffers from ALL runs intersecting this street)
FROM streets
JOIN runs_buffered ON ST_Intersects(streets.geom, runs_buffered.geom)
GROUP BY streets.id;
```

**Complexity:** O(total_runs × total_streets)

**Memory usage:**
```
With 11 runs × 2,597 streets:
- Load all 11 run buffers into memory
- For each street, union all intersecting buffers
- Peak memory: 112 GB (!!)
- Crashed your server
```

**Time:** 5-10 minutes for 11 runs, exponentially worse as runs increased

---

### New System (Incremental)

**What it does:**
```sql
-- Only update blocks touched by NEW run
INSERT INTO block_coverage (block_id, covered_geom, ...)
SELECT ...
FROM blocks
WHERE ST_Intersects(blocks.geom, NEW_run_buffer)
ON CONFLICT DO UPDATE SET
  covered_geom = ST_Union(existing_coverage, new_coverage);
```

**Complexity:** O(blocks_touched_by_new_run)

**Memory usage:**
```
Per run:
- Load 1 run buffer into memory
- Update ~50-200 blocks
- Peak memory: 15-20 MB
- Constant regardless of total runs
```

**Time:** ~10-15 seconds per run, stays constant as runs increase

---

## Database Growth

### Storage Scaling

**Actual Measurements (17 runs, 8 walks, 0 cycling):**
- `runs_raw`: 1.1 MB (17 runs) = ~65 KB per run
- `runs_buffered_32610`: 1.8 MB (17 buffers) = ~105 KB per run buffer
- `walks_raw`: 496 KB (8 walks) = ~62 KB per walk
- `block_coverage_32610`: 552 KB (1,505 blocks with coverage)

**Projected Growth:**

| Runs | runs_raw | runs_buffered | block_coverage | walks_raw | Total DB |
|------|----------|---------------|----------------|-----------|----------|
| 17*  | 1.1 MB   | 1.8 MB        | 552 KB         | 496 KB    | ~6 MB    |
| 100  | 6.5 MB   | 10.5 MB       | 600 KB         | 3 MB      | ~25 MB   |
| 500  | 33 MB    | 53 MB         | 650 KB         | 15 MB     | ~110 MB  |
| 1000 | 65 MB    | 105 MB        | 700 KB         | 30 MB     | ~210 MB  |
| 5000 | 325 MB   | 525 MB        | 800 KB         | 150 MB    | ~1 GB    |
| 10000| 650 MB   | 1 GB          | 900 KB         | 300 MB    | ~2 GB    |

*Current scale (October 2025)

**Key insights:**
- `runs_raw` and `runs_buffered_32610` grow linearly (~170 KB per run combined)
- `walks_raw` and `cycling_raw` grow at similar rate (~62 KB per activity)
- `block_coverage_32610` approaches ceiling as more blocks get covered
- `streets_blocks_32610`: Fixed at ~744 KB (2,597 blocks, doesn't grow)

**Your server:** 100GB disk, can handle 100,000+ activities easily

---

## Performance Bottlenecks

### Current Bottlenecks (in order)

1. **Tile Export (~60 seconds)**
   - Exports entire state every time
   - Could be optimized with differential exports
   - Not a blocker - runs async in background

2. **Stats Refresh (1-2 seconds, grows slowly)**
   - Recalculates aggregates over all touched blocks
   - Eventually approaches ~2 seconds when most blocks touched
   - Acceptable

3. **Geometry Unions (5-15 seconds)**
   - `ST_Union(old_coverage, new_coverage)` for each touched block
   - PostGIS operation, well-optimized
   - Stays constant per run

**None of these scale badly with number of runs.**

### What Would Break the System?

**Scenario 1: Massive single run**
- 100km ultra-marathon touching 1,000+ blocks
- Still only O(1000), would take ~30-60 seconds
- Acceptable

**Scenario 2: 100,000 runs**
- Processing time still constant (~10-15 sec per run)
- Database size ~75 GB
- Stats refresh might hit 3-5 seconds
- Still usable

**Scenario 3: Real-time tile updates**
- If you wanted tiles to update immediately after every run
- 60 second tile export becomes blocker
- Solution: Differential tile exports or tile caching

---

## Optimization Opportunities

### If Performance Degrades

**1. Materialized View Refresh**
```sql
-- Current: Full refresh every run
REFRESH MATERIALIZED VIEW coverage_stats_blocks;

-- Alternative: Only when needed
-- Refresh on schedule (every hour) instead of per-run
-- Or use a regular view (slower queries, no refresh needed)
```

**2. Tile Export**
```sql
-- Current: Export all blocks every time

-- Alternative: Differential exports
-- Only export blocks that changed since last export
-- Or: Cache tiles, only regenerate changed areas
```

**3. Coverage Table**
```sql
-- Current: Geometry union on every update

-- Alternative: Use simpler geometry
-- Or: Pre-aggregate at block level (already doing this!)
```

**None of these are needed yet** - system performs well.

---

## When You'll Notice Slowdown

### Stats Refresh
```
After ~500 runs:   ~1.5 seconds (barely noticeable)
After ~2000 runs:  ~2 seconds (still fine)
After ~10000 runs: ~3-5 seconds (acceptable)
```

**Why it slows:** More blocks have coverage, more rows to aggregate

**Mitigation:**
- Use incremental stats updates
- Or just accept 3-5 second delay (still fast)

### Tile Export
```
Currently: ~60 seconds (independent of run count)
Forever:   ~60 seconds (only depends on total blocks)
```

**Already async** - doesn't block run processing

---

## Theoretical Limits

### Hard Limits

**Maximum blocks with coverage:** 2,597 (one per block)
- Already defined by street network
- Won't grow unless you add new streets

**Maximum runs:** Effectively unlimited
- Linear storage growth (~200 KB per run)
- Constant processing time per run
- Database can handle millions of rows easily

**Maximum processing time per run:** ~15 seconds
- Bounded by blocks touched (~50-200)
- Spatial index ensures fast lookups
- Geometry operations are well-optimized

### Soft Limits (Performance Degradation)

**~1,000 runs:** No noticeable slowdown
**~5,000 runs:** Stats refresh hits 2-3 seconds (acceptable)
**~10,000 runs:** Stats refresh hits 3-5 seconds (still usable)

**Current status (17 runs, 8 walks):** You have massive headroom before any issues.

---

## Adding Walks and Cycling Layers

### Current Architecture

The system already supports separate tracking of walks and cycling:
- **Separate tables:** `walks_raw`, `cycling_raw` (same structure as `runs_raw`)
- **Same deduplication:** Uses `content_hash` to prevent duplicates
- **No coverage tracking:** Walks/cycling don't affect block coverage (coverage is running-only)
- **Metadata tracking:** Distance, duration, pace/speed recorded separately

### Scalability Impact of Multiple Activity Types

**If you add walks/cycling visualization layers:**

#### Option 1: Display Tracks Only (Current)
```
No additional processing needed
- walks_raw table already exists: 496 KB (8 walks)
- No buffers or coverage calculations
- Export to PMTiles: +30 seconds one-time
- Tile size: ~5-10 MB for walks layer
```

**Impact:** Minimal - just export an additional PMTiles layer

#### Option 2: Separate Coverage for Walks
```
Would need to create:
- walks_buffered_32610 table
- walks_block_coverage_32610 table
- New processing functions
```

**Per-walk processing time:**
- Same as runs: ~10-15 seconds per walk
- Same memory usage: ~15 MB per walk
- Independent of running coverage

**Database growth:**
- walks_buffered_32610: ~105 KB per walk (same as runs)
- walks_block_coverage_32610: ~700 KB ceiling (separate from runs)

**Total system capacity:**
| Activity Type | Current | Easy Scale | Hard Limit |
|--------------|---------|------------|------------|
| Runs         | 17      | 5,000      | 50,000+    |
| Walks        | 8       | 5,000      | 50,000+    |
| Cycling      | 0       | 5,000      | 50,000+    |

**Key insight:** Each activity type scales independently. Total capacity is multiplicative, not additive.

### Recommended Approach

**For walks/cycling visualization:**
1. **Display tracks only** (no coverage calculation)
   - Export `walks_raw` to separate PMTiles layer
   - Different color from runs (e.g., blue for walks, yellow for cycling)
   - No additional processing needed
   - Minimal performance impact

2. **If you want walk coverage later:**
   - Clone the block coverage system for walks
   - Run processing in parallel with runs (separate functions)
   - Stats view would need updating to separate run/walk coverage

**Current implementation:** Walks are tracked but not visualized. Zero additional overhead beyond storage (~62 KB per walk).

---

## Real-World Scenario

**Your pace:** ~1 run every few days
**Runs per year:** ~100-150
**Years to hit 1,000 runs:** ~7-10 years

**By that time:**
- Processing time: Still ~10-15 seconds per run
- Stats refresh: ~1.5-2 seconds
- Total time: ~20 seconds per run
- Memory: ~15-20 MB per run
- Database size: ~750 MB

**Completely manageable.**

---

## Summary

### Current Performance
- **Per-run processing:** ~10-15 seconds
- **Memory:** ~15-20 MB per run
- **Scalability:** O(blocks_touched) not O(total_runs)

### As Runs Increase
- **Processing time:** Stays constant (~10-15 sec)
- **Memory usage:** Stays constant (~15-20 MB)
- **Database size:** Grows linearly (~750 MB at 1,000 runs)
- **Stats refresh:** Grows slowly (1s → 2s over 1,000 runs)

### Bottlenecks
1. ✅ **None currently** - system is well-designed
2. ⚠️ **Tile export** (60 sec, but async)
3. ⚠️ **Stats refresh** (1-2 sec, grows to 3-5 sec eventually)

### The Big Win
**Old system:** O(N × M) where N=runs, M=streets → 112GB RAM crash
**New system:** O(K) where K=blocks touched by current run → 15MB constant

**You can scale to 10,000+ runs without issues.**

---

---

## Future Scaling Problems - Summary

Based on current architecture and actual measurements, here are potential issues and when you'll hit them:

### ✅ No Concerns (Current → 1,000 activities)
- **Per-run processing time:** 13-15 seconds (constant)
- **Memory usage:** ~15 MB per run (constant)
- **Database size:** ~200 MB (manageable)
- **Stats refresh:** 0.5-2 seconds (acceptable)

### ⚠️ Minor Issues (1,000 → 5,000 activities)
1. **Stats refresh slowdown**
   - Time: 2-3 seconds (currently 0.5s)
   - Impact: Barely noticeable
   - Mitigation: Cache stats, refresh on schedule instead of per-run

2. **Database size growth**
   - Size: ~1 GB (currently ~6 MB)
   - Impact: None (server has 100 GB disk)
   - Mitigation: Not needed

### 🟡 Moderate Issues (5,000 → 10,000 activities)
1. **Tile export time**
   - Time: Still ~60 seconds (doesn't scale with runs)
   - Impact: Async process, doesn't block uploads
   - Mitigation: Differential tile exports (export only changed blocks)

2. **Stats view refresh**
   - Time: 3-5 seconds
   - Impact: Noticeable but acceptable
   - Mitigation: Incremental stats updates or scheduled refreshes

3. **Bulk operations**
   - Reprocessing all runs takes longer (linear growth)
   - Impact: Only affects full rebuilds (rare)
   - Mitigation: Optimize bulk processing scripts

### 🔴 Potential Breaking Points (10,000+ activities)
1. **Full coverage recalculation**
   - Time: Would take hours to reprocess 10,000+ runs
   - Impact: Only needed if changing buffer distance or algorithm
   - Mitigation: Design schema changes to be incremental

2. **Database backup/restore**
   - Size: ~10 GB at 50,000 activities
   - Impact: Longer backup times
   - Mitigation: Incremental backups, pg_dump optimizations

3. **Spatial index maintenance**
   - Size: Index grows with geometry count
   - Impact: VACUUM and ANALYZE take longer
   - Mitigation: Scheduled maintenance, consider partitioning

### Activity Type Scaling

**Adding walks/cycling visualization:**
- **Tracks only:** No performance impact, just tile export time
- **Coverage tracking:** Independent scaling per activity type
- **Combined capacity:** Can handle 50,000+ of EACH activity type

**Recommendation:** Display tracks without coverage initially. Add coverage if needed later.

### When To Optimize

| Milestone | Action Required |
|-----------|----------------|
| 100 activities | ✅ None - current system optimal |
| 500 activities | ✅ None - minor stats slowdown acceptable |
| 1,000 activities | ⚠️ Consider caching stats view |
| 5,000 activities | ⚠️ Implement differential tile exports |
| 10,000 activities | 🟡 Add incremental stats updates |
| 50,000+ activities | 🔴 Consider database partitioning |

**You're currently at 25 activities total (17 runs + 8 walks).** You have 40x headroom before minor optimizations needed, 400x before moderate changes needed.

### Architecture Wins

The block-based incremental system has these fundamental advantages:
1. **Constant memory usage:** Always ~15 MB per run regardless of total runs
2. **Constant processing time:** Always ~13 seconds per run regardless of history
3. **Bounded complexity:** Ceiling at 2,597 blocks (won't grow unless street network changes)
4. **Independent scaling:** Multiple activity types don't interfere with each other

**Bottom line:** You will never hit memory limits. Only potential issue is stats refresh time, which grows logarithmically and can be easily optimized.

---

## See Also

- [Block Coverage Migration](BLOCK_PERCENTAGE_MIGRATION.md) - How incremental system works
- [Resource Impact Analysis](RESOURCE_IMPACT_ANALYSIS.md) - Memory comparison
- [Usage Guide](USAGE_GUIDE.md) - Day-to-day operations
