#!/bin/bash
# Rebuild all coverage from scratch
# Use this after changing buffer settings or if coverage data gets corrupted

set -e

# Load common environment configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

echo "======================================"
echo "Rebuild All Coverage"
echo "======================================"
echo ""
echo "This will:"
echo "  1. Clear all coverage data"
echo "  2. Rebuild buffers and mark visited segments"
echo "  3. Refresh statistics"
echo "  4. Export new tiles"
echo ""
echo "⚠️  WARNING: This can take 5-10 minutes"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo "======================================"
echo "Step 1: Clearing existing coverage..."
echo "======================================"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
TRUNCATE runmap.runs_buffered_subdiv;
TRUNCATE runmap.block_segment_visited;
TRUNCATE runmap.block_coverage_segments;
EOF
echo "✓ Coverage data cleared"

echo ""
echo "Re-initializing segment visited flags..."
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
-- Re-initialize visited flags for all segments (required after TRUNCATE)
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE
FROM runmap.block_segments
ON CONFLICT (segment_id) DO NOTHING;
EOF

SEGMENT_COUNT=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c \
  "SELECT COUNT(*) FROM runmap.block_segment_visited;")
echo "✓ Initialized $SEGMENT_COUNT segment flags"

echo ""
echo "Re-initializing block coverage records..."
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
-- Initialize coverage records for ALL blocks (required after TRUNCATE)
INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
SELECT block_id, 0, block_length_m
FROM runmap.streets_blocks_32610
ON CONFLICT (block_id) DO NOTHING;
EOF

BLOCK_COUNT=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c \
  "SELECT COUNT(*) FROM runmap.block_coverage_segments;")
echo "✓ Initialized $BLOCK_COUNT block coverage records"

echo ""
echo "======================================"
echo "Step 2: Rebuilding all buffers and coverage..."
echo "======================================"
echo "This may take a few minutes..."

# Get all run IDs (Sacramento only, ordered chronologically)
RUN_IDS=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -A -c \
  "SELECT id FROM runmap.runs_raw WHERE location = 'sacramento' ORDER BY start_time;")

RUN_COUNT=$(echo "$RUN_IDS" | wc -l | tr -d ' ')
echo "Found $RUN_COUNT Sacramento runs to process"
echo ""

COUNTER=0
for RUN_ID in $RUN_IDS; do
  COUNTER=$((COUNTER + 1))
  echo "[$COUNTER/$RUN_COUNT] Processing run: $RUN_ID"

  # Buffer and subdivide
  psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c \
    "SELECT runmap.buffer_one_run_subdiv('$RUN_ID'::uuid);" > /dev/null

  # Mark segments as visited
  psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c \
    "SELECT runmap.apply_run_to_segments('$RUN_ID'::uuid);" > /dev/null
done

echo ""
echo "✓ All runs processed (buffers created, segments marked)"

echo ""
echo "======================================"
echo "Step 3: Refreshing statistics..."
echo "======================================"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
EOF
echo "✓ Statistics refreshed"

# Show updated stats
echo ""
echo "======================================"
echo "Updated Coverage Statistics"
echo "======================================"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  total_blocks,
  incomplete_blocks,
  complete_blocks,
  ROUND(block_completion_pct::numeric, 1) as completion_pct,
  ROUND(overall_coverage_pct::numeric, 1) as distance_pct
FROM runmap.coverage_stats_blocks;
EOF

echo ""
echo "======================================"
echo "Step 4: Exporting tiles..."
echo "======================================"

# Get project root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Export tiles
bash "$PROJECT_ROOT/scripts/export_tiles_blocks.sh"

echo ""
echo "======================================"
echo "Rebuild Complete!"
echo "======================================"
echo ""
echo "✓ All coverage data rebuilt successfully"
echo "✓ Tiles exported"
echo ""
echo "Next steps:"
echo "  - Hard refresh browser: Cmd+Shift+R (Mac) or Ctrl+Shift+R (Windows)"
echo "  - Check map: https://runmap.chouinard.me"
echo ""
