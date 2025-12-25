-- ============================================================================
-- Utility Views for RunMap
-- ============================================================================
--
-- This file contains convenience views for querying activity data, coverage
-- statistics, and processing status. These views are useful for debugging,
-- dashboards, and data analysis.
--
-- Created: 2025-11-18 (exported from production)
-- ============================================================================

\echo ''
\echo '========================================='
\echo 'Creating Utility Views'
\echo '========================================='
\echo ''

-- ============================================================================
-- PART 1: Activity Views
-- ============================================================================

-- All activities combined (runs, walks, cycling)
DROP VIEW IF EXISTS runmap.all_activities CASCADE;
CREATE VIEW runmap.all_activities AS
SELECT
  id,
  filename,
  uploaded_at,
  geom,
  workout_hash,
  'run'::text AS activity_type,
  NULL::double precision AS avg_pace_min_per_mile,
  NULL::double precision AS avg_speed_mph,
  NULL::double precision AS total_distance_m,
  NULL::integer AS duration_seconds
FROM runmap.runs_raw
UNION ALL
SELECT
  id,
  filename,
  uploaded_at,
  geom,
  workout_hash,
  'walk'::text AS activity_type,
  avg_pace_min_per_mile,
  NULL::double precision AS avg_speed_mph,
  total_distance_m,
  duration_seconds
FROM runmap.walks_raw
UNION ALL
SELECT
  id,
  filename,
  uploaded_at,
  geom,
  workout_hash,
  'cycle'::text AS activity_type,
  NULL::double precision AS avg_pace_min_per_mile,
  avg_speed_mph,
  total_distance_m,
  duration_seconds
FROM runmap.cycling_raw;

ALTER TABLE runmap.all_activities OWNER TO runmap_user;
COMMENT ON VIEW runmap.all_activities IS 'Union of all activity types (runs, walks, cycling) for unified queries';

\echo '  ✓ all_activities - Union of runs, walks, cycling'

-- Activity statistics summary
DROP VIEW IF EXISTS runmap.activity_stats CASCADE;
CREATE VIEW runmap.activity_stats AS
SELECT
  activity_type,
  COUNT(*) AS total_count,
  SUM(total_distance_m) / 1609.34 AS total_miles,
  SUM(duration_seconds)::numeric / 3600.0 AS total_hours
FROM (
  SELECT
    'run'::text AS activity_type,
    NULL::double precision AS total_distance_m,
    NULL::integer AS duration_seconds
  FROM runmap.runs_raw
  UNION ALL
  SELECT
    'walk'::text,
    total_distance_m,
    duration_seconds
  FROM runmap.walks_raw
  UNION ALL
  SELECT
    'cycle'::text,
    total_distance_m,
    duration_seconds
  FROM runmap.cycling_raw
) combined
GROUP BY activity_type
ORDER BY activity_type;

ALTER TABLE runmap.activity_stats OWNER TO runmap_user;
COMMENT ON VIEW runmap.activity_stats IS 'Summary statistics for each activity type (count, total miles, total hours)';

\echo '  ✓ activity_stats - Statistics by activity type'

-- ============================================================================
-- PART 2: Processing Status Views
-- ============================================================================

-- Failed/pending runs with error details
DROP VIEW IF EXISTS runmap.failed_runs CASCADE;
CREATE VIEW runmap.failed_runs AS
SELECT
  r.id,
  r.filename,
  r.start_time,
  r.total_distance_m,
  r.location,
  r.uploaded_at,
  r.processing_started_at,
  r.processing_status,
  pe.error_message,
  pe.error_type,
  pe.retry_count,
  pe.occurred_at AS last_error_at
FROM runmap.runs_raw r
LEFT JOIN LATERAL (
  SELECT
    error_type,
    error_message,
    retry_count,
    occurred_at
  FROM runmap.processing_errors
  WHERE run_id = r.id
  ORDER BY occurred_at DESC
  LIMIT 1
) pe ON true
WHERE r.processing_status IN ('failed', 'pending')
ORDER BY r.uploaded_at DESC;

ALTER TABLE runmap.failed_runs OWNER TO runmap_user;
COMMENT ON VIEW runmap.failed_runs IS 'Lists all runs that failed processing with their most recent error details';

\echo '  ✓ failed_runs - Debugging view for failed processing'

-- ============================================================================
-- PART 3: Block/Street Analysis Views
-- ============================================================================

-- Block statistics summary
DROP VIEW IF EXISTS runmap.blocks_stats CASCADE;
CREATE VIEW runmap.blocks_stats AS
SELECT
  COUNT(*) AS total_blocks,
  ROUND(AVG(block_length_m)::numeric, 1) AS avg_length_m,
  ROUND(MIN(block_length_m)::numeric, 1) AS min_length_m,
  ROUND(MAX(block_length_m)::numeric, 1) AS max_length_m,
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY block_length_m)::numeric, 1) AS median_length_m,
  COUNT(*) FILTER (WHERE block_length_m > 200) AS blocks_over_200m,
  COUNT(*) FILTER (WHERE block_length_m > 100) AS blocks_over_100m,
  COUNT(*) FILTER (WHERE block_length_m > 50) AS blocks_over_50m
FROM runmap.streets_blocks_32610;

ALTER TABLE runmap.blocks_stats OWNER TO runmap_user;
COMMENT ON VIEW runmap.blocks_stats IS 'Statistical summary of block lengths (used for analyzing segmentation quality)';

\echo '  ✓ blocks_stats - Block length statistics'

-- Blocks per street name
DROP VIEW IF EXISTS runmap.blocks_per_street CASCADE;
CREATE VIEW runmap.blocks_per_street AS
SELECT
  s.ogc_fid,
  s.name,
  s.highway,
  s.total_length_m AS original_length_m,
  COUNT(b.block_id) AS num_blocks,
  ROUND(AVG(b.block_length_m)::numeric, 1) AS avg_block_length_m
FROM runmap.streets_reference_32610 s
LEFT JOIN runmap.streets_blocks_32610 b ON b.parent_ogc_fid = s.ogc_fid
GROUP BY s.ogc_fid, s.name, s.highway, s.total_length_m
ORDER BY COUNT(b.block_id) DESC;

ALTER TABLE runmap.blocks_per_street OWNER TO runmap_user;
COMMENT ON VIEW runmap.blocks_per_street IS 'Shows how many blocks each street was segmented into (useful for coverage planning)';

\echo '  ✓ blocks_per_street - Block segmentation by street'

-- ============================================================================
-- Complete
-- ============================================================================

\echo ''
\echo '========================================='
\echo 'Utility Views Created'
\echo '========================================='
\echo ''
\echo 'Available utility views:'
\echo '  - all_activities: Union of runs, walks, cycling'
\echo '  - activity_stats: Summary statistics by activity type'
\echo '  - failed_runs: Debugging view for failed processing'
\echo '  - blocks_stats: Block length statistics'
\echo '  - blocks_per_street: Block segmentation by street name'
\echo ''
\echo 'Usage examples:'
\echo ''
\echo '  -- Check activity totals'
\echo '  SELECT * FROM runmap.activity_stats;'
\echo ''
\echo '  -- Find failed uploads'
\echo '  SELECT filename, error_message FROM runmap.failed_runs LIMIT 10;'
\echo ''
\echo '  -- Analyze block segmentation'
\echo '  SELECT * FROM runmap.blocks_stats;'
\echo ''
