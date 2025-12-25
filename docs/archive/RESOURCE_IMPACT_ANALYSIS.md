# Resource Impact Analysis: Chunk-Based Coverage System

## Current State (Baseline)

**Database Size:** 577 MB total

**Current Tables:**
| Table | Size | Rows | Notes |
|-------|------|------|-------|
| `street_coverage_32610` | 1.2 MB | 1,456 | Current coverage tracking |
| `streets_reference` | 1.0 MB | 1,456 | OSM baseline (WGS84) |
| `streets_reference_32610` | 1.0 MB | 1,456 | OSM baseline (UTM) |
| `runs_buffered_32610` | 328 KB | 3 | Per-run buffers |
| `runs_raw` | 256 KB | 3 | GPX tracks |

**Total Runmap Tables:** ~3.8 MB

**Server Specs (from CLAUDE.md):**
- RAM: 20 GB
- Previous issue: 112 GB RAM requirement with old full-recalculation system (crashed)
- Current incremental system: ~3 GB RAM

## Projected Impact of Chunk System

### Storage Impact

**New Tables to Create:**

1. **`streets_blocks_32610`** (intersection-split segments)
   - Estimated rows: ~4,000-5,000 (assuming avg 3 intersections per street)
   - Row size: ~500 bytes (geometry + metadata)
   - Estimated size: **2-2.5 MB**
   - Indexes: ~1 MB
   - **Total: ~3-3.5 MB**

2. **`streets_chunks_32610`** (50m subdivided chunks)
   - Estimated rows: ~12,000-15,000 (based on avg block length ~150m → 3 chunks/block)
   - Row size: ~400 bytes (shorter geometry + FK references)
   - Estimated size: **5-6 MB**
   - Indexes (geom + parent FK): ~2-3 MB
   - **Total: ~7-9 MB**

3. **`chunk_coverage_32610`** (chunk-level coverage)
   - Rows: Same as chunks (~12,000-15,000)
   - Row size: ~300 bytes (coverage geometry + stats)
   - Estimated size: **4-5 MB**
   - Indexes: ~2 MB
   - **Total: ~6-7 MB**

4. **`runs_union_32610`** (materialized view - CONCERN!)
   - Single row with unioned geometry of all runs
   - Current: 3 runs, small area
   - Future: 50+ runs across Sacramento
   - **Estimated size: 10-50 MB** (depends on run density)
   - **THIS IS THE WILDCARD**

### Total Storage Increase

**Conservative estimate:** +20-30 MB (including indexes)
**With 50+ runs:** +50-75 MB for union materialized view

**New database size:** ~600-650 MB (from 577 MB)
**Impact:** ✅ **NEGLIGIBLE** - well within server capacity

---

### Memory Impact (CRITICAL)

#### One-Time Operations (Migration)

**1. Split streets at intersections:**
```sql
SELECT runmap.split_streets_at_intersections();
```
- Loads all 1,456 streets into memory
- Computes intersections via spatial joins
- Uses `ST_Split` on each street
- **Peak RAM:** ~500 MB - 1 GB
- **Duration:** 2-5 minutes
- **Risk:** ✅ **LOW** - server has 20GB RAM

**2. Subdivide blocks to chunks:**
```sql
SELECT runmap.subdivide_blocks_to_chunks(50.0);
```
- Iterates blocks sequentially (no massive join)
- Uses `ST_LineSubstring` (lightweight)
- **Peak RAM:** ~200-500 MB
- **Duration:** 1-2 minutes
- **Risk:** ✅ **LOW**

**3. Rebuild coverage from existing runs:**
```sql
SELECT runmap.rebuild_chunk_coverage();
```
- Processes 3 runs sequentially
- Each run: spatial join with ~15k chunks
- Filters to intersecting chunks only (~100-500 chunks per run)
- **Peak RAM per run:** ~300-500 MB
- **Total for 3 runs:** ~1 GB
- **Risk:** ✅ **LOW**

