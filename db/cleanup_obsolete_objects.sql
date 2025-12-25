-- ============================================================================
-- Database Cleanup Script - Remove Obsolete Objects
-- ============================================================================
-- Purpose: Remove functions, views, and tables from old coverage systems
-- Safe to run: Only drops objects that are NOT used by segment-visited system
--
-- BEFORE RUNNING:
-- 1. Backup your database: pg_dump runmap > backup_before_cleanup.sql
-- 2. Review this script carefully
-- 3. Test on a copy of the database first if possible
--
-- Date: 2025-11-18
-- ============================================================================

-- Safety check: Verify we're connected to the right database
SELECT current_database() as database,
       (SELECT COUNT(*) FROM runmap.runs_raw) as runs_count,
       (SELECT COUNT(*) FROM runmap.block_segments) as segments_exist;

-- If segment-visited system is NOT deployed, STOP HERE!
-- Expected: segments_exist > 0 (should be ~50,000+ segments)

\echo ''
\echo '========================================='
\echo 'Database Cleanup - Obsolete Objects'
\echo '========================================='
\echo ''

-- ============================================================================
-- PART 1: Obsolete Functions (Old Coverage Systems)
-- ============================================================================

\echo 'Dropping obsolete functions from old coverage systems...'
\echo ''

-- Very old chunk-based system
DROP FUNCTION IF EXISTS runmap.apply_run_to_chunk_coverage(bigint) CASCADE;
DROP FUNCTION IF EXISTS runmap.apply_run_to_chunk_coverage(uuid) CASCADE;

