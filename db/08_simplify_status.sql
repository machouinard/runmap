-- ============================================================================
-- Simplify Status System: Complete vs Incomplete
-- ============================================================================
-- Combines "partial" and "unrun" into single "incomplete" status
-- Rationale: Partial chunks (5-90% coverage) are mostly intersection crossings
--            that don't provide useful information about what needs to be run.
--            Only chunks with ≥90% coverage are meaningfully "done".
-- ============================================================================

-- Drop existing views
DROP VIEW IF EXISTS runmap.chunks_complete CASCADE;
DROP VIEW IF EXISTS runmap.chunks_partial CASCADE;
DROP VIEW IF EXISTS runmap.chunks_unrun CASCADE;

-- Drop and recreate chunk_coverage_32610 with simplified status
-- Note: Can't reference generated column coverage_pct in another generated column,
-- so we recalculate the percentage inline
ALTER TABLE runmap.chunk_coverage_32610
  DROP COLUMN IF EXISTS status CASCADE;

ALTER TABLE runmap.chunk_coverage_32610
  ADD COLUMN status TEXT GENERATED ALWAYS AS (
    CASE
      WHEN total_length_m > 0 AND (covered_length_m / total_length_m * 100) >= 90 THEN 'complete'
      ELSE 'incomplete'
    END
  ) STORED;

-- Create simplified views
CREATE OR REPLACE VIEW runmap.chunks_incomplete AS
SELECT
  c.chunk_id,
  s.name,
  s.highway,
  s.geom_32610,
  c.coverage_pct,
  c.covered_length_m,
  c.total_length_m
FROM runmap.chunk_coverage_32610 c
JOIN runmap.streets_chunks_32610 s ON c.chunk_id = s.chunk_id
WHERE c.coverage_pct < 90;

CREATE OR REPLACE VIEW runmap.chunks_complete AS
SELECT
  c.chunk_id,
  s.name,
  s.highway,
  s.geom_32610,
  c.coverage_pct,
  c.covered_length_m,
  c.total_length_m
FROM runmap.chunk_coverage_32610 c
JOIN runmap.streets_chunks_32610 s ON c.chunk_id = s.chunk_id
WHERE c.coverage_pct >= 90;

-- Update coverage stats view
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats_chunks;

CREATE MATERIALIZED VIEW runmap.coverage_stats_chunks AS
SELECT
  COUNT(*) as total_chunks,
  COUNT(*) FILTER (WHERE coverage_pct < 90) as incomplete_chunks,
  COUNT(*) FILTER (WHERE coverage_pct >= 90) as complete_chunks,
  SUM(total_length_m) as total_length_m,
  SUM(covered_length_m) as covered_length_m,
  ROUND((SUM(covered_length_m) / SUM(total_length_m) * 100)::numeric, 2) as overall_coverage_pct,
  COUNT(DISTINCT chunk_id) FILTER (WHERE coverage_pct >= 90)::float / COUNT(DISTINCT chunk_id) * 100 as chunk_completion_pct
FROM runmap.chunk_coverage_32610;

-- Add index on status for better query performance
CREATE INDEX IF NOT EXISTS idx_chunk_coverage_status
  ON runmap.chunk_coverage_32610 ((
    CASE WHEN coverage_pct >= 90 THEN 'complete' ELSE 'incomplete' END
  ));

-- Refresh the materialized view
REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;

-- Recreate dependent views that were dropped
CREATE OR REPLACE VIEW runmap.streets_most_complete AS
SELECT
  s.name,
  s.highway,
  COUNT(*) FILTER (WHERE c.status = 'complete') as complete_chunks,
  COUNT(*) as total_chunks,
  ROUND(AVG(c.coverage_pct)::numeric, 1) as avg_coverage_pct
FROM runmap.streets_chunks_32610 s
JOIN runmap.chunk_coverage_32610 c ON s.chunk_id = c.chunk_id
WHERE s.name IS NOT NULL AND s.name != ''
GROUP BY s.name, s.highway
HAVING COUNT(*) FILTER (WHERE c.status = 'complete') > 0
ORDER BY complete_chunks DESC, avg_coverage_pct DESC;

CREATE OR REPLACE VIEW runmap.streets_least_complete AS
SELECT
  s.name,
  s.highway,
  COUNT(*) FILTER (WHERE c.status = 'complete') as complete_chunks,
  COUNT(*) as total_chunks,
  ROUND(AVG(c.coverage_pct)::numeric, 1) as avg_coverage_pct
FROM runmap.streets_chunks_32610 s
JOIN runmap.chunk_coverage_32610 c ON s.chunk_id = c.chunk_id
WHERE s.name IS NOT NULL AND s.name != ''
GROUP BY s.name, s.highway
HAVING COUNT(*) FILTER (WHERE c.status = 'incomplete') > 0
ORDER BY complete_chunks ASC, avg_coverage_pct ASC;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- View new status distribution
-- SELECT status, COUNT(*) FROM runmap.chunk_coverage_32610 GROUP BY status;

-- Check stats
-- SELECT * FROM runmap.coverage_stats_chunks;
