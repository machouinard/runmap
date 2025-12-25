# Chunk Size Analysis: 25m vs 50m

## Current State (After Phase 1)

- **Total blocks:** 2,597
- **Distribution:**
  - <50m: 630 blocks (24%)
  - 50-100m: 631 blocks (24%)
  - 100-150m: 1,096 blocks (42%)
  - 150-200m: 84 blocks (3%)
  - >200m: 156 blocks (6%)

## Projection: 50m Max Chunk Size

### Chunking Logic (50m)
- Blocks ≤50m: Keep as-is (1 chunk per block)
- Blocks >50m: Split into chunks of ~50m

### Estimated Chunk Counts
```
<50m blocks:     630 blocks × 1 chunk    =    630 chunks
50-100m blocks:  631 blocks × 2 chunks   =  1,262 chunks (avg 75m → 2 chunks of ~37m)
100-150m blocks: 1,096 blocks × 2-3      =  2,740 chunks (avg 124m → 2-3 chunks of ~41-62m)
150-200m blocks: 84 blocks × 3-4         =    294 chunks (avg 171m → 3-4 chunks of ~43-57m)
>200m blocks:    156 blocks × 5+         =    936 chunks (avg 273m → 5-6 chunks of ~45-55m)
---
TOTAL:                                   ≈ 5,862 chunks
```

**Actual chunk size range:** 1.2m - 50m, most concentrated around 40-50m

### Impact

**Storage:**
- `streets_chunks_32610`: ~5,862 rows × ~400 bytes = **2.3 MB** + indexes (~1 MB) = **~3-4 MB**
- `chunk_coverage_32610`: ~5,862 rows × ~300 bytes = **1.8 MB** + indexes (~1 MB) = **~2-3 MB**
- **Total new storage:** ~6-8 MB

**Memory (per upload):**
- Your runs typically cross ~50-100 blocks
- With 50m chunks: each block has 2-3 chunks on average
- Chunks touched per run: **100-300 chunks**
- RAM per upload: **300-500 MB** ✅

**Tile size:**
- 5,862 chunks exported as GeoJSON → Tippecanoe → PMTiles
- 3 layers (unrun/partial/complete): **30-60 MB total**

**Visual granularity:**
- Crossing a street perpendicularly: marks **1-2 chunks** (~50-100m)
- Running a full block (120m): marks **2-3 chunks**
- GPS accuracy (±5-10m): Well represented by 50m chunks

---

## Projection: 25m Max Chunk Size

### Chunking Logic (25m)
- Blocks ≤25m: Keep as-is (1 chunk per block)
- Blocks >25m: Split into chunks of ~25m

### Estimated Chunk Counts
```
<25m blocks:     ~315 blocks × 1 chunk   =    315 chunks (half of <50m)
25-50m blocks:   ~315 blocks × 2 chunks  =    630 chunks (other half of <50m)
50-100m blocks:  631 blocks × 3-4        =  2,208 chunks (avg 75m → 3 chunks of ~25m)
100-150m blocks: 1,096 blocks × 4-6      =  5,480 chunks (avg 124m → 5 chunks of ~25m)
150-200m blocks: 84 blocks × 6-8         =    588 chunks (avg 171m → 7 chunks of ~24m)
>200m blocks:    156 blocks × 10+        =  1,872 chunks (avg 273m → 11 chunks of ~25m)
---
TOTAL:                                   ≈ 11,093 chunks
```

**Actual chunk size range:** 1.2m - 25m, most concentrated around 20-25m

### Impact

**Storage:**
- `streets_chunks_32610`: ~11,093 rows × ~400 bytes = **4.4 MB** + indexes (~2 MB) = **~6-7 MB**
- `chunk_coverage_32610`: ~11,093 rows × ~300 bytes = **3.3 MB** + indexes (~2 MB) = **~5-6 MB**
- **Total new storage:** ~12-14 MB

**Memory (per upload):**
- Your runs typically cross ~50-100 blocks
- With 25m chunks: each block has 4-5 chunks on average
- Chunks touched per run: **200-500 chunks**
- RAM per upload: **500-800 MB** ✅

**Tile size:**
- 11,093 chunks exported as GeoJSON → Tippecanoe → PMTiles
- 3 layers (unrun/partial/complete): **60-100 MB total**
- Browser must render 2x more features on map

**Visual granularity:**
- Crossing a street perpendicularly: marks **1 chunk** (~25m) ← More precise!
- Running a full block (120m): marks **4-5 chunks** ← More detailed progress
- GPS accuracy (±5-10m): 25m chunks might be overkill (GPS wobble is ~10-20m wide)

---

## Comparison Table

| Metric | 50m Chunks | 25m Chunks | Notes |
|--------|------------|------------|-------|
| **Total chunks** | ~5,900 | ~11,100 | 25m = 1.88x more chunks |
| **Storage** | 6-8 MB | 12-14 MB | 25m = 2x storage |
| **RAM per upload** | 300-500 MB | 500-800 MB | Both well within 32GB |
| **Tile export time** | 2-4 min | 3-6 min | 25m = 1.5x longer |
| **Tile file size** | 30-60 MB | 60-100 MB | 25m = 2x larger tiles |
| **Map rendering** | Good | Slower | 2x features to render |
| **Crossing street** | 1-2 chunks (~50-100m) | 1 chunk (~25m) | 25m more precise |
| **Full block run** | 2-3 chunks | 4-5 chunks | 25m shows more progress |
| **GPS accuracy match** | Excellent | Overkill? | GPS buffer is ±5-10m |

