-- ============================================================================
-- AOI-Based Location Detection (Scalable for Multiple Areas)
-- ============================================================================
-- This replaces the hardcoded bounding box approach with AOI polygon checks.
-- Now you can add new areas by just inserting AOI polygons!
-- Uses a 10-mile buffer around AOI polygons for forgiving location detection.

-- Drop old function
DROP FUNCTION IF EXISTS runmap.detect_location(geometry);

-- New AOI-based location detection with 10-mile buffer
CREATE OR REPLACE FUNCTION runmap.detect_location(run_geom geometry)
RETURNS TEXT AS $$
DECLARE
  centroid_point geometry;
  location_name TEXT;
  buffer_distance_m FLOAT := 16093.4;  -- 10 miles in meters
BEGIN
  -- Handle NULL geometry
  IF run_geom IS NULL THEN
    RETURN NULL;
  END IF;

  -- Get centroid of the activity
  centroid_point := ST_Centroid(run_geom);

  -- Check if centroid falls within any AOI polygon (with 10-mile buffer)
  -- Buffer is applied in UTM for accuracy, then checked against WGS84 centroid
  -- Priority order: sacramento > portland > other named AOIs > 'other'
  SELECT a.name INTO location_name
  FROM runmap.aoi a
  WHERE ST_Within(
    centroid_point,
    ST_Transform(ST_Buffer(ST_Transform(a.geom, 32610), buffer_distance_m), 4326)
  )
  ORDER BY
    CASE
      WHEN a.name = 'sacramento' THEN 1
      WHEN a.name = 'portland' THEN 2
      ELSE 3
    END
  LIMIT 1;

  -- If no AOI match, return 'other'
  RETURN COALESCE(LOWER(location_name), 'other');
END;
$$ LANGUAGE plpgsql STABLE;

GRANT EXECUTE ON FUNCTION runmap.detect_location(geometry) TO runmap_user;

-- ============================================================================
-- Ensure unique constraint on AOI name (required for ON CONFLICT)
-- ============================================================================
ALTER TABLE runmap.aoi DROP CONSTRAINT IF EXISTS aoi_name_unique;
ALTER TABLE runmap.aoi ADD CONSTRAINT aoi_name_unique UNIQUE (name);

-- ============================================================================
-- Add Portland AOI (example - adjust coordinates for your actual area)
-- ============================================================================
-- For now, using bounding box as placeholder
-- Replace with actual Portland metro polygon when you have OSM data

INSERT INTO runmap.aoi (name, geom)
VALUES (
  'portland',
  ST_MakeEnvelope(-122.8, 45.4, -122.5, 45.7, 4326)
)
ON CONFLICT (name) DO NOTHING;

-- ============================================================================
-- Backfill existing runs with new location detection
-- ============================================================================
-- This re-calculates locations using the AOI polygons

UPDATE runmap.runs_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL;

UPDATE runmap.walks_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL;

UPDATE runmap.cycling_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL;

-- Verify
SELECT
  'After AOI-based detection' as status,
  location,
  COUNT(*) as count
FROM runmap.runs_raw
GROUP BY location
ORDER BY location;
