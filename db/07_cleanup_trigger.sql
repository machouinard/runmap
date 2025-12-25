-- ============================================================================
-- Cleanup Trigger for Run Deletion
-- ============================================================================
--
-- This trigger ensures coverage data remains accurate when runs are deleted.
-- When a run is removed, the trigger:
-- 1. Identifies segments affected by the deleted run's buffer
-- 2. Rechecks if those segments are still visited by OTHER runs
-- 3. Updates segment visited flags accordingly
-- 4. Recalculates block coverage for affected blocks
-- 5. Refreshes coverage statistics materialized view
--
-- Created: Extracted from production 2025-11-18
-- System: Segment-visited coverage (current)
-- ============================================================================

\echo ''
\echo '========================================='
\echo 'Creating Cleanup Coverage Trigger'
\echo '========================================='
\echo ''

-- ============================================================================
-- Cleanup Function
-- ============================================================================

DROP FUNCTION IF EXISTS runmap.cleanup_coverage_on_delete() CASCADE;

CREATE FUNCTION runmap.cleanup_coverage_on_delete()
RETURNS TRIGGER AS $$
DECLARE
  affected_segment_ids INTEGER[];
BEGIN
  -- Get list of segment IDs affected by this run's buffer
  -- Must do this BEFORE the buffer is cascade-deleted
  SELECT ARRAY_AGG(DISTINCT bs.segment_id)
  INTO affected_segment_ids
  FROM runmap.runs_buffered_subdiv rbs
  JOIN runmap.block_segments bs ON ST_Intersects(rbs.geom, bs.segment_geom)
  WHERE rbs.run_id = OLD.id;

  -- The buffer will be automatically deleted by CASCADE after this trigger

  IF affected_segment_ids IS NOT NULL AND array_length(affected_segment_ids, 1) > 0 THEN
    -- For each affected segment, check if it's still visited by any OTHER run
    -- This is more efficient than recalculating everything
    UPDATE runmap.block_segment_visited bsv
    SET visited = EXISTS (
      SELECT 1
      FROM runmap.runs_buffered_subdiv rbs
      JOIN runmap.block_segments bs ON bs.segment_id = bsv.segment_id
      WHERE ST_Intersects(rbs.geom, bs.segment_geom)
        AND rbs.run_id != OLD.id  -- Exclude the run being deleted
    )
    WHERE bsv.segment_id = ANY(affected_segment_ids);

    -- Recompute block coverage from segments
    -- Get affected blocks
    WITH affected_blocks AS (
      SELECT DISTINCT block_id
      FROM runmap.block_segments
      WHERE segment_id = ANY(affected_segment_ids)
    )
    INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
    SELECT
      bs.block_id,
      COALESCE(SUM(bs.segment_length_m) FILTER (WHERE bsv.visited), 0) as visited_length_m,
      SUM(bs.segment_length_m) as total_length_m
    FROM runmap.block_segments bs
    LEFT JOIN runmap.block_segment_visited bsv ON bs.segment_id = bsv.segment_id
    WHERE bs.block_id IN (SELECT block_id FROM affected_blocks)
    GROUP BY bs.block_id
    ON CONFLICT (block_id) DO UPDATE
    SET visited_length_m = EXCLUDED.visited_length_m,
        total_length_m = EXCLUDED.total_length_m;

    -- Refresh stats
    REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

    RAISE NOTICE 'Cleaned up coverage for % affected segments from run %',
                 array_length(affected_segment_ids, 1), OLD.id;
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql VOLATILE;

ALTER FUNCTION runmap.cleanup_coverage_on_delete() OWNER TO runmap_user;

COMMENT ON FUNCTION runmap.cleanup_coverage_on_delete() IS
  'Trigger function that recalculates segment visited flags and block coverage when a run is deleted';

\echo '  ✓ cleanup_coverage_on_delete() function'

-- ============================================================================
-- Cleanup Trigger
-- ============================================================================

DROP TRIGGER IF EXISTS trigger_cleanup_coverage_on_delete ON runmap.runs_raw;

CREATE TRIGGER trigger_cleanup_coverage_on_delete
  BEFORE DELETE ON runmap.runs_raw
  FOR EACH ROW
  EXECUTE FUNCTION runmap.cleanup_coverage_on_delete();

\echo '  ✓ trigger_cleanup_coverage_on_delete on runs_raw'

-- ============================================================================
-- Complete
-- ============================================================================

\echo ''
\echo '========================================='
\echo 'Cleanup Trigger Ready'
\echo '========================================='
\echo ''
\echo 'The cleanup trigger will now automatically:'
\echo '  1. Detect which segments were affected by deleted runs'
\echo '  2. Recheck if those segments are still visited by other runs'
\echo '  3. Update segment visited flags (may set to FALSE if no other runs)'
\echo '  4. Recalculate block coverage for affected blocks'
\echo '  5. Refresh coverage statistics materialized view'
\echo ''
\echo 'This ensures coverage data stays accurate when runs are removed.'
\echo ''
\echo 'NOTE: Deleting runs with large buffers affecting many segments'
\echo '      may take several seconds due to recalculation.'
\echo ''