**4. Create runs union materialized view:**
```sql
REFRESH MATERIALIZED VIEW runmap.runs_union_32610;
```
- `ST_Union` of 3 run buffers
- **Peak RAM:** ~200-500 MB (only 3 runs currently)
- **Risk:** ✅ **LOW NOW**, ⚠️ **GROWS WITH RUNS**

---

#### Incremental Operations (Per Upload)

**On each new GPX upload:**

1. Buffer one run: ~50-100 MB RAM ✅
2. Apply to chunk coverage: ~300-500 MB RAM ✅
3. Refresh runs union MV: ⚠️ **THIS IS THE CONCERN**

**Runs Union Refresh (grows over time):**
- With 10 runs: ~1-2 GB RAM
- With 50 runs: ~5-10 GB RAM
- With 100 runs: ~10-20 GB RAM ⚠️ **APPROACHING LIMIT**

**Risk Assessment:**
- ✅ **Safe for <50 runs** (~10 GB peak)
- ⚠️ **Monitor at 50-75 runs** (10-15 GB peak)
- ❌ **May fail at 100+ runs** (exceeds 20 GB)

---

### CPU Impact

**One-time migration:**
- Intersection splitting: CPU-intensive (spatial joins, ST_Split)
- Estimated duration: **5-10 minutes** on server
- Server will be responsive but slow during this time

**Per-upload operations:**
- Similar to current incremental system
- Chunk coverage update: More rows to check (~15k vs 1.5k) but spatial index helps
- Estimated per-upload: **10-30 seconds** (vs current ~5-10 seconds)
- ✅ **Acceptable increase**

---

### Tile Export Impact

**Current tiles:** 5 PMTiles files, ~10-20 MB total

**New tiles (chunk-based):**
- `streets_unrun.pmtiles`: ~10k chunks → ~15-25 MB
- `streets_partial.pmtiles`: varies by coverage → ~5-15 MB
- `streets_complete.pmtiles`: varies by coverage → ~5-15 MB
- `runs.pmtiles`: unchanged
- `coverage.pmtiles`: unchanged (or remove if using chunks)

**Total tile size:** ~40-80 MB (from ~20 MB)

**Export duration:**
- Tippecanoe with 15k features: ~30-60 seconds per layer
- Total export time: **2-5 minutes** (vs current ~1-2 minutes)
- ✅ **Acceptable** - runs async anyway

**Nginx serving:**
- Larger PMTiles files but still efficient
- ✅ **No impact** - PMTiles designed for this

---

## RISK SUMMARY

### Immediate Risks (Migration)

| Operation | Peak RAM | Duration | Risk Level |
|-----------|----------|----------|------------|
| Split at intersections | 1 GB | 2-5 min | ✅ LOW |
| Subdivide to chunks | 500 MB | 1-2 min | ✅ LOW |
| Rebuild coverage | 1 GB | 2-3 min | ✅ LOW |
| Refresh union MV | 500 MB | 30 sec | ✅ LOW |
| **TOTAL MIGRATION** | **~2-3 GB** | **10-15 min** | ✅ **LOW** |

### Long-Term Risks (Operational)

| Scenario | Peak RAM | Risk Level | Mitigation |
|----------|----------|------------|------------|
| <50 total runs | <10 GB | ✅ LOW | None needed |
| 50-75 runs | 10-15 GB | ⚠️ MEDIUM | Monitor, consider union strategy change |
| 100+ runs | 15-20 GB | ❌ HIGH | **MUST** change union approach (see below) |

### THE BOTTLENECK: Runs Union Materialized View

**Current design:**
```sql
CREATE MATERIALIZED VIEW runmap.runs_union_32610 AS
SELECT ST_Union(geom) FROM runmap.runs_buffered_32610;
```

This `ST_Union` operation creates a single geometry from all runs. **Memory usage grows with run count.**

---

## MITIGATION STRATEGIES

### Option A: Skip Union, Use Individual Buffers (Recommended)

