-- Location-Based Run Tracking
-- Adds geographic location detection to runs, walks, and cycling activities
-- Created: 2025-10-19

-- ============================================================================
-- PHASE 1: Add location columns
-- ============================================================================

-- Add location to runs_raw
ALTER TABLE runmap.runs_raw
  ADD COLUMN IF NOT EXISTS location TEXT;

-- Add location to walks_raw
ALTER TABLE runmap.walks_raw
  ADD COLUMN IF NOT EXISTS location TEXT;

-- Add location to cycling_raw
ALTER TABLE runmap.cycling_raw
  ADD COLUMN IF NOT EXISTS location TEXT;

-- Create indexes for fast filtering
CREATE INDEX IF NOT EXISTS idx_runs_location ON runmap.runs_raw(location);
CREATE INDEX IF NOT EXISTS idx_walks_location ON runmap.walks_raw(location);
CREATE INDEX IF NOT EXISTS idx_cycling_location ON runmap.cycling_raw(location);

-- ============================================================================
-- PHASE 2: Create location detection function
-- ============================================================================

CREATE OR REPLACE FUNCTION runmap.detect_location(geom geometry)
RETURNS TEXT AS $$
DECLARE
  centroid_point geometry;
  lon FLOAT;
  lat FLOAT;
BEGIN
  -- Handle NULL geometry
  IF geom IS NULL THEN
    RETURN NULL;
  END IF;

  -- Get centroid of the activity
  centroid_point := ST_Centroid(geom);
  lon := ST_X(centroid_point);
  lat := ST_Y(centroid_point);

  -- Check Sacramento boundaries (expanded to metro area)
  -- Latitude: 38.4° to 38.7°
  -- Longitude: -121.6° to -121.3°
  IF lat BETWEEN 38.4 AND 38.7
     AND lon BETWEEN -121.6 AND -121.3 THEN
    RETURN 'sacramento';
  END IF;

  -- Check Portland boundaries (expanded to metro area)
  -- Latitude: 45.4° to 45.7°
  -- Longitude: -122.8° to -122.5°
  IF lat BETWEEN 45.4 AND 45.7
     AND lon BETWEEN -122.8 AND -122.5 THEN
    RETURN 'portland';
  END IF;

  -- Everything else
  RETURN 'other';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Grant execute to runmap_user
GRANT EXECUTE ON FUNCTION runmap.detect_location(geometry) TO runmap_user;

-- ============================================================================
-- PHASE 3: Backfill existing activities
-- ============================================================================

-- Backfill runs_raw
UPDATE runmap.runs_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL AND location IS NULL;

-- Backfill walks_raw
UPDATE runmap.walks_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL AND location IS NULL;

-- Backfill cycling_raw
UPDATE runmap.cycling_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL AND location IS NULL;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Show distribution by location
SELECT 'runs_raw' as table_name, location, COUNT(*)
FROM runmap.runs_raw
GROUP BY location
UNION ALL
SELECT 'walks_raw' as table_name, location, COUNT(*)
FROM runmap.walks_raw
GROUP BY location
UNION ALL
SELECT 'cycling_raw' as table_name, location, COUNT(*)
FROM runmap.cycling_raw
GROUP BY location
ORDER BY table_name, location;

-- Show Portland runs (should be 8)
SELECT filename, location,
  ROUND(ST_Y(ST_Centroid(geom))::numeric, 4) as lat,
  ROUND(ST_X(ST_Centroid(geom))::numeric, 4) as lon
FROM runmap.runs_raw
WHERE location = 'portland'
ORDER BY filename;

-- Show Sacramento run count (should be 301)
SELECT location, COUNT(*) as count
FROM runmap.runs_raw
WHERE location = 'sacramento'
GROUP BY location;
