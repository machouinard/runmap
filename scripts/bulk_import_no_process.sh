#!/bin/bash
# Bulk import GPX files WITHOUT processing (for faster testing cycles)
# After import, run: ./scripts/process_all_runs.sh
# Usage: ./bulk_import_no_process.sh <gpx_directory>

set -e

# Load common environment configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

GPX_DIR=${1:?Error: Please provide GPX directory path}

echo "========================================"
echo "Bulk GPX Import (No Processing)"
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

# Disable auto-process triggers for bulk import
echo "Disabling auto-process triggers..."
psql -d "$DB_NAME" -c "ALTER TABLE runmap.runs_raw DISABLE TRIGGER trigger_auto_process_run;" >/dev/null 2>&1 || true
echo ""

# Import each file
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
        ACTIVITY_TYPE=$(echo "$OUTPUT" | grep -o "Inserted [a-z]*" | awk '{print $2}')
        echo "✓ SUCCESS: $FILENAME ($ACTIVITY_TYPE)"
        SUCCESS=$((SUCCESS + 1))

        case "$ACTIVITY_TYPE" in
            run) RUNS_IMPORTED=$((RUNS_IMPORTED + 1)) ;;
            walk) WALKS_IMPORTED=$((WALKS_IMPORTED + 1)) ;;
            cycling) CYCLING_IMPORTED=$((CYCLING_IMPORTED + 1)) ;;
        esac
    elif echo "$OUTPUT" | grep -q "⚠ Duplicate"; then
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
echo "Import Complete (Processing Skipped)"
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

echo "========================================"
echo "Next Steps"
echo "========================================"
echo ""
echo "To process coverage for all imported runs:"
echo "  ./scripts/process_all_runs.sh"
echo ""
echo "To reset processing (clear buffers/coverage but keep runs):"
echo "  psql -c \"SELECT runmap.reset_coverage_processing();\""
echo ""
