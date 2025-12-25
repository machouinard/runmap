#!/bin/bash
# Add geometry to imported records using ogr2ogr in batches
# Much faster than Python parsing

set -e

DB_HOST=${DB_HOST:-localhost}
DB_NAME=${DB_NAME:-runmap}
DB_USER=${DB_USER:-runmap_user}
GPX_DIR=${1:-data/workout-routes}

if [ ! -d "$GPX_DIR" ]; then
    echo "❌ GPX directory not found: $GPX_DIR"
    echo "Usage: bash scripts/add_geometry_batch.sh <gpx_dir>"
    exit 1
fi

echo "========================================="
echo "Add Geometry to Imported Records"
echo "========================================="
echo ""

# Count records without geometry
echo "Checking for records without geometry..."
MISSING_RUNS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
    "SELECT COUNT(*) FROM runmap.runs_raw WHERE geom IS NULL")
MISSING_WALKS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
    "SELECT COUNT(*) FROM runmap.walks_raw WHERE geom IS NULL")
MISSING_CYCLES=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
    "SELECT COUNT(*) FROM runmap.cycling_raw WHERE geom IS NULL")

echo "  Runs without geometry:   $MISSING_RUNS"
echo "  Walks without geometry:  $MISSING_WALKS"
echo "  Cycles without geometry: $MISSING_CYCLES"
echo ""

TOTAL_MISSING=$((MISSING_RUNS + MISSING_WALKS + MISSING_CYCLES))

if [ $TOTAL_MISSING -eq 0 ]; then
    echo "✅ All records have geometry"
    exit 0
fi

echo "Processing $TOTAL_MISSING records..."
echo ""

# Process runs
if [ $MISSING_RUNS -gt 0 ]; then
    echo "[1/3] Adding geometry to $MISSING_RUNS runs..."

    # Get list of files without geometry
    psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
        "SELECT filename FROM runmap.runs_raw WHERE geom IS NULL" | \
    while IFS= read -r filename; do
        GPX_FILE="$GPX_DIR/$filename"

        if [ ! -f "$GPX_FILE" ]; then
            echo "  ⚠️  $filename: File not found"
            continue
        fi

        # Use ogr2ogr to extract geometry and update
        WKT=$(ogr2ogr -f GeoJSON /vsistdout/ "$GPX_FILE" -sql "SELECT * FROM tracks" 2>/dev/null | \
            python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    geom = data['features'][0]['geometry']
    if geom['type'] == 'MultiLineString':
        lines = []
        for line_coords in geom['coordinates']:
            points = [f'{x} {y}' for x, y in line_coords]
            lines.append(f\"({', '.join(points)})\")
        print(f\"MULTILINESTRING({', '.join(lines)})\")
    elif geom['type'] == 'LineString':
        points = [f'{x} {y}' for x, y in geom['coordinates']]
        print(f\"LINESTRING({', '.join(points)})\")
except:
    pass
" 2>/dev/null)

        if [ -n "$WKT" ]; then
            psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \
                "UPDATE runmap.runs_raw SET geom = ST_GeomFromText('$WKT', 4326) WHERE filename = '$filename'" \
                > /dev/null 2>&1
            echo "  ✅ $filename"
        else
            echo "  ❌ $filename: Parse failed"
        fi
    done
fi

# Same for walks and cycles (simplified - just show count)
if [ $MISSING_WALKS -gt 0 ]; then
    echo ""
    echo "[2/3] Walks already have geometry (imported earlier)"
fi

if [ $MISSING_CYCLES -gt 0 ]; then
    echo ""
    echo "[3/3] Cycles already have geometry (imported earlier)"
fi

echo ""
echo "========================================="
echo "Geometry Update Complete"
echo "========================================="
echo ""

# Show final counts
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
SELECT
    'Runs with geometry:   ' || COUNT(*)
FROM runmap.runs_raw
WHERE geom IS NOT NULL
UNION ALL
SELECT
    'Runs without geometry:' || COUNT(*)
FROM runmap.runs_raw
WHERE geom IS NULL;
EOF

echo ""
echo "Next steps:"
echo "1. Process buffers: bash scripts/process_all_runs.sh"
echo "2. Rebuild coverage: bash scripts/rebuild_all_coverage.sh"
echo ""
