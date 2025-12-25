#!/bin/bash
# ============================================================================
# Production Database Audit Script
# ============================================================================
# Purpose: Compare actual production database objects against documentation
# This will reveal any objects that exist in production but aren't documented
# ============================================================================

set -e

DB_HOST="192.168.68.25"
DB_USER="runmap_user"
DB_NAME="runmap"
export PGPASSWORD="fucker"

echo "========================================="
echo "Production Database Audit"
echo "========================================="
echo ""
echo "Checking what actually exists in production vs documentation..."
echo ""

# ============================================================================
# PART 1: All Functions
# ============================================================================

echo "========================================="
echo "ALL FUNCTIONS in runmap schema"
echo "========================================="
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  proname as function_name,
  pg_get_function_identity_arguments(oid) as arguments,
  CASE
    WHEN proname IN ('buffer_one_run_subdiv', 'apply_run_to_segments',
                     'auto_process_new_run_segments', 'cleanup_coverage_on_delete',
                     'detect_location', 'get_buffer_distance', 'get_completion_threshold')
    THEN '✅ DOCUMENTED'
    ELSE '⚠️  NOT IN DOCS'
  END as doc_status
FROM pg_proc
WHERE pronamespace = 'runmap'::regnamespace
ORDER BY doc_status DESC, proname;
EOF

echo ""

# ============================================================================
# PART 2: All Tables
# ============================================================================

echo "========================================="
echo "ALL TABLES in runmap schema"
echo "========================================="
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  tablename,
  CASE
    WHEN tablename IN ('runs_raw', 'walks_raw', 'cycling_raw',
                      'streets_reference', 'streets_reference_32610',
                      'streets_blocks_32610', 'runs_buffered_subdiv',
                      'block_segments', 'block_segment_visited',
                      'block_coverage_segments', 'performance_log',
                      'processing_errors', 'settings', 'aoi',
                      'streets_reference_vertices_pgr')
    THEN '✅ DOCUMENTED'
    ELSE '⚠️  NOT IN DOCS'
  END as doc_status
FROM pg_tables
WHERE schemaname = 'runmap'
ORDER BY doc_status DESC, tablename;
EOF

echo ""

# ============================================================================
# PART 3: All Views (Regular)
# ============================================================================

echo "========================================="
echo "ALL VIEWS in runmap schema"
echo "========================================="
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  viewname,
  CASE
    WHEN viewname IN ('blocks_incomplete', 'blocks_complete')
    THEN '✅ DOCUMENTED'
    ELSE '⚠️  NOT IN DOCS'
  END as doc_status
FROM pg_views
WHERE schemaname = 'runmap'
ORDER BY doc_status DESC, viewname;
EOF

echo ""

# ============================================================================
# PART 4: All Materialized Views
# ============================================================================

echo "========================================="
echo "ALL MATERIALIZED VIEWS in runmap schema"
echo "========================================="
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  matviewname,
  CASE
    WHEN matviewname IN ('coverage_stats_blocks')
    THEN '✅ DOCUMENTED'
    ELSE '⚠️  NOT IN DOCS'
  END as doc_status
FROM pg_matviews
WHERE schemaname = 'runmap'
ORDER BY doc_status DESC, matviewname;
EOF

echo ""

# ============================================================================
# PART 5: All Triggers on runs_raw
# ============================================================================

echo "========================================="
echo "ALL TRIGGERS on runs_raw table"
echo "========================================="
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  tgname as trigger_name,
  CASE
    WHEN tgname IN ('trigger_auto_process_run_segments',
                    'trigger_set_location_before_insert',
                    'trigger_cleanup_coverage_on_delete')
    THEN '✅ DOCUMENTED'
    WHEN tgname LIKE 'RI_ConstraintTrigger_%'
    THEN '✅ EXPECTED (FK)'
    ELSE '⚠️  NOT IN DOCS'
  END as doc_status,
  pg_get_triggerdef(oid) as definition
FROM pg_trigger
WHERE tgrelid = 'runmap.runs_raw'::regclass
ORDER BY doc_status DESC, tgname;
EOF

echo ""

# ============================================================================
# PART 6: Function Details for Undocumented Objects
# ============================================================================

echo "========================================="
echo "DETAIL: Functions NOT in documentation"
echo "========================================="
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  proname as function_name,
  pg_get_function_identity_arguments(oid) as arguments,
  pg_get_functiondef(oid) as full_definition
FROM pg_proc
WHERE pronamespace = 'runmap'::regnamespace
  AND proname NOT IN ('buffer_one_run_subdiv', 'apply_run_to_segments',
                      'auto_process_new_run_segments', 'cleanup_coverage_on_delete',
                      'detect_location', 'get_buffer_distance', 'get_completion_threshold')
