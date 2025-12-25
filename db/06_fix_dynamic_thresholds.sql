-- ============================================================================
-- Fix Dynamic Threshold Views
-- ============================================================================
--
-- ISSUE: Views currently use hardcoded thresholds (5%, 75%) instead of
--        the completion_threshold_pct setting.
--
-- This script:
-- 1. Ensures completion_threshold_pct setting exists (default 75)
-- 2. Updates views to use get_completion_threshold() function
-- 3. Documents how to change the threshold in the future
--
-- NOTE: After running this, you can change the threshold by updating the
--       setting and re-exporting tiles. No schema changes needed.
--
-- ============================================================================

\echo ''
\echo '========================================='
\echo 'Fixing Dynamic Threshold Views'
\echo '========================================='
\echo ''

-- Ensure completion_threshold_pct setting exists
-- Default to 75 to match current hardcoded behavior
INSERT INTO runmap.settings (key, value)
VALUES ('completion_threshold_pct', '75'::jsonb)
ON CONFLICT (key) DO NOTHING;

\echo 'Setting: completion_threshold_pct = 75% (or existing value preserved)'
\echo ''

-- Ensure get_completion_threshold() function exists
-- (should already exist from earlier migrations, but include for completeness)
CREATE OR REPLACE FUNCTION runmap.get_completion_threshold()
RETURNS FLOAT AS $$
  SELECT COALESCE((value::text)::float, 75.0)
  FROM runmap.settings
  WHERE key = 'completion_threshold_pct';
$$ LANGUAGE sql STABLE;

\echo 'Function: get_completion_threshold() ready'
\echo ''

-- ============================================================================
-- Update Views to Use Dynamic Threshold
-- ============================================================================

\echo 'Updating views to use dynamic threshold...'
\echo ''

-- Streets with <5% coverage (always hardcoded, represents "truly unrun")
-- This threshold should stay at 5% to distinguish "never touched" from "started"
DROP VIEW IF EXISTS runmap.streets_unrun CASCADE;
CREATE VIEW runmap.streets_unrun AS
SELECT
  b.block_id,
  b.name,
  b.highway,
  b.geom_32610,
  b.block_length_m,
  COALESCE(bcs.coverage_pct, 0::double precision) AS coverage_pct
FROM runmap.streets_blocks_32610 b
LEFT JOIN runmap.block_coverage_segments bcs USING (block_id)
WHERE COALESCE(bcs.coverage_pct, 0::double precision) < 5::double precision;

\echo '  ✓ streets_unrun (<5% coverage, grey) - hardcoded threshold'

-- Streets with 5% to completion_threshold (partial coverage)
DROP VIEW IF EXISTS runmap.streets_partial CASCADE;
CREATE VIEW runmap.streets_partial AS
SELECT
  b.block_id,
  b.name,
  b.highway,
  b.geom_32610,
  b.block_length_m,
  bcs.coverage_pct
FROM runmap.streets_blocks_32610 b
JOIN runmap.block_coverage_segments bcs USING (block_id)
WHERE bcs.coverage_pct >= 5::double precision
  AND bcs.coverage_pct < runmap.get_completion_threshold();

\echo '  ✓ streets_partial (5% to threshold, purple) - uses get_completion_threshold()'

-- Streets with coverage >= completion_threshold (complete)
DROP VIEW IF EXISTS runmap.streets_complete CASCADE;
CREATE VIEW runmap.streets_complete AS
SELECT
  b.block_id,
  b.name,
  b.highway,
  b.geom_32610,
  b.block_length_m,
  bcs.coverage_pct
FROM runmap.streets_blocks_32610 b
JOIN runmap.block_coverage_segments bcs USING (block_id)
WHERE bcs.coverage_pct >= runmap.get_completion_threshold();

\echo '  ✓ streets_complete (>=threshold, green) - uses get_completion_threshold()'
\echo ''

-- ============================================================================
-- Verify Setup
-- ============================================================================

\echo 'Current configuration:'
\echo ''
SELECT
  '  Completion threshold: ' ||
  COALESCE((value::text)::float, 75.0)::text || '%'
FROM runmap.settings
WHERE key = 'completion_threshold_pct';

\echo ''
\echo '========================================='
\echo 'Migration Complete!'
\echo '========================================='
\echo ''
\echo 'HOW TO CHANGE THRESHOLD IN THE FUTURE:'
\echo ''
\echo '1. Update the setting:'
\echo '   UPDATE runmap.settings SET value = ''85''::jsonb'
\echo '   WHERE key = ''completion_threshold_pct'';'
\echo ''
\echo '2. Refresh materialized view:'
\echo '   REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;'
\echo ''
\echo '3. Re-export tiles:'
\echo '   bash scripts/export_tiles_blocks.sh'
\echo ''
\echo '4. Update tiles version to invalidate browser caches:'
\echo '   UPDATE runmap.settings SET value = to_jsonb(extract(epoch from now())::bigint)'
\echo '   WHERE key = ''tiles_version'';'
\echo ''
\echo 'The views will automatically use the new threshold!'
\echo ''
