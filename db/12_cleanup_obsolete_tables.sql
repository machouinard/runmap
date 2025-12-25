-- ============================================================================
-- Database Cleanup: Remove Obsolete Tables
-- ============================================================================
-- Created: 2025-10-20
-- Purpose: Remove tables from previous coverage system iterations
--
-- Background:
-- The system evolved through several approaches:
--   1. Street-level coverage with geometry unions (street_coverage_32610)
--   2. Block-level with single buffers (runs_buffered_32610, block_coverage_32610)
--   3. Junction table approach (block_run_coverage)
--   4. Current: Segment-visited with subdivided buffers (67x faster)
--
-- This migration removes tables from approaches 1-3.
-- ============================================================================

\echo '======================================'
\echo 'Database Cleanup: Obsolete Tables'
\echo '======================================'
\echo ''

-- ============================================================================
-- SAFETY CHECK: Verify current system is active
-- ============================================================================

DO $$
DECLARE
  v_subdiv_count INTEGER;
  v_segments_count INTEGER;
  v_visited_count INTEGER;
BEGIN
  -- Check that new system has data
  SELECT COUNT(*) INTO v_subdiv_count FROM runmap.runs_buffered_subdiv;
  SELECT COUNT(*) INTO v_segments_count FROM runmap.block_segments;
  SELECT COUNT(*) INTO v_visited_count FROM runmap.block_segment_visited;

  IF v_subdiv_count = 0 OR v_segments_count = 0 OR v_visited_count = 0 THEN
    RAISE EXCEPTION 'ERROR: New segment-visited system appears empty! Aborting cleanup for safety.';
  END IF;

  RAISE NOTICE '✓ Safety check passed:';
  RAISE NOTICE '  - runs_buffered_subdiv: % rows', v_subdiv_count;
  RAISE NOTICE '  - block_segments: % rows', v_segments_count;
  RAISE NOTICE '  - block_segment_visited: % rows', v_visited_count;
END $$;

\echo ''
\echo 'Analyzing obsolete tables...'
\echo ''

-- Show what we're about to delete
SELECT
  'runs_buffered_32610' as table_name,
  COUNT(*) as row_count,
  pg_size_pretty(pg_total_relation_size('runmap.runs_buffered_32610')) as size,
  'Old single-buffer approach' as reason
FROM runmap.runs_buffered_32610
UNION ALL
SELECT
  'block_coverage_32610',
  COUNT(*),
  pg_size_pretty(pg_total_relation_size('runmap.block_coverage_32610')),
  'Old geometry-union approach'
FROM runmap.block_coverage_32610
UNION ALL
SELECT
  'block_run_coverage',
  COUNT(*),
  pg_size_pretty(pg_total_relation_size('runmap.block_run_coverage')),
  'Intermediate junction table'
FROM runmap.block_run_coverage
UNION ALL
SELECT
  'street_coverage_32610',
  COUNT(*),
  pg_size_pretty(pg_total_relation_size('runmap.street_coverage_32610')),
  'Pre-block-splitting system'
FROM runmap.street_coverage_32610;

\echo ''
\echo 'Dropping obsolete tables...'
\echo ''

-- ============================================================================
-- DROP OBSOLETE TABLES
-- ============================================================================

-- 1. Street-level coverage (pre-block-splitting era)
\echo '1. Dropping street_coverage_32610...'
DROP TABLE IF EXISTS runmap.street_coverage_32610 CASCADE;

-- 2. Old block coverage with geometry unions
\echo '2. Dropping block_coverage_32610...'
DROP TABLE IF EXISTS runmap.block_coverage_32610 CASCADE;

-- 3. Junction table approach
\echo '3. Dropping block_run_coverage...'
DROP TABLE IF EXISTS runmap.block_run_coverage CASCADE;

-- 4. Old single-buffer runs
\echo '4. Dropping runs_buffered_32610...'
DROP TABLE IF EXISTS runmap.runs_buffered_32610 CASCADE;

\echo ''
\echo '======================================'
\echo 'Cleanup Complete!'
\echo '======================================'
\echo ''
\echo 'Obsolete tables removed:'
\echo '  ✓ street_coverage_32610 (pre-block-splitting)'
\echo '  ✓ block_coverage_32610 (geometry-union approach)'
\echo '  ✓ block_run_coverage (junction table approach)'
\echo '  ✓ runs_buffered_32610 (single-buffer approach)'
\echo ''
\echo 'Active system remains intact:'
\echo '  ✓ runs_buffered_subdiv (subdivided buffers)'
\echo '  ✓ block_segments (5m segments)'
\echo '  ✓ block_segment_visited (visited flags)'
\echo '  ✓ block_coverage_segments (precomputed %)'
\echo ''

-- ============================================================================
-- VERIFICATION
-- ============================================================================

\echo 'Current database size:'
SELECT
  schemaname,
  pg_size_pretty(SUM(pg_total_relation_size(schemaname||'.'||tablename))::bigint) as total_size
FROM pg_tables
WHERE schemaname = 'runmap'
GROUP BY schemaname;

\echo ''
\echo 'Active coverage tables:'
SELECT
  tablename,
  pg_size_pretty(pg_total_relation_size('runmap.'||tablename)) as size
FROM pg_tables
WHERE schemaname = 'runmap'
  AND tablename IN ('runs_buffered_subdiv', 'block_segments', 'block_segment_visited', 'block_coverage_segments')
ORDER BY pg_total_relation_size('runmap.'||tablename) DESC;

\echo ''
\echo '======================================'
\echo 'Next Steps:'
\echo '======================================'
\echo '1. Update scripts that reference old tables'
\echo '2. Update CLAUDE.md documentation'
\echo '3. Remove obsolete .sql files from db/ directory'
\echo ''