ORDER BY proname;
EOF

echo ""

# ============================================================================
# PART 7: Check for Old System Objects
# ============================================================================

echo "========================================="
echo "CHECKING: Old system objects that should be deleted"
echo "========================================="

echo ""
echo "Old functions (should NOT exist):"
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  proname as function_name,
  pg_get_function_identity_arguments(oid) as arguments
FROM pg_proc
WHERE pronamespace = 'runmap'::regnamespace
  AND (
    proname LIKE '%chunk%' OR
    proname LIKE 'buffer_one_run' AND proname != 'buffer_one_run_subdiv' OR
    proname LIKE 'apply_run_to_coverage' OR
    proname LIKE 'apply_run_to_block_coverage' OR
    proname = 'auto_process_new_run' OR
    proname = 'set_location_on_insert' OR
    proname LIKE 'rebuild_%'
  )
ORDER BY proname;
EOF

echo ""
echo "Old tables (should NOT exist):"
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT tablename
FROM pg_tables
WHERE schemaname = 'runmap'
  AND (
    tablename LIKE '%chunk%' OR
    tablename = 'runs_buffered_32610' OR
    tablename = 'block_coverage_32610' OR
    tablename = 'block_run_coverage' OR
    tablename = 'street_coverage_32610'
  )
ORDER BY tablename;
EOF

echo ""
echo "Old views (should NOT exist):"
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT viewname
FROM pg_views
WHERE schemaname = 'runmap'
  AND (
    viewname LIKE 'streets_%' OR
    viewname LIKE 'chunks_%'
  )
ORDER BY viewname;
EOF

echo ""

# ============================================================================
# PART 8: Verify Current System is Complete
# ============================================================================

echo "========================================="
echo "VERIFICATION: Current segment-visited system"
echo "========================================="

echo ""
echo "Segment-visited tables (should all exist):"
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  t.expected_table,
  CASE WHEN pt.tablename IS NOT NULL THEN '✅ EXISTS' ELSE '❌ MISSING' END as status,
  COALESCE(pg_size_pretty(pg_total_relation_size('runmap.' || t.expected_table)), 'N/A') as size
FROM (VALUES
  ('runs_buffered_subdiv'),
  ('block_segments'),
  ('block_segment_visited'),
  ('block_coverage_segments')
) AS t(expected_table)
LEFT JOIN pg_tables pt ON pt.schemaname = 'runmap' AND pt.tablename = t.expected_table
ORDER BY t.expected_table;
EOF

echo ""
echo "Segment-visited functions (should all exist):"
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  t.expected_function,
  CASE WHEN pp.proname IS NOT NULL THEN '✅ EXISTS' ELSE '❌ MISSING' END as status
FROM (VALUES
  ('buffer_one_run_subdiv'),
  ('apply_run_to_segments'),
  ('auto_process_new_run_segments'),
  ('cleanup_coverage_on_delete')
) AS t(expected_function)
LEFT JOIN pg_proc pp ON pp.pronamespace = 'runmap'::regnamespace AND pp.proname = t.expected_function
ORDER BY t.expected_function;
EOF

echo ""
echo "Segment-visited views (should all exist):"
psql -U $DB_USER -h $DB_HOST -d $DB_NAME << 'EOF'
SELECT
  t.expected_view,
  CASE WHEN pv.viewname IS NOT NULL THEN '✅ EXISTS'
       WHEN pm.matviewname IS NOT NULL THEN '✅ EXISTS (MATVIEW)'
       ELSE '❌ MISSING' END as status
FROM (VALUES
  ('blocks_incomplete'),
  ('blocks_complete'),
  ('coverage_stats_blocks')
) AS t(expected_view)
LEFT JOIN pg_views pv ON pv.schemaname = 'runmap' AND pv.viewname = t.expected_view
LEFT JOIN pg_matviews pm ON pm.schemaname = 'runmap' AND pm.matviewname = t.expected_view
ORDER BY t.expected_view;
EOF

echo ""

# ============================================================================
# SUMMARY
# ============================================================================

echo "========================================="
echo "AUDIT COMPLETE"
echo "========================================="
echo ""
echo "Review the output above for:"
echo "  ⚠️  NOT IN DOCS - Objects that exist but aren't documented"
echo "  ❌ MISSING - Expected objects that don't exist"
echo ""
echo "These may indicate:"
echo "  1. Manually created objects not in schema files"
echo "  2. Documentation errors"
echo "  3. Incomplete cleanup from old systems"
echo ""