-- Old incremental/block-percentage system
DROP FUNCTION IF EXISTS runmap.apply_run_to_coverage(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.apply_run_to_block_coverage(uuid) CASCADE;

-- Old buffer function (replaced by buffer_one_run_subdiv)
DROP FUNCTION IF EXISTS runmap.buffer_one_run(uuid) CASCADE;
DROP FUNCTION IF EXISTS runmap.buffer_one_run(bigint) CASCADE;

-- Old processing functions (if they exist)
DROP FUNCTION IF EXISTS runmap.auto_process_new_run() CASCADE;
DROP FUNCTION IF EXISTS runmap.set_location_on_insert() CASCADE;

-- NOTE: DO NOT drop these functions - they are part of the current system:
--   - auto_process_new_run_segments()
--   - cleanup_coverage_on_delete()
--   - buffer_one_run_subdiv()
--   - apply_run_to_segments()

-- Old rebuild functions
DROP FUNCTION IF EXISTS runmap.rebuild_block_coverage() CASCADE;
DROP FUNCTION IF EXISTS runmap.rebuild_chunk_coverage() CASCADE;

-- Old chunk subdivision function
DROP FUNCTION IF EXISTS runmap.subdivide_blocks_to_chunks(float8) CASCADE;

-- Old reset function (references obsolete tables: runs_buffered_32610, block_coverage_32610, block_run_coverage)
DROP FUNCTION IF EXISTS runmap.reset_coverage_processing() CASCADE;

-- Unused variable buffer functions (user confirmed not needed)
DROP FUNCTION IF EXISTS runmap.get_buffer_config() CASCADE;
DROP FUNCTION IF EXISTS runmap.set_buffer_distance(text, float8) CASCADE;

\echo 'Obsolete functions dropped.'
\echo ''

-- ============================================================================
-- PART 2: Obsolete Views (Old Coverage Systems)
-- ============================================================================

\echo 'Dropping obsolete views from old coverage systems...'
\echo ''

-- NOTE: streets_unrun, streets_partial, streets_complete are NOT obsolete!
-- They are part of the current segment-visited system and query block_coverage_segments.
-- DO NOT DROP THEM.

-- Old chunk-based views (if they exist)
DROP VIEW IF EXISTS runmap.chunks_incomplete CASCADE;
DROP VIEW IF EXISTS runmap.chunks_complete CASCADE;

-- Old utility views that may be obsolete
DROP VIEW IF EXISTS runmap.streets_most_complete CASCADE;
DROP VIEW IF EXISTS runmap.streets_least_complete CASCADE;

\echo 'Obsolete views dropped.'
\echo ''

-- ============================================================================
-- PART 3: Obsolete Materialized Views
-- ============================================================================

\echo 'Dropping obsolete materialized views...'
\echo ''

-- Old coverage stats (replaced by coverage_stats_blocks)
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats CASCADE;
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats_chunks CASCADE;

\echo 'Obsolete materialized views dropped.'
\echo ''

-- ============================================================================
-- PART 4: Obsolete Tables (Old Coverage Systems)
-- ============================================================================

\echo 'Checking for obsolete tables...'
\echo ''

-- Old chunk-based tables
DROP TABLE IF EXISTS runmap.streets_chunks_32610 CASCADE;
DROP TABLE IF EXISTS runmap.chunk_coverage_32610 CASCADE;

-- Old block-percentage tables (should not exist, but just in case)
DROP TABLE IF EXISTS runmap.block_coverage_32610 CASCADE;
DROP TABLE IF EXISTS runmap.block_run_coverage CASCADE;

-- Old buffer tables (replaced by runs_buffered_subdiv)
DROP TABLE IF EXISTS runmap.runs_buffered_32610 CASCADE;

-- Old street coverage table (if it exists)
DROP TABLE IF EXISTS runmap.street_coverage_32610 CASCADE;

\echo 'Obsolete tables dropped (if they existed).'
\echo ''

-- ============================================================================
-- PART 5: Obsolete Triggers
-- ============================================================================

\echo 'Dropping obsolete triggers...'
\echo ''

-- Old trigger (replaced by trigger_auto_process_run_segments)
DROP TRIGGER IF EXISTS trigger_auto_process_run ON runmap.runs_raw;

-- NOTE: DO NOT drop these triggers - they are part of the current system:
--   - trigger_auto_process_run_segments (current auto-processing)
--   - trigger_set_location_before_insert (current location detection)
--   - trigger_cleanup_coverage_on_delete (current cleanup on delete)

\echo 'Obsolete triggers dropped (if they existed).'
\echo ''

-- ============================================================================
-- PART 6: Verification - What's Left?
-- ============================================================================

\echo ''
\echo '========================================='
\echo 'Cleanup Complete - Verification'
\echo '========================================='
\echo ''

\echo 'Current functions (should only be segment-visited system):'
SELECT proname as function_name,
       pg_get_function_identity_arguments(oid) as arguments
FROM pg_proc
WHERE pronamespace = 'runmap'::regnamespace
  AND proname LIKE '%buffer%' OR proname LIKE '%apply%'
ORDER BY proname;

\echo ''
\echo 'Current views:'
SELECT viewname FROM pg_views WHERE schemaname = 'runmap' ORDER BY viewname;

\echo ''
\echo 'Current materialized views:'
SELECT matviewname FROM pg_matviews WHERE schemaname = 'runmap' ORDER BY matviewname;

\echo ''
\echo 'Current triggers on runs_raw:'
SELECT tgname as trigger_name,
       pg_get_triggerdef(oid) as definition
FROM pg_trigger
WHERE tgrelid = 'runmap.runs_raw'::regclass
ORDER BY tgname;

\echo ''
\echo '========================================='
\echo 'Cleanup Summary'
\echo '========================================='
\echo ''
\echo 'The following objects should remain:'
\echo ''
\echo 'TABLES:'
\echo '  - runs_raw, walks_raw, cycling_raw'
\echo '  - streets_reference, streets_reference_32610'
\echo '  - streets_blocks_32610'
\echo '  - runs_buffered_subdiv (current system)'
\echo '  - block_segments (current system)'
\echo '  - block_segment_visited (current system)'
\echo '  - block_coverage_segments (current system)'
\echo '  - performance_log, processing_errors'
\echo '  - settings, aoi'
\echo ''
\echo 'FUNCTIONS:'
\echo '  - buffer_one_run_subdiv(uuid)'
\echo '  - apply_run_to_segments(uuid)'
\echo '  - auto_process_new_run_segments()'
\echo '  - detect_location(geometry)'
\echo '  - get_buffer_distance()'
\echo ''
\echo 'VIEWS:'
\echo '  - streets_unrun (<5% coverage)'
\echo '  - streets_partial (5-75% coverage)'
\echo '  - streets_complete (>=75% coverage)'
\echo '  + utility views: activity_stats, all_activities, blocks_per_street, blocks_stats, failed_runs'
\echo ''
\echo 'MATERIALIZED VIEWS:'
\echo '  - coverage_stats_blocks'
\echo ''
\echo 'TRIGGERS:'
\echo '  - trigger_auto_process_run_segments'
\echo '  - trigger_set_location_before_insert'
\echo '  - trigger_cleanup_coverage_on_delete'
\echo ''
\echo 'If you see anything else (except RI_ConstraintTrigger_*), it may be obsolete.'
\echo ''
\echo '========================================='
\echo 'Done!'
\echo '========================================='