**Don't create a runs union at all.** Instead, check chunk coverage against individual run buffers:

```sql
-- In apply_run_to_chunk_coverage(), use ONLY the new run's buffer
-- Don't union with previous runs, just track cumulative covered_geom per chunk

-- Coverage calculation becomes:
covered_geom = ST_Union(existing_covered_geom, new_run_intersection)
```

**Advantages:**
- ✅ Memory usage stays constant per upload (only 1 run buffer in memory)
- ✅ No union operation needed
- ✅ Scales to unlimited runs

**Disadvantages:**
- ❌ Can't easily visualize "total coverage buffer" (but we have chunk colors for that)
- ❌ Slightly more complex logic (union coverage per chunk instead of globally)

**Verdict:** ✅ **THIS IS THE WAY** - avoids the scaling problem entirely

### Option B: Incremental Union (Fallback)

If we DO need a global union for some reason:

```sql
-- Instead of rebuilding from scratch, incrementally add new run
UPDATE runmap.runs_union_32610
SET geom = ST_Union(geom, (SELECT geom FROM runmap.runs_buffered_32610 WHERE run_id = NEW_RUN_ID));
```

**Peak RAM:** Only 2 geometries in memory (old union + new run) → ~500 MB regardless of run count

**Disadvantages:**
- Geometry complexity grows over time (can degrade performance)
- May need periodic simplification

---

## RECOMMENDATION

### Implement with Option A (No Global Union)

**Changes to implementation plan:**

1. ❌ **REMOVE** `runs_union_32610` materialized view entirely
2. ✅ **KEEP** individual `runs_buffered_32610` rows
3. ✅ **MODIFY** `apply_run_to_chunk_coverage()` to union coverage incrementally per chunk:
   ```sql
   -- For each chunk touched by new run:
   covered_geom = ST_Union(existing_covered_geom, new_coverage_segment)
   ```

**Result:**
- ✅ Peak RAM stays constant: ~500 MB per upload regardless of run count
- ✅ Scales to 100+ runs easily
- ✅ No operational risk

**Storage impact:** -10 to -50 MB (no union MV needed)
**RAM impact:** ✅ **SAFE** - never exceeds 2 GB even with 1000 runs

---

## MONITORING CHECKLIST

Before migration:
- [ ] Verify server has >5 GB free RAM: `free -h`
- [ ] Check no other heavy processes running: `htop`
- [ ] Ensure database has no active connections: `SELECT count(*) FROM pg_stat_activity WHERE datname='runmap';`

During migration:
- [ ] Monitor RAM usage: `watch -n 5 free -h`
- [ ] Monitor PostgreSQL processes: `watch -n 5 "ps aux | grep postgres"`
- [ ] Keep terminal open to kill process if needed: `Ctrl+C` in psql

After migration:
- [ ] Verify table sizes: `\dt+ runmap.*`
- [ ] Check chunk count: `SELECT COUNT(*) FROM runmap.streets_chunks_32610;`
- [ ] Test one incremental upload, monitor RAM

---

## GO / NO-GO DECISION

**Migration (one-time):** ✅ **GO**
- Peak RAM: ~2-3 GB
- Server capacity: 20 GB
- Safety margin: 6-10x
- Risk: **LOW**

**Long-term operation:** ✅ **GO** (with Option A - no global union)
- Peak RAM per upload: ~500 MB (constant)
- Scales to unlimited runs
- Risk: **LOW**

**Recommended approach:** Proceed with implementation using **Option A** (no runs union MV).

---

## ROLLBACK PLAN

If migration causes issues:

1. **Stop immediately** (Ctrl+C in psql)
2. **Check RAM:** `free -h` - if >18 GB used, wait for process to complete or reboot
3. **Rollback:** New tables are separate, old system intact
4. **Restart services:** `sudo systemctl restart postgresql` if needed
5. **Verify old system works:** Test upload with old incremental functions

**Data loss risk:** ✅ **NONE** - all new tables, old system untouched
