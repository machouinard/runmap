# Coverage Granularity Options

## Problem Statement

The current coverage calculation is too coarse-grained. OSM street segments are very long (median 120m, up to 1.8km), so when running in a grid pattern and crossing a street perpendicularly, the entire long segment gets marked as covered even though only a small portion was actually run.

**Example:** Crossing "P Street" (1,596m segment) perpendicularly only runs ~20m of it, but the 10m buffer intersection marks coverage against the entire 1.6km segment.

**Current Data:**
- Total segments: 1,456
- Average length: 175.3m
- Median length: 120.2m
- Max length: 1,800.8m (24th Street)

## Option 1: Spatial Subdivision (Recommended)

**Break each OSM street segment into smaller "virtual blocks" (~30-50m each) for coverage tracking**

### Implementation
- Keep original OSM geometry as-is in `streets_reference`
- Create new table `streets_subdivided_32610` that splits each street into ~30-50m chunks using `ST_LineSubstring`
- Track coverage on subdivided segments instead of original segments
- Update `apply_run_to_coverage()` to work with subdivided table
- Aggregate back to original streets for display/stats

### Process
```sql
-- For each street segment:
-- 1. Calculate number of chunks: CEIL(total_length / chunk_size)
-- 2. Generate chunk geometries using ST_LineSubstring at regular intervals
-- 3. Store with parent street reference
CREATE TABLE runmap.streets_subdivided_32610 (
  chunk_id SERIAL PRIMARY KEY,
  parent_ogc_fid INT REFERENCES runmap.streets_reference_32610(ogc_fid),
  chunk_index INT,
  geom_32610 geometry(LineString, 32610),
  chunk_length_m FLOAT
);
```

### Example
Original: "P Street" = 1 segment × 1,596m
Subdivided (50m chunks): "P Street" = 32 segments × ~50m each

Crossing perpendicularly marks only 1-2 chunks (~50-100m) as covered, not all 1,596m.

### Pros
- Minimal code changes (update coverage functions to use subdivided table)
- Can still show coverage on original street names by aggregating chunks
- Reversible - can adjust subdivision length and regenerate
- Accurately represents what was actually run
- Better visual representation on map (can style individual chunks)

### Cons
- More geometry rows (~10-15k instead of 1.5k, estimated 10x increase)
- Slightly more complex queries (need to join back to parent streets)
- Larger `street_coverage_32610` table
- Need to decide on optimal chunk size

### Chunk Size Considerations
Sacramento grid blocks are typically 100-120m between intersections.

- **30m chunks:** 3-4 chunks per block, very granular, catches partial block coverage
- **50m chunks:** 2-3 chunks per block, good balance, ~10-15k total segments
- **100m chunks:** 1-2 chunks per block, less granular but smaller table

**Recommendation:** Start with 50m chunks as a balance between granularity and table size.

## Option 2: Change Coverage Metric

**Instead of % length covered, require minimum continuous coverage**

### Implementation
- Continue tracking coverage as-is with current segment lengths
- Change "complete" threshold to require a continuous covered segment >X% of total length
- Use `ST_LineMerge` and `ST_Length` on `covered_geom` to find longest continuous section
- Only mark complete if `max_continuous_length >= total_length * 0.75`

### Example
"P Street" (1,596m total):
- Perpendicular crossing creates 20m covered section
- Longest continuous coverage = 20m (1.2% of total)
- Street stays "unrun" even though geometry intersected buffer

### Pros
- Simple concept - "did I run most of this street continuously?"
- No schema changes required
- Works with existing data

### Cons
- Doesn't solve the visual problem (map still shows whole street in one color)
- Harder to show "which parts are covered" on the map
- Requires `ST_LineMerge` on every coverage calculation (potentially slow)
- A street with 10 separate 10m crossings (100m total) would show as less complete than one 100m continuous run, even though same total distance

## Option 3: Re-import OSM with Finer Granularity

**Pre-process the OSM data to break streets at every intersection**

### Implementation
- Export current OSM data
- Use `ogr2ogr` or PostGIS to split LineStrings at all intersection points
- Re-import with each "block" (intersection to intersection) as separate segment
- Each segment gets its own coverage tracking

### Process
```bash
# Use ST_Split or similar to break at intersections
psql << 'EOF'
CREATE TABLE streets_split AS
WITH intersections AS (
  SELECT ST_Union(ST_StartPoint(geom)) AS pts FROM streets
  UNION ALL
  SELECT ST_Union(ST_EndPoint(geom)) AS pts FROM streets
)
SELECT
  ST_Split(s.geom, i.pts) as geom,
  s.name,
  s.highway
FROM streets s, intersections i;
EOF
```

### Example
Current: "P Street" = 1 segment (multiple blocks)
After split: "P Street" = 13 segments (one per block between intersections)

### Pros
- Most "correct" representation of street network
- Matches mental model of streets (block by block)
- Natural granularity based on actual intersection locations
- Each segment has real-world meaning (the block between X St and Y St)

### Cons
- Need to reprocess OSM source data before import
- Lose original OSM IDs/relationships
- More complex initial setup/tooling required
- Intersection detection can be tricky (tolerance issues, missing connections)
- Harder to update when OSM data changes

## Comparison Table

| Aspect | Option 1: Subdivision | Option 2: Continuous Metric | Option 3: OSM Re-import |
|--------|----------------------|----------------------------|------------------------|
| **Granularity** | Configurable (30-100m) | Same as current (120m avg) | Block-level (~100-120m) |
| **Schema Changes** | New subdivided table | None | Replace reference table |
| **Reversibility** | Easy (regenerate chunks) | Immediate | Hard (re-import required) |
| **Visual Accuracy** | Excellent | Poor | Excellent |
| **Implementation Effort** | Medium (new table + update functions) | Low (update views only) | High (pre-processing pipeline) |
| **Query Complexity** | Medium (join to parent) | Low-Medium | Low |
| **Table Size** | ~10-15k rows | ~1.5k rows | ~3-5k rows (estimated) |
| **Ongoing Maintenance** | Low | Low | Medium (re-split on OSM updates) |

## Recommendation

**Option 1: Spatial Subdivision with 50m chunks**

This provides the best balance of:
- Accurate representation of what was actually run
- Flexibility to adjust granularity
- Good visual feedback on the map
- Manageable complexity and table size

### Implementation Plan

1. Create `streets_subdivided_32610` table with subdivision function
2. Create `street_coverage_subdivided_32610` to track chunk-level coverage
3. Update `apply_run_to_coverage()` to use subdivided chunks
4. Update tile export views to aggregate chunks by color (unrun/partial/complete)
5. Create aggregation view showing per-original-street coverage stats
6. Test with existing runs
7. Export new tiles

Estimated effort: 2-3 hours implementation + testing
