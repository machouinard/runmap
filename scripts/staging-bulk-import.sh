#!/bin/bash
# Bulk import for staging database (without processing - just import GPX files)
set -e

# Load staging environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load .env.staging
if [ ! -f "$PROJECT_ROOT/.env.staging" ]; then
    echo "ERROR: .env.staging not found!"
    exit 1
fi

export $(grep -v '^#' "$PROJECT_ROOT/.env.staging" | sed 's/#.*//' | xargs)

# Set PostgreSQL environment variables
export PGHOST=$DB_HOST
export PGDATABASE=$DB_NAME
export PGUSER=$DB_USER
# PGPASSWORD already set from .env.staging

GPX_LIST=${1:?Error: Please provide path to file list}

if [ ! -f "$GPX_LIST" ]; then
    echo "ERROR: File list not found: $GPX_LIST"
    exit 1
fi

echo "========================================"
echo "Staging Bulk GPX Import"
echo "========================================"
echo ""
echo "Database: $DB_NAME @ $DB_HOST"
echo "GPX list: $GPX_LIST"
echo ""

# Count files
GPX_COUNT=$(wc -l < "$GPX_LIST" | tr -d ' ')
echo "Found $GPX_COUNT GPX files to import"
echo ""

# Import each file
SUCCESS=0
DUPLICATE=0
ERROR=0
RUNS_IMPORTED=0
WALKS_IMPORTED=0
CYCLING_IMPORTED=0

while IFS= read -r GPX_FILE; do
    FILENAME=$(basename "$GPX_FILE")

    # Import the file using staging-specific ingest script
    # (environment variables already exported from .env.staging)
    OUTPUT=$(bash "$SCRIPT_DIR/ingest_gpx_staging.sh" "$GPX_FILE" 2>&1)

    if echo "$OUTPUT" | grep -q "✓ Inserted"; then
        # Match any activity type: "✓ Inserted run", "✓ Inserted walk", "✓ Inserted cycling"
        ACTIVITY_TYPE=$(echo "$OUTPUT" | grep -o "Inserted [a-z]*" | awk '{print $2}')

        # Extract generated filename from output
        GENERATED_FILENAME=$(echo "$OUTPUT" | grep "ℹ Generated filename:" | sed 's/.*ℹ Generated filename: \([^ ]*\).*/\1/')

        if [ -n "$GENERATED_FILENAME" ]; then
            echo "✓ SUCCESS: $FILENAME → $GENERATED_FILENAME ($ACTIVITY_TYPE)"
        else
            echo "✓ SUCCESS: $FILENAME ($ACTIVITY_TYPE)"
        fi

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
        echo "  Output: $OUTPUT"
        ERROR=$((ERROR + 1))
    fi
done < "$GPX_LIST"

echo ""
echo "========================================"
echo "Import Complete"
echo "========================================"
echo ""
echo "✓ Imported: $SUCCESS total"
if [ "$RUNS_IMPORTED" -gt 0 ]; then echo "  - Runs: $RUNS_IMPORTED"; fi
if [ "$WALKS_IMPORTED" -gt 0 ]; then echo "  - Walks: $WALKS_IMPORTED"; fi
if [ "$CYCLING_IMPORTED" -gt 0 ]; then echo "  - Cycling: $CYCLING_IMPORTED"; fi
echo "⚠️  Duplicates: $DUPLICATE"
echo "✗ Errors: $ERROR"
echo ""

# Show database counts
echo "Database totals:"
psql -t -A -c \
    "SELECT
        'Runs: ' || COUNT(*) FROM runmap.runs_raw
     UNION ALL
     SELECT 'Walks: ' || COUNT(*) FROM runmap.walks_raw
     UNION ALL
     SELECT 'Cycling: ' || COUNT(*) FROM runmap.cycling_raw;"
echo ""
