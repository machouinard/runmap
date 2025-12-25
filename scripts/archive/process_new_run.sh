#!/bin/bash
# Process a single new GPX run incrementally
# Usage: bash process_new_run.sh path/to/run.gpx

set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <path/to/run.gpx>"
  exit 1
fi

GPX_FILE="$1"

if [ ! -f "$GPX_FILE" ]; then
  echo "Error: File not found: $GPX_FILE"
  exit 1
fi

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Process New Run"
echo "======================================"
echo "GPX File: $GPX_FILE"
echo ""

# 1. Ingest GPX to database
echo "1. Importing GPX to database..."
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$PROJECT_ROOT/scripts/ingest_gpx.sh" "$GPX_FILE"

# 2. Get the newly inserted run ID
echo "2. Getting run ID..."
RUN_ID=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
  "SELECT id FROM runmap.runs_raw ORDER BY uploaded_at DESC LIMIT 1;")
echo "   Run ID: $RUN_ID"

# 3. Create buffer for this run
echo "3. Creating buffer..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \
  "SELECT runmap.buffer_one_run('$RUN_ID'::uuid);" > /dev/null

# 4. Apply run to block coverage
echo "4. Updating block coverage..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \
  "SELECT runmap.apply_run_to_block_coverage('$RUN_ID'::uuid);" > /dev/null

# 5. Refresh coverage stats
echo "5. Refreshing coverage statistics..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \
  "REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;" > /dev/null

# 6. Show updated stats
echo ""
echo "======================================"
echo "Updated Coverage Statistics"
echo "======================================"
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
SELECT
  total_blocks,
  complete_blocks,
  ROUND(block_completion_pct::numeric, 1) as completion_pct,
  ROUND(overall_coverage_pct::numeric, 1) as distance_pct
FROM runmap.coverage_stats_blocks;
EOF

echo ""
echo "======================================"
echo "Processing Complete!"
echo "======================================"
echo ""
echo "Next step: Export tiles"
echo "  bash scripts/export_tiles_blocks.sh"
echo ""
