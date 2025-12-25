#!/bin/bash
# Recalculate content hashes using binary mode (consistent with API)
set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
GPX_DIR=${GPX_DIR:-/home/mark/runmap/gpx}

echo "========================================"
echo "Recalculating Content Hashes"
echo "========================================"
echo ""
echo "This fixes hash mismatches between bulk import and API upload"
echo ""

# Get all runs with their filenames
RUNS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
    "SELECT id, filename FROM runmap.runs_raw")

UPDATED=0
MISSING=0
ERROR=0

while IFS='|' read -r RUN_ID FILENAME; do
    GPX_FILE="$GPX_DIR/$FILENAME"
    
    if [ ! -f "$GPX_FILE" ]; then
        echo "⚠️  MISSING: $FILENAME"
        MISSING=$((MISSING + 1))
        continue
    fi
    
    # Calculate hash in binary mode
    NEW_HASH=$(sha256sum "$GPX_FILE" | awk '{print $1}')
    
    # Update database
    psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \
        "UPDATE runmap.runs_raw SET content_hash = '$NEW_HASH' WHERE id = '$RUN_ID'::uuid" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        UPDATED=$((UPDATED + 1))
        if [ $((UPDATED % 50)) -eq 0 ]; then
            echo "  Updated $UPDATED hashes..."
        fi
    else
        echo "✗ ERROR: $FILENAME"
        ERROR=$((ERROR + 1))
    fi
done <<< "$RUNS"

echo ""
echo "========================================"
echo "Hash Recalculation Complete"
echo "========================================"
echo ""
echo "✓ Updated: $UPDATED"
echo "⚠️  Missing files: $MISSING"
echo "✗ Errors: $ERROR"
echo ""
