# Location-Based Run Tracking

**Date**: 2025-10-19
**Status**: Planning
**Goal**: Add location detection to runs (sacramento/portland/other) for accurate per-city distance totals

---

## Problem Statement

Currently all runs are stored in `runs_raw` regardless of location:
- 301 runs in Sacramento, CA (latitude ~38.55°)
- 8 runs in Portland, OR (latitude ~45.51°)
- Distance totals include all runs regardless of location
- No way to get Sacramento-only or Portland-only totals

**We don't have Portland street data**, so we can't use intersection-based detection. We need a geographic coordinate approach.

---

## Solution: Geographic Bounding Box Detection

### Detection Strategy

Use **known geographic boundaries** for each city:

**Sacramento, CA**:
- Latitude: 38.4° to 38.7°
- Longitude: -121.6° to -121.3°
- (Covers greater Sacramento metro area)

**Portland, OR**:
- Latitude: 45.4° to 45.7°
- Longitude: -122.8° to -122.5°
- (Covers greater Portland metro area)

**Detection Logic**:
1. Calculate run's centroid (center point)
2. Check if centroid falls within Sacramento bbox → 'sacramento'
3. Else check if centroid falls within Portland bbox → 'portland'
4. Else → 'other'

### Why Centroid?

- **Fast**: Single point check vs full geometry intersection
- **Accurate enough**: Runs don't cross city boundaries (Sacramento to Portland is 580 miles)
- **Simple**: No external data needed (streets, boundaries, etc.)
- **Bulletproof**: Works for any city we add in the future

---

## Implementation Plan

### Phase 1: Schema Changes

**1. Add location column to runs_raw**
```sql
ALTER TABLE runmap.runs_raw
  ADD COLUMN location TEXT;

-- Add index for fast filtering
CREATE INDEX idx_runs_location ON runmap.runs_raw(location);
```

**2. Add location column to walks_raw and cycling_raw**
```sql
ALTER TABLE runmap.walks_raw
  ADD COLUMN location TEXT;

ALTER TABLE runmap.cycling_raw
  ADD COLUMN location TEXT;

CREATE INDEX idx_walks_location ON runmap.walks_raw(location);
CREATE INDEX idx_cycling_location ON runmap.cycling_raw(location);
```

### Phase 2: Create Detection Function

**3. Create city boundary detection function**
```sql
CREATE OR REPLACE FUNCTION runmap.detect_location(geom geometry)
RETURNS TEXT AS $$
DECLARE
  centroid_point geometry;
  lon FLOAT;
  lat FLOAT;
BEGIN
  -- Get centroid of the run
  centroid_point := ST_Centroid(geom);
  lon := ST_X(centroid_point);
  lat := ST_Y(centroid_point);

  -- Check Sacramento boundaries (expanded to metro area)
  IF lat BETWEEN 38.4 AND 38.7
     AND lon BETWEEN -121.6 AND -121.3 THEN
    RETURN 'sacramento';
  END IF;

  -- Check Portland boundaries (expanded to metro area)
  IF lat BETWEEN 45.4 AND 45.7
     AND lon BETWEEN -122.8 AND -122.5 THEN
    RETURN 'portland';
  END IF;

  -- Everything else
  RETURN 'other';
END;
$$ LANGUAGE plpgsql IMMUTABLE;
```

### Phase 3: Backfill Existing Runs

**4. Update location for all existing runs**
```sql
-- Backfill runs_raw
UPDATE runmap.runs_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL;

-- Backfill walks_raw
UPDATE runmap.walks_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL;

-- Backfill cycling_raw
UPDATE runmap.cycling_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL;
```

**5. Verify the backfill**
```sql
-- Check distribution
SELECT location, COUNT(*)
FROM runmap.runs_raw
GROUP BY location;

-- Verify Portland runs detected correctly
SELECT filename, location,
  ROUND(ST_Y(ST_Centroid(geom))::numeric, 2) as lat
FROM runmap.runs_raw
WHERE location = 'portland'
ORDER BY filename;

-- Verify Sacramento runs
SELECT location, COUNT(*)
FROM runmap.runs_raw
WHERE location = 'sacramento';
```

### Phase 4: Update Auto-Process Trigger

**6. Modify trigger to set location on insert**
```sql
CREATE OR REPLACE FUNCTION runmap.auto_process_new_run()
RETURNS TRIGGER AS $$
BEGIN
  -- Set location if not already set and geometry exists
  IF NEW.geom IS NOT NULL AND NEW.location IS NULL THEN
    NEW.location := runmap.detect_location(NEW.geom);
  END IF;

  -- Buffer and process coverage (existing logic)
  PERFORM runmap.buffer_one_run(NEW.id);
  PERFORM runmap.apply_run_to_coverage(NEW.id);

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### Phase 5: Update Bulk Import Scripts

**7. Modify bulk import to set location**

Update `scripts/bulk_import_ultra_fast.py` to:
- Detect location based on GPX centroid before import
- Include location in COPY statement

**8. Update API upload endpoint**

Modify `api/app.py` to:
- Let database trigger handle location detection (no code changes needed!)
- Trigger will auto-set location when geometry is inserted

---

## Verification Queries

### After Implementation

```sql
-- Total distance by location
SELECT
  location,
  COUNT(*) as num_runs,
  ROUND(SUM(total_distance_m) / 1609.34) as total_miles,
  ROUND(AVG(total_distance_m) / 1609.34, 2) as avg_miles_per_run
