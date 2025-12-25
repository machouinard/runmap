-- ============================================================================
-- Phase 1: Split Streets at Intersections
-- ============================================================================
-- Creates topology-aware street blocks by splitting at real intersections.
-- This gives us "block-level" segments that align with the actual street grid.
-- ============================================================================

-- Create the blocks table
CREATE TABLE IF NOT EXISTS runmap.streets_blocks_32610 (
  block_id SERIAL PRIMARY KEY,
  parent_ogc_fid INT REFERENCES runmap.streets_reference_32610(ogc_fid),
  block_index INT,
  geom_32610 geometry(LineString, 32610),
  block_length_m FLOAT,
  -- Metadata from parent
  name TEXT,
  highway TEXT
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_blocks_geom ON runmap.streets_blocks_32610 USING GIST(geom_32610);
CREATE INDEX IF NOT EXISTS idx_blocks_parent ON runmap.streets_blocks_32610(parent_ogc_fid);

-- Function to split streets at intersection points
CREATE OR REPLACE FUNCTION runmap.split_streets_at_intersections()
RETURNS void AS $$
DECLARE
  street_rec RECORD;
  intersection_pts geometry;
  split_geom geometry;
  segment geometry;
  segment_idx INT;
  segment_count INT := 0;
  street_count INT := 0;
  total_streets INT;
BEGIN
  -- Clear existing data
  TRUNCATE runmap.streets_blocks_32610 CASCADE;

  SELECT COUNT(*) INTO total_streets FROM runmap.streets_reference_32610;
  RAISE NOTICE 'Splitting % streets at intersections...', total_streets;

  FOR street_rec IN
    SELECT ogc_fid, name, highway, geom_32610, total_length_m
    FROM runmap.streets_reference_32610
    ORDER BY ogc_fid
  LOOP
    street_count := street_count + 1;

    -- Progress indicator every 100 streets
    IF street_count % 100 = 0 THEN
      RAISE NOTICE 'Processing street % of % (%.0f%%)...',
        street_count, total_streets, (street_count::FLOAT / total_streets * 100);
    END IF;

    -- Find all intersection points for this street
    -- (points where other streets cross this street's geometry)
    SELECT ST_Union(pts) INTO intersection_pts
    FROM (
      SELECT ST_Intersection(street_rec.geom_32610, other.geom_32610) AS pts
      FROM runmap.streets_reference_32610 other
      WHERE other.ogc_fid != street_rec.ogc_fid
        AND ST_Intersects(street_rec.geom_32610, other.geom_32610)
        AND ST_GeometryType(ST_Intersection(street_rec.geom_32610, other.geom_32610)) = 'ST_Point'
    ) t
    WHERE pts IS NOT NULL;

    -- If no intersections found, keep original segment as single block
    IF intersection_pts IS NULL THEN
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES
        (street_rec.ogc_fid, 0, street_rec.geom_32610, street_rec.total_length_m,
         street_rec.name, street_rec.highway);
      segment_count := segment_count + 1;
      CONTINUE;
    END IF;

    -- Split street at intersection points
    BEGIN
      split_geom := ST_Split(street_rec.geom_32610, intersection_pts);
    EXCEPTION WHEN OTHERS THEN
      -- If split fails (can happen with topology issues), keep original
      RAISE WARNING 'Failed to split street ogc_fid=% (%): %. Keeping as single block.',
        street_rec.ogc_fid, COALESCE(street_rec.name, 'unnamed'), SQLERRM;
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES
        (street_rec.ogc_fid, 0, street_rec.geom_32610, street_rec.total_length_m,
         street_rec.name, street_rec.highway);
      segment_count := segment_count + 1;
      CONTINUE;
    END;

    -- Insert each resulting segment as a block
    segment_idx := 0;
    FOR segment IN
      SELECT (ST_Dump(split_geom)).geom
    LOOP
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES (
        street_rec.ogc_fid,
        segment_idx,
        segment,
        ST_Length(segment),
        street_rec.name,
        street_rec.highway
      );
      segment_idx := segment_idx + 1;
      segment_count := segment_count + 1;
    END LOOP;
  END LOOP;

  RAISE NOTICE '====================================';
  RAISE NOTICE 'Phase 1 Complete: Intersection Split';
  RAISE NOTICE 'Input: % streets', total_streets;
  RAISE NOTICE 'Output: % blocks', segment_count;
  RAISE NOTICE 'Ratio: %.1f blocks per street', segment_count::FLOAT / total_streets;
  RAISE NOTICE '====================================';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- DIAGNOSTIC QUERIES
-- ============================================================================

-- View block statistics
CREATE OR REPLACE VIEW runmap.blocks_stats AS
SELECT
  COUNT(*) as total_blocks,
  ROUND(AVG(block_length_m)::numeric, 1) as avg_length_m,
  ROUND(MIN(block_length_m)::numeric, 1) as min_length_m,
  ROUND(MAX(block_length_m)::numeric, 1) as max_length_m,
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY block_length_m)::numeric, 1) as median_length_m,
  COUNT(*) FILTER (WHERE block_length_m > 200) as blocks_over_200m,
  COUNT(*) FILTER (WHERE block_length_m > 100) as blocks_over_100m,
  COUNT(*) FILTER (WHERE block_length_m > 50) as blocks_over_50m
FROM runmap.streets_blocks_32610;

-- View blocks grouped by parent street
CREATE OR REPLACE VIEW runmap.blocks_per_street AS
SELECT
  s.ogc_fid,
  s.name,
  s.highway,
  s.total_length_m as original_length_m,
  COUNT(b.block_id) as num_blocks,
  ROUND(AVG(b.block_length_m)::numeric, 1) as avg_block_length_m
FROM runmap.streets_reference_32610 s
LEFT JOIN runmap.streets_blocks_32610 b ON b.parent_ogc_fid = s.ogc_fid
GROUP BY s.ogc_fid, s.name, s.highway, s.total_length_m
ORDER BY COUNT(b.block_id) DESC;

-- ============================================================================
-- USAGE
-- ============================================================================

-- Run the split:
-- SELECT runmap.split_streets_at_intersections();

-- View statistics:
-- SELECT * FROM runmap.blocks_stats;

-- See which streets got split the most:
-- SELECT * FROM runmap.blocks_per_street LIMIT 20;

-- Check a specific street (e.g., P Street):
-- SELECT * FROM runmap.blocks_per_street WHERE name = 'P Street';
