#!/bin/bash
# Universal bulk import script for GPX files
# Usage: ./bulk_import.sh <gpx_directory>

set -e

# Load common environment configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

GPX_DIR=${1:?Error: Please provide GPX directory path}

echo "========================================"
echo "Bulk GPX Import"
echo "========================================"
echo ""
echo "Source directory: $GPX_DIR"
echo ""

# Count files
GPX_COUNT=$(find "$GPX_DIR" -name "*.gpx" 2>/dev/null | wc -l | tr -d ' ')

if [ "$GPX_COUNT" -eq 0 ]; then
    echo "ERROR: No GPX files found in $GPX_DIR"
    exit 1
fi

echo "Found $GPX_COUNT GPX files"
echo ""

# Disable auto-process triggers for bulk import (speeds up import dramatically)
# NOTE: We keep location trigger enabled so locations are set on insert
echo "Disabling auto-process triggers for bulk import..."
psql -d "$DB_NAME" -c "ALTER TABLE runmap.runs_raw DISABLE TRIGGER trigger_auto_process_run;" >/dev/null 2>&1 || true
echo ""

# Import each file using the ingest script
SUCCESS=0
DUPLICATE=0
ERROR=0
RUNS_IMPORTED=0
WALKS_IMPORTED=0
CYCLING_IMPORTED=0

for GPX_FILE in "$GPX_DIR"/*.gpx; do
    FILENAME=$(basename "$GPX_FILE")

    # Import the file (ingest_gpx.sh handles duplicate detection via workout_hash)
    OUTPUT=$(bash scripts/ingest_gpx.sh "$GPX_FILE" 2>&1)

    if echo "$OUTPUT" | grep -q "✓ Inserted"; then
        # Match any activity type: "✓ Inserted run", "✓ Inserted walk", "✓ Inserted cycling"
        ACTIVITY_TYPE=$(echo "$OUTPUT" | grep -o "Inserted [a-z]*" | awk '{print $2}')
        echo "✓ SUCCESS: $FILENAME ($ACTIVITY_TYPE)"
        SUCCESS=$((SUCCESS + 1))

        # Count by activity type
        case "$ACTIVITY_TYPE" in
            run) RUNS_IMPORTED=$((RUNS_IMPORTED + 1)) ;;
            walk) WALKS_IMPORTED=$((WALKS_IMPORTED + 1)) ;;
            cycling) CYCLING_IMPORTED=$((CYCLING_IMPORTED + 1)) ;;
        esac
    elif echo "$OUTPUT" | grep -q "⚠ Duplicate"; then
        # Match any duplicate: "⚠ Duplicate run", "⚠ Duplicate walk", etc.
        ACTIVITY_TYPE=$(echo "$OUTPUT" | grep -o "Duplicate [a-z]*" | awk '{print $2}')
        echo "⚠️  DUPLICATE: $FILENAME ($ACTIVITY_TYPE)"
        DUPLICATE=$((DUPLICATE + 1))
    else
        echo "✗ ERROR: $FILENAME"
        ERROR=$((ERROR + 1))
    fi
done

echo ""
echo "========================================"
echo "Import Complete - Re-enabling Trigger"
echo "========================================"
echo ""

echo "✓ Imported: $SUCCESS total"
if [ "$RUNS_IMPORTED" -gt 0 ]; then echo "  - Runs: $RUNS_IMPORTED"; fi
if [ "$WALKS_IMPORTED" -gt 0 ]; then echo "  - Walks: $WALKS_IMPORTED"; fi
if [ "$CYCLING_IMPORTED" -gt 0 ]; then echo "  - Cycling: $CYCLING_IMPORTED"; fi
echo "⚠️  Duplicates: $DUPLICATE"
echo "✗ Errors: $ERROR"
echo ""

# Re-enable auto-process triggers
echo "Re-enabling auto-process triggers..."
psql -d "$DB_NAME" -c "ALTER TABLE runmap.runs_raw ENABLE TRIGGER trigger_auto_process_run;" >/dev/null 2>&1 || true

# Now process all the imported runs in bulk
# TODO: How do we estimate the time it will take to process all the runs?
if [ "$SUCCESS" -gt 0 ]; then
    echo ""
    echo "Processing $SUCCESS new runs (buffering + coverage)..."
    echo "Time varies by route complexity - estimated completion after first 10 runs..."
    echo ""

    # Get IDs of runs without buffers (Sacramento only - don't process other locations)
    NEW_RUN_IDS=$(psql -d "$DB_NAME" -t -A -c \
        "SELECT id FROM runmap.runs_raw r
         WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_subdiv rb WHERE rb.run_id = r.id)
         AND r.location = 'sacramento'
         LIMIT $SUCCESS")

    # Buffer and apply coverage for each new run
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
        BUFFER_INFO=$(psql -d "$DB_NAME" -t -A -c \
            "SELECT COUNT(*) FROM runmap.runs_buffered_subdiv WHERE run_id = '$RUN_ID'::uuid")
        BUFFER_SUBDIVISIONS=$BUFFER_INFO

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
        REMAINING=$((SUCCESS - COUNT))
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
                echo "  Processed $COUNT/$SUCCESS runs (avg: ${AVG_TIME}s/run, est remaining: ${EST_MINS}m)"
            fi
        fi
    done

    END_ALL=$(date +%s)
    TOTAL_ELAPSED=$((END_ALL - START_ALL))
    TOTAL_MINS=$((TOTAL_ELAPSED / 60))
    echo "  Processed $SUCCESS/$SUCCESS runs in ${TOTAL_MINS}m ${TOTAL_ELAPSED}s total"
    echo ""
    echo "Refreshing coverage statistics..."
    psql -d "$DB_NAME" -c \
        "REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;" > /dev/null

    echo ""
    echo "Exporting tiles..."
    bash "$SCRIPT_DIR/export_tiles_blocks.sh"
fi

echo ""
echo "Total activities in database:"
psql -d "$DB_NAME" -t -A -c \
    "SELECT
        'Runs: ' || COUNT(*) FROM runmap.runs_raw
     UNION ALL
     SELECT 'Walks: ' || COUNT(*) FROM runmap.walks_raw
     UNION ALL
     SELECT 'Cycling: ' || COUNT(*) FROM runmap.cycling_raw;"
echo ""