FROM runmap.runs_raw
GROUP BY location
ORDER BY location;

-- Sacramento-only stats
SELECT
  COUNT(*) as total_runs,
  ROUND(SUM(total_distance_m) / 1609.34) as total_miles
FROM runmap.runs_raw
WHERE location = 'sacramento';

-- Portland-only stats
SELECT
  COUNT(*) as total_runs,
  ROUND(SUM(total_distance_m) / 1609.34) as total_miles
FROM runmap.runs_raw
WHERE location = 'portland';

-- Verify expected distribution (301 sacramento, 8 portland)
SELECT
  location,
  COUNT(*),
  ARRAY_AGG(filename ORDER BY filename) FILTER (WHERE location = 'portland') as portland_files
FROM runmap.runs_raw
GROUP BY location;
```

---

## Edge Cases Handled

### 1. Runs with NULL geometry
- Location stays NULL
- Won't break queries (can filter with `WHERE location IS NOT NULL`)

### 2. Runs outside both cities
- Get `location = 'other'`
- Still tracked, just not in city-specific stats

### 3. Future cities
- Add new boundary checks to `detect_location()` function
- Rerun UPDATE to reclassify existing runs
- Example: Add 'san_francisco', 'seattle', etc.

### 4. Boundary expansion
- Sacramento boundaries are generous (38.4-38.7, not strict city limits)
- Captures suburbs and metro area
- Reduces 'other' classification for nearby runs

### 5. Manual override
- Users can manually UPDATE location if detection is wrong
- Not expected to be needed (cities are 580 miles apart)

---

## Future Enhancements

### Option 1: City-Specific Coverage Stats

Add materialized views:
```sql
CREATE MATERIALIZED VIEW runmap.sacramento_stats AS
SELECT
  COUNT(*) as total_runs,
  SUM(total_distance_m) as total_distance_m,
  (SELECT block_completion_pct FROM runmap.coverage_stats_blocks) as coverage_pct
FROM runmap.runs_raw
WHERE location = 'sacramento';
```

### Option 2: Multi-City Coverage Tracking

If Portland street data is added later:
- Import Portland streets to separate tables or add `city` column to existing tables
- Create Portland-specific blocks and coverage
- Frontend shows city selector
- All queries filter by location

### Option 3: More Granular Locations

Change to hierarchical:
- `location_city`: 'sacramento', 'portland'
- `location_neighborhood`: 'midtown', 'downtown', 'pearl_district'
- Detect neighborhood based on finer-grained bboxes

---

## Files to Create/Modify

### New Files
- `db/13_location_tracking.sql` - All schema changes and functions

### Modified Files
- `db/11_auto_process_trigger.sql` - Add location detection to trigger
- `scripts/bulk_import_ultra_fast.py` - Add location to import (optional, trigger handles it)
- `api/app.py` - No changes needed (trigger handles it)

### Documentation
- `CLAUDE.md` - Add location column to schema documentation
- `docs/LOCATION_TRACKING.md` - This file

---

## Rollout Steps

1. ✅ Create this planning document
2. ⏳ Review and approve plan
3. ⏳ Create `db/13_location_tracking.sql`
4. ⏳ Test on development database
5. ⏳ Run on production database
6. ⏳ Verify backfill results (301 sacramento, 8 portland expected)
7. ⏳ Update trigger function
8. ⏳ Test with new upload
9. ⏳ Update CLAUDE.md documentation

---

## Expected Results

### Before
```
Total runs: 309
Total distance: ALL runs included (Sacramento + Portland + Other)
```

### After
```
Location     | Runs | Total Miles
-------------|------|------------
sacramento   | 301  | ~XXX miles
portland     |   8  | ~XX miles
other        |   0  | 0 miles
```

### Coverage Stats (unchanged)
```
Sacramento coverage: 89.12% (only counts Sacramento runs)
Portland coverage: N/A (no street data)
```

Coverage calculations are ALREADY filtered by geometry intersection with Sacramento streets, so they won't change. This just adds the ability to query distance totals per city.

---

## Risk Assessment

**Risk Level**: ⚠️ LOW

**Why Low Risk?**
- Adding a column (not modifying existing data)
- Function is read-only (just calculates location)
- Backfill is UPDATE only (can rollback if needed)
- Doesn't affect coverage calculations (already geographic)
- Can be tested on copy of database first

**Rollback Plan**:
```sql
-- If something goes wrong:
ALTER TABLE runmap.runs_raw DROP COLUMN location;
ALTER TABLE runmap.walks_raw DROP COLUMN location;
ALTER TABLE runmap.cycling_raw DROP COLUMN location;
DROP FUNCTION runmap.detect_location(geometry);
```

---

*Ready for implementation when approved.*
