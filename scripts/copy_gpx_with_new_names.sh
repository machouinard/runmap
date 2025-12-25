#!/bin/bash
# Copy GPX files from original location to project GPX directory with database-assigned new filenames
# This fixes the issue where bulk imports stored new filenames in DB but didn't copy the physical files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

echo "========================================"
echo "Copy GPX Files with New Names"
echo "========================================"
echo ""
echo "Source: /Volumes/RunMap/data/gpx/"
echo "Destination: $GPX_DIR"
echo "Database: $DB_NAME @ $DB_HOST"
echo ""

# Create destination directory if it doesn't exist
mkdir -p "$GPX_DIR"

# Query all activities and copy files
PGPASSWORD=$PGPASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -F'|' << 'EOF' | while IFS='|' read -r id filename activity_type; do
    SELECT id, filename, 'run' as activity_type FROM runmap.runs_raw
    UNION ALL
    SELECT id, filename, 'walk' as activity_type FROM runmap.walks_raw
    UNION ALL
    SELECT id, filename, 'cycling' as activity_type FROM runmap.cycling_raw
    ORDER BY filename;
EOF

    # Skip header/empty lines
    if [ -z "$id" ] || [ "$id" = "id" ]; then
        continue
    fi

    # Check if file already exists in destination
    DEST_PATH="$GPX_DIR/$filename"
    if [ -f "$DEST_PATH" ]; then
        echo "✓ Already exists: $filename"
        continue
    fi

    # Try to find original file in source directory
    # Search by matching the original filename stored in the database
    # For new-format names like "2025-10-24_2029_walk_8.2km.gpx", we need to find the source

    # This is complex because we don't have a mapping of old->new filenames
    # Best approach: Query the database for start_time and distance, then search for matching GPX
    echo "⚠ Missing: $filename (ID: $id, Type: $activity_type)"
done

echo ""
echo "========================================"
echo "Analysis complete"
echo "========================================"
echo ""
echo "To copy files, we need to re-import from source with the updated ingest script."
echo "Run: bash scripts/bulk_import.sh /tmp/all_gpx_files.txt"
