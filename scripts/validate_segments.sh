#!/bin/bash
# Validate segment-visited approach on 30 runs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

echo "========================================"
echo "Segment-Visited Validation (30 runs)"
echo "========================================"
echo ""

# Get first 30 Sacramento runs
TEST_RUN_IDS=$(psql -t -A -c \
  "SELECT id FROM runmap.runs_raw
   WHERE location = 'sacramento'
   ORDER BY start_time
   LIMIT 30")

RUN_COUNT=$(echo "$TEST_RUN_IDS" | wc -l | tr -d ' ')

echo "Processing $RUN_COUNT test runs with segment-visited approach..."
echo ""

COUNT=0
TOTAL_TIME=0
START_ALL=$(date +%s)

for RUN_ID in $TEST_RUN_IDS; do
  START=$(date +%s)

  # Buffer, subdivide, and apply to segments
  psql -c "SELECT runmap.buffer_one_run_subdiv('$RUN_ID'::uuid);" > /dev/null 2>&1
  psql -c "SELECT runmap.apply_run_to_segments('$RUN_ID'::uuid);" > /dev/null 2>&1

  END=$(date +%s)
  ELAPSED=$((END - START))
  TOTAL_TIME=$((TOTAL_TIME + ELAPSED))
  COUNT=$((COUNT + 1))

  if [ $((COUNT % 5)) -eq 0 ]; then
    AVG_TIME_MS=$((TOTAL_TIME * 1000 / COUNT))
    echo "  Processed $COUNT/$RUN_COUNT runs (avg: ${AVG_TIME_MS}ms/run)"
  fi
done

END_ALL=$(date +%s)
TOTAL_ELAPSED=$((END_ALL - START_ALL))
AVG_TIME_MS=$((TOTAL_TIME * 1000 / COUNT))

echo ""
echo "✓ Processed $RUN_COUNT/$RUN_COUNT runs in ${TOTAL_ELAPSED}s (avg: ${AVG_TIME_MS}ms/run)"
echo ""

# Show coverage statistics
echo "Coverage statistics:"
psql << 'EOF'
SELECT
  COUNT(*) as total_blocks,
  COUNT(CASE WHEN visited_length_m > 0 THEN 1 END) as blocks_with_coverage,
  ROUND(AVG(CASE WHEN visited_length_m > 0 THEN coverage_pct END)::numeric, 2) as avg_coverage_pct,
  ROUND(MAX(coverage_pct)::numeric, 2) as max_coverage_pct,
  COUNT(CASE WHEN coverage_pct >= 75 THEN 1 END) as complete_blocks,
  COUNT(CASE WHEN coverage_pct BETWEEN 5 AND 75 THEN 1 END) as partial_blocks,
  COUNT(CASE WHEN coverage_pct < 5 THEN 1 END) as unrun_blocks
FROM runmap.block_coverage_segments;

-- Check for any blocks >100% (should be zero!)
SELECT COUNT(*) as blocks_over_100_pct
FROM runmap.block_coverage_segments
WHERE coverage_pct > 100;
EOF

echo ""
echo "Validation complete!"
echo ""
