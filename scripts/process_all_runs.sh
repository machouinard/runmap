#!/bin/bash
# Process all unprocessed Sacramento runs (buffer + coverage)
# This script processes existing runs in the database without re-importing GPX files
# Useful for testing coverage algorithm changes without waiting for slow GPX import

set -e

# Load common environment configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

echo "========================================"
echo "Process All Runs (Coverage Only)"
echo "========================================"
echo ""

# Get count of unprocessed Sacramento runs
UNPROCESSED_COUNT=$(psql -d "$DB_NAME" -t -A -c \
    "SELECT COUNT(*) FROM runmap.runs_raw r
     WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_subdiv rb WHERE rb.run_id = r.id)
     AND r.location = 'sacramento'")

if [ "$UNPROCESSED_COUNT" -eq 0 ]; then
    echo "No unprocessed Sacramento runs found."
    echo ""
    echo "To reset processing (clear buffers/coverage but keep imported runs):"
    echo "  psql -d \$DB_NAME -c \"SELECT runmap.reset_coverage_processing();\""
    echo ""
    exit 0
fi

echo "Found $UNPROCESSED_COUNT unprocessed Sacramento runs"
echo "Processing time varies by route complexity (1-15s per run)"
echo "Estimated completion time will be calculated after first 10 runs..."
echo ""

# Get IDs of runs without buffers (Sacramento only)
NEW_RUN_IDS=$(psql -d "$DB_NAME" -t -A -c \
    "SELECT id FROM runmap.runs_raw r
     WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_subdiv rb WHERE rb.run_id = r.id)
     AND r.location = 'sacramento'
     ORDER BY start_time ASC")

# Process each run with detailed timing
COUNT=0
TOTAL_TIME=0
START_ALL=$(date +%s)

for RUN_ID in $NEW_RUN_IDS; do
    START=$(date +%s)

    # Get run metadata for diagnostics
    RUN_INFO=$(psql -d "$DB_NAME" -t -A -F'|' -c \
        "SELECT filename, ROUND(total_distance_m::numeric, 0), ST_NPoints(geom)
         FROM runmap.runs_raw WHERE id = '$RUN_ID'::uuid")
    FILENAME=$(echo "$RUN_INFO" | cut -d'|' -f1)
    DISTANCE_M=$(echo "$RUN_INFO" | cut -d'|' -f2)
    NUM_POINTS=$(echo "$RUN_INFO" | cut -d'|' -f3)

    # Buffer the run
    START_BUFFER=$(date +%s)
    psql -d "$DB_NAME" -c "SELECT runmap.buffer_one_run_subdiv('$RUN_ID'::uuid);" > /dev/null 2>&1
    END_BUFFER=$(date +%s)
    BUFFER_TIME=$((END_BUFFER - START_BUFFER))

    # Get buffer stats (count subdivisions)
    BUFFER_SUBDIVISIONS=$(psql -d "$DB_NAME" -t -A -c \
        "SELECT COUNT(*) FROM runmap.runs_buffered_subdiv WHERE run_id = '$RUN_ID'::uuid")

    # Apply coverage and get affected segment count
    START_COVERAGE=$(date +%s)
    SEGMENTS_UPDATED=$(psql -d "$DB_NAME" -t -A -c \
        "SELECT runmap.apply_run_to_segments('$RUN_ID'::uuid);")
    END_COVERAGE=$(date +%s)
    COVERAGE_TIME=$((END_COVERAGE - START_COVERAGE))

    END=$(date +%s)
    ELAPSED=$((END - START))
    TOTAL_TIME=$((TOTAL_TIME + ELAPSED))
    COUNT=$((COUNT + 1))

    # Calculate stats
    AVG_TIME=$((TOTAL_TIME / COUNT))
    REMAINING=$((UNPROCESSED_COUNT - COUNT))
    EST_REMAINING=$((REMAINING * AVG_TIME))
    EST_MINS=$((EST_REMAINING / 60))

    # Show every run if slow (>5s), otherwise every 10 runs
    if [ "$ELAPSED" -gt 5 ] || [ $((COUNT % 10)) -eq 0 ]; then
        if [ "$ELAPSED" -gt 5 ]; then
            # Get total visited segments for diagnosis
            TOTAL_VISITED=$(psql -d "$DB_NAME" -t -A -c \
                "SELECT COUNT(*) FROM runmap.block_segment_visited WHERE visited = true")

            echo "  ⚠️  Run $COUNT: ${ELAPSED}s total (buffer:${BUFFER_TIME}s, coverage:${COVERAGE_TIME}s)"
            echo "      File: $FILENAME"
            echo "      Distance: ${DISTANCE_M}m, Points: $NUM_POINTS, Subdivisions: $BUFFER_SUBDIVISIONS, Segments: $SEGMENTS_UPDATED"
            echo "      Total visited segments: $TOTAL_VISITED"
        else
            echo "  Processed $COUNT/$UNPROCESSED_COUNT runs (avg: ${AVG_TIME}s/run, est remaining: ${EST_MINS}m)"
        fi
    fi
done

END_ALL=$(date +%s)
TOTAL_ELAPSED=$((END_ALL - START_ALL))
TOTAL_MINS=$((TOTAL_ELAPSED / 60))
echo "  Processed $UNPROCESSED_COUNT/$UNPROCESSED_COUNT runs in ${TOTAL_MINS}m ${TOTAL_ELAPSED}s total"
echo ""
echo "Refreshing coverage statistics..."
psql -d "$DB_NAME" -c "REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;" > /dev/null

echo ""
echo "Exporting tiles..."
bash "$SCRIPT_DIR/export_tiles_blocks.sh"

echo ""
echo "✓ Processing complete!"
echo ""