---

## Visual Examples

### Scenario: Crossing P Street Perpendicularly (122.8m block)

**With 50m chunks:**
- Block split into: 3 chunks (41m, 41m, 41m)
- Your perpendicular crossing (20m wide with 10m buffer): touches **1 chunk**
- Marked as covered: **41m of 122.8m block** (33% of block)
- Visual: One 41m green segment

**With 25m chunks:**
- Block split into: 5 chunks (25m, 25m, 25m, 25m, 23m)
- Your perpendicular crossing: touches **1 chunk**
- Marked as covered: **25m of 122.8m block** (20% of block)
- Visual: One 25m green segment ← More precise!

### Scenario: Running Full Block on 24th Street (120m block)

**With 50m chunks:**
- Block split into: 2 chunks (60m, 60m)
- Running the full block: marks **2 chunks** green
- Progress visible in 2 steps (50% done, 100% done)

**With 25m chunks:**
- Block split into: 5 chunks (24m, 24m, 24m, 24m, 24m)
- Running the full block: marks **5 chunks** green
- Progress visible in 5 steps (20%, 40%, 60%, 80%, 100%) ← More detailed!

---

## GPS Accuracy Considerations

**Your GPS buffer:** Currently 10m, planning to reduce to 5-8m

**GPS wobble width:** ±5-10m from true path = **10-20m wide corridor**

**Implications:**

**50m chunks:**
- Chunk length (50m) >> GPS wobble (20m)
- Clear distinction between "ran this chunk" vs "didn't run this chunk"
- Less likely to get false positives on parallel streets 25m away

**25m chunks:**
- Chunk length (25m) ≈ GPS wobble (20m)
- On a 25m chunk, GPS wobble covers 80% of chunk length
- Could mark chunks as "partial" when you actually ran the whole thing
- More noise in the data

---

## Performance Considerations

### Tile Rendering (Browser)

MapLibre GL JS must render all chunk geometries on the map.

**50m chunks:** ~6,000 line segments
- Typical desktop: 60 FPS, smooth
- Typical mobile: 45-60 FPS, smooth

**25m chunks:** ~11,000 line segments
- Typical desktop: 45-60 FPS, still smooth
- Typical mobile: 30-45 FPS, may stutter on older phones

**Verdict:** Both should be fine for modern browsers, but 50m has more headroom

### Database Query Performance

When you upload a run, PostGIS must:
1. Find all chunks intersecting the run buffer (spatial index scan)
2. Calculate ST_Intersection for each chunk
3. ST_Union with existing coverage

**50m chunks:** ~200 chunks touched → **0.5-1 second**
**25m chunks:** ~400 chunks touched → **1-2 seconds**

**Verdict:** Both fast enough for async processing

---

## Recommendation

### Use 50m Chunks

**Reasons:**

1. **Better GPS accuracy match:** 50m >> GPS wobble (20m)
   - Clearer signal: "I ran this chunk" vs noise
   - Less partial coverage artifacts

2. **Sufficient granularity for your use case:**
   - You're running in grid patterns (full blocks)
   - Goal: Track which blocks you've run, not sub-block precision
   - 50m chunks on 120m blocks = 2-3 chunks = good progress visibility

3. **Performance headroom:**
   - Half the tile size (30-60 MB vs 60-100 MB)
   - Faster map rendering
   - Faster uploads

4. **Visual clarity:**
   - Fewer, larger chunks = easier to see on map
   - At city zoom (z12-z14), 25m chunks might be too small to distinguish

5. **Sacramento block size:**
   - Typical block: 100-120m
   - 50m chunks: 2-3 per block (nice round number)
   - 25m chunks: 4-5 per block (more cluttered)

### When to Use 25m Chunks

**If you were:**
- Running partial blocks frequently (not your pattern)
- Zooming in to street level (z16-z18) to see fine detail
- Tracking very precise coverage for statistical analysis
- Running on very dense street grid (<50m blocks)

**But you're not doing these things**, so 50m is the sweet spot.

---

## Decision Matrix

| Your Priority | 50m | 25m | Winner |
|---------------|-----|-----|--------|
| Visual precision for perpendicular crossings | Good (1-2 chunks) | Better (1 chunk) | 25m (slight) |
| Visual precision for full blocks | Good (2-3 chunks) | Better (4-5 chunks) | 25m (slight) |
| Matches GPS accuracy | Excellent | Overkill | **50m** |
| Map rendering speed | Fast | Slower | **50m** |
| Tile download size | Smaller | Larger | **50m** |
| Upload processing time | Faster | Slower | **50m** |
| Storage efficiency | Better | Worse | **50m** |
| Visual clarity at city zoom | Better | Cluttered | **50m** |
| Simplicity | Better | More complex | **50m** |

**Score: 50m wins 6-3**

---

## Final Recommendation

**Start with 50m chunks.**

**Why:**
- Better matches GPS accuracy (~10-20m wide buffer corridor)
- Faster, smaller, simpler
- Still gives you excellent granularity (2-3 chunks per block)
- Easy to change later if needed (just rebuild)

**If you find 50m too coarse after testing:**
- You can re-run Phase 2 with 25m (takes 2 minutes)
- Or even try 35m or 40m as a middle ground

**The system is designed to be flexible** - chunk size is just a parameter to the `subdivide_blocks_to_chunks()` function.

Let's start with 50m and adjust based on real-world usage!
