#!/bin/bash
# Delete N most recent Sacramento runs for testing purposes
# This creates test data for upload workflow validation
# Usage: ./delete_recent_runs.sh [N]  (default: 20)

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_NAME=${DB_NAME:-runmap}
DB_USER=${DB_USER:-runmap_user}

# Number of runs to delete (default 20)
NUM_RUNS=${1:-20}

echo "========================================"
echo "Deleting $NUM_RUNS Most Recent Sacramento Runs"
echo "========================================"
echo ""

# Store run IDs to temp file for reference
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << EOF > /tmp/deleted_runs.txt
-- Get N most recent Sacramento runs BY RUN DATE (not upload date)
SELECT id, filename, start_time
FROM runmap.runs_raw
WHERE location = 'sacramento'
ORDER BY start_time DESC
LIMIT $NUM_RUNS;
EOF

echo "Runs to be deleted:"
cat /tmp/deleted_runs.txt
echo ""

# Delete the runs (cascades to buffers, coverage will be rebuilt)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << EOF
-- Store IDs in temp table
CREATE TEMP TABLE runs_to_delete AS
SELECT id
FROM runmap.runs_raw
WHERE location = 'sacramento'
ORDER BY start_time DESC
LIMIT $NUM_RUNS;

-- Delete buffers for these runs
DELETE FROM runmap.runs_buffered_subdiv
WHERE run_id IN (SELECT id FROM runs_to_delete);

-- Delete the runs themselves
DELETE FROM runmap.runs_raw
WHERE id IN (SELECT id FROM runs_to_delete);

-- Show count
SELECT
  (SELECT COUNT(*) FROM runs_to_delete) as deleted_count,
  (SELECT COUNT(*) FROM runmap.runs_raw WHERE location = 'sacramento') as remaining_sacramento_runs,
  (SELECT COUNT(*) FROM runmap.runs_raw) as total_runs;
EOF

echo ""
echo "========================================"
echo "Runs Deleted Successfully"
echo "========================================"
echo ""
echo "Now rebuilding coverage without these runs..."
echo ""

# Rebuild coverage
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
-- Rebuild block coverage
TRUNCATE runmap.block_coverage_32610;

INSERT INTO runmap.block_coverage_32610 (block_id, covered_geom, covered_length_m, total_length_m)
SELECT
  b.block_id,
  ST_Intersection(b.geom_32610, ST_Union(rb.geom)) as covered_geom,
  ST_Length(ST_Intersection(b.geom_32610, ST_Union(rb.geom))) as covered_length_m,
  b.block_length_m as total_length_m
FROM runmap.streets_blocks_32610 b
JOIN runmap.runs_buffered_32610 rb ON ST_Intersects(b.geom_32610, rb.geom)
GROUP BY b.block_id, b.block_length_m, b.geom_32610;

-- Refresh stats
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

-- Show final stats
SELECT
  total_blocks,
  incomplete_blocks,
  complete_blocks,
  ROUND(overall_coverage_pct::numeric, 2) as overall_coverage_pct,
  ROUND(block_completion_pct::numeric, 2) as block_completion_pct
FROM runmap.coverage_stats_blocks;
EOF

echo ""
echo "========================================"
echo "Coverage Rebuilt Successfully"
echo "========================================"
echo ""
echo "List of deleted runs saved to: /tmp/deleted_runs.txt"
echo "You can now re-upload these 20 GPX files for testing"
echo ""
