-- ============================================================================
-- Block-Percentage Coverage System
-- ============================================================================
-- Simplified coverage tracking using blocks (no chunk subdivision needed)
-- Blocks are already split at intersections (Phase 1), which provides
-- sufficient granularity to detect perpendicular crossings.
--
-- Benefits over chunk system:
-- - 60% fewer segments (2,597 blocks vs 6,456 chunks)
-- - Simpler schema (no subdivision step)
-- - Faster processing and smaller tiles
-- - More intuitive (blocks ≈ city blocks)
-- ============================================================================

-- Add configurable completion threshold to settings
INSERT INTO runmap.settings (key, value)
VALUES ('completion_threshold_pct', '90'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- Drop chunk-based system
DROP TABLE IF EXISTS runmap.chunk_coverage_32610 CASCADE;
DROP TABLE IF EXISTS runmap.streets_chunks_32610 CASCADE;
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats_chunks CASCADE;

-- Create block coverage table
-- Note: status is calculated in views using configurable threshold from settings
CREATE TABLE IF NOT EXISTS runmap.block_coverage_32610 (
  block_id INT PRIMARY KEY REFERENCES runmap.streets_blocks_32610(block_id),
  covered_geom geometry(Geometry, 32610),
  covered_length_m FLOAT NOT NULL DEFAULT 0,
  total_length_m FLOAT NOT NULL,
  coverage_pct FLOAT GENERATED ALWAYS AS (
    CASE
      WHEN total_length_m > 0 THEN ROUND((covered_length_m / total_length_m * 100)::numeric, 2)
      ELSE 0
    END
  ) STORED
);

CREATE INDEX IF NOT EXISTS idx_block_coverage_pct
  ON runmap.block_coverage_32610(coverage_pct);
CREATE INDEX IF NOT EXISTS idx_block_coverage_geom
  ON runmap.block_coverage_32610 USING GIST(covered_geom);

-- Helper function to get completion threshold
CREATE OR REPLACE FUNCTION runmap.get_completion_threshold()
RETURNS FLOAT AS $$
  SELECT COALESCE((value::float), 90.0)
  FROM runmap.settings
  WHERE key = 'completion_threshold_pct';
$$ LANGUAGE sql STABLE;

-- Function to apply a single run to block coverage (incremental)
CREATE OR REPLACE FUNCTION runmap.apply_run_to_block_coverage(run_uuid UUID)
RETURNS void AS $$
DECLARE
  v_threshold FLOAT;
BEGIN
  -- Get current threshold
  v_threshold := runmap.get_completion_threshold();

  -- Find blocks that intersect this run's buffer and update coverage
  INSERT INTO runmap.block_coverage_32610 (block_id, covered_geom, covered_length_m, total_length_m)
  SELECT
    b.block_id,
    ST_Intersection(b.geom_32610, rb.geom) as new_coverage,
    ST_Length(ST_Intersection(b.geom_32610, rb.geom)) as new_length,
    b.block_length_m as total_length_m
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = run_uuid
  WHERE ST_Intersects(b.geom_32610, rb.geom)
  ON CONFLICT (block_id) DO UPDATE SET
    -- Union new coverage with existing coverage
    covered_geom = ST_Union(
      runmap.block_coverage_32610.covered_geom,
      EXCLUDED.covered_geom
    ),
    -- Recalculate length from unioned geometry
    covered_length_m = ST_Length(ST_Union(
      runmap.block_coverage_32610.covered_geom,
      EXCLUDED.covered_geom
    ));
END;
$$ LANGUAGE plpgsql;

-- Function to rebuild all block coverage from scratch
CREATE OR REPLACE FUNCTION runmap.rebuild_block_coverage()
RETURNS void AS $$
BEGIN
  TRUNCATE runmap.block_coverage_32610;

  -- Process all runs in order
  PERFORM runmap.apply_run_to_block_coverage(id)
  FROM runmap.runs_raw
  ORDER BY uploaded_at;

  RAISE NOTICE 'Rebuilt coverage for % blocks',
    (SELECT COUNT(*) FROM runmap.block_coverage_32610 WHERE covered_length_m > 0);
END;
$$ LANGUAGE plpgsql;

-- Views for complete and incomplete blocks
CREATE OR REPLACE VIEW runmap.blocks_incomplete AS
SELECT
  b.block_id,
  b.name,
  b.highway,
  b.geom_32610,
  b.block_length_m,
  COALESCE(bc.coverage_pct, 0) as coverage_pct,
  COALESCE(bc.covered_length_m, 0) as covered_length_m,
  b.block_length_m as total_length_m
FROM runmap.streets_blocks_32610 b
LEFT JOIN runmap.block_coverage_32610 bc ON b.block_id = bc.block_id
WHERE COALESCE(bc.coverage_pct, 0) < runmap.get_completion_threshold();

CREATE OR REPLACE VIEW runmap.blocks_complete AS
SELECT
  b.block_id,
  b.name,
  b.highway,
  b.geom_32610,
  b.block_length_m,
  bc.coverage_pct,
  bc.covered_length_m,
  b.block_length_m as total_length_m
FROM runmap.streets_blocks_32610 b
JOIN runmap.block_coverage_32610 bc ON b.block_id = bc.block_id
WHERE bc.coverage_pct >= runmap.get_completion_threshold();

-- Coverage statistics materialized view
CREATE MATERIALIZED VIEW runmap.coverage_stats_blocks AS
SELECT
  (SELECT COUNT(*) FROM runmap.streets_blocks_32610) as total_blocks,
  COUNT(*) FILTER (
    WHERE coverage_pct < runmap.get_completion_threshold()
  ) as incomplete_blocks,
  COUNT(*) FILTER (
    WHERE coverage_pct >= runmap.get_completion_threshold()
  ) as complete_blocks,
  SUM(total_length_m) as total_length_m,
  SUM(covered_length_m) as covered_length_m,
  ROUND((SUM(covered_length_m) / SUM(total_length_m) * 100)::numeric, 2) as overall_coverage_pct,
  COUNT(*) FILTER (
    WHERE coverage_pct >= runmap.get_completion_threshold()
  )::float / NULLIF((SELECT COUNT(*) FROM runmap.streets_blocks_32610), 0) * 100 as block_completion_pct
FROM runmap.block_coverage_32610;

-- Helper views for street-level analysis
CREATE OR REPLACE VIEW runmap.streets_most_complete AS
SELECT
  b.name,
  b.highway,
  COUNT(*) FILTER (
    WHERE COALESCE(bc.coverage_pct, 0) >= runmap.get_completion_threshold()
  ) as complete_blocks,
  COUNT(*) as total_blocks,
  ROUND(AVG(COALESCE(bc.coverage_pct, 0))::numeric, 1) as avg_coverage_pct
FROM runmap.streets_blocks_32610 b
LEFT JOIN runmap.block_coverage_32610 bc ON b.block_id = bc.block_id
WHERE b.name IS NOT NULL AND b.name != ''
GROUP BY b.name, b.highway
HAVING COUNT(*) FILTER (
  WHERE COALESCE(bc.coverage_pct, 0) >= runmap.get_completion_threshold()
) > 0
ORDER BY complete_blocks DESC, avg_coverage_pct DESC;

CREATE OR REPLACE VIEW runmap.streets_least_complete AS
SELECT
  b.name,
  b.highway,
  COUNT(*) FILTER (
    WHERE COALESCE(bc.coverage_pct, 0) >= runmap.get_completion_threshold()
  ) as complete_blocks,
  COUNT(*) as total_blocks,
  ROUND(AVG(COALESCE(bc.coverage_pct, 0))::numeric, 1) as avg_coverage_pct
FROM runmap.streets_blocks_32610 b
LEFT JOIN runmap.block_coverage_32610 bc ON b.block_id = bc.block_id
WHERE b.name IS NOT NULL AND b.name != ''
GROUP BY b.name, b.highway
HAVING COUNT(*) FILTER (
  WHERE COALESCE(bc.coverage_pct, 0) < runmap.get_completion_threshold()
) > 0
ORDER BY complete_blocks ASC, avg_coverage_pct ASC;

-- ============================================================================
-- INITIAL BUILD
-- ============================================================================

-- Rebuild coverage from all existing runs
SELECT runmap.rebuild_block_coverage();

-- Refresh materialized view
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- View current threshold
-- SELECT key, value FROM runmap.settings WHERE key = 'completion_threshold_pct';

-- View status distribution
-- SELECT status, COUNT(*) as blocks,
--   ROUND((COUNT(*)::float / (SELECT COUNT(*) FROM runmap.streets_blocks_32610) * 100)::numeric, 1) as pct_of_total
-- FROM runmap.block_coverage_32610
-- GROUP BY status;

-- View overall stats
-- SELECT * FROM runmap.coverage_stats_blocks;

-- View top streets
-- SELECT * FROM runmap.streets_most_complete LIMIT 10;
