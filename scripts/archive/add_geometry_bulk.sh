#!/bin/bash
# Bulk add geometry using ogr2ogr import to temp tables then UPDATE
# Much faster than one-by-one processing

set -e

DB_HOST=${DB_HOST:-localhost}
DB_NAME=${DB_NAME:-runmap}
DB_USER=${DB_USER:-runmap_user}
GPX_DIR=${1:-data/workout-routes}

echo "========================================="
echo "Bulk Add Geometry (Fast Method)"
echo "========================================="
echo ""

# Count missing geometry
MISSING_RUNS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
    "SELECT COUNT(*) FROM runmap.runs_raw WHERE geom IS NULL")
MISSING_WALKS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
    "SELECT COUNT(*) FROM runmap.walks_raw WHERE geom IS NULL")
MISSING_CYCLES=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -A -c \
    "SELECT COUNT(*) FROM runmap.cycling_raw WHERE geom IS NULL")

echo "Records without geometry:"
echo "  Runs:   $MISSING_RUNS"
echo "  Walks:  $MISSING_WALKS"
echo "  Cycles: $MISSING_CYCLES"
echo ""

if [ $((MISSING_RUNS + MISSING_WALKS + MISSING_CYCLES)) -eq 0 ]; then
    echo "✅ All records have geometry"
    exit 0
fi

# Create temp table for geometry import
echo "Creating temporary import table..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
DROP TABLE IF EXISTS runmap.temp_gpx_import;
CREATE TABLE runmap.temp_gpx_import (
    ogc_fid SERIAL PRIMARY KEY,
    geom geometry(MultiLineString, 4326),
    filename TEXT
);
EOF

echo "✅ Temp table created"
echo ""

# Import ALL GPX files with geometry using ogr2ogr (fast!)
echo "Importing GPX files with geometry (this will take 3-5 minutes)..."
echo ""

IMPORTED=0
FAILED=0

for GPX_FILE in "$GPX_DIR"/*.gpx; do
    if [ ! -f "$GPX_FILE" ]; then
        continue
    fi

    FILENAME=$(basename "$GPX_FILE")

    # Import using ogr2ogr (fast for geometry extraction)
    if ogr2ogr -f PostgreSQL \
        PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER" \
        "$GPX_FILE" \
        -nln runmap.temp_gpx_import \
        -append \
        -sql "SELECT '$FILENAME' as filename, * FROM tracks" \
        2>/dev/null; then

        IMPORTED=$((IMPORTED + 1))

        if [ $((IMPORTED % 50)) -eq 0 ]; then
            echo "  Imported $IMPORTED files..."
        fi
    else
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "✅ Imported $IMPORTED files to temp table"
echo "   Failed: $FAILED"
echo ""

# Update runs_raw with geometry
if [ $MISSING_RUNS -gt 0 ]; then
    echo "Updating runs_raw with geometry..."
    psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
UPDATE runmap.runs_raw r
SET geom = t.geom
FROM runmap.temp_gpx_import t
WHERE r.filename = t.filename
  AND r.geom IS NULL;
EOF
    echo "✅ Updated $MISSING_RUNS runs"
fi

# Update walks_raw with geometry
if [ $MISSING_WALKS -gt 0 ]; then
    echo "Updating walks_raw with geometry..."
    psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
UPDATE runmap.walks_raw w
SET geom = t.geom
FROM runmap.temp_gpx_import t
WHERE w.filename = t.filename
  AND w.geom IS NULL;
EOF
    echo "✅ Updated $MISSING_WALKS walks"
fi

# Update cycling_raw with geometry
if [ $MISSING_CYCLES -gt 0 ]; then
    echo "Updating cycling_raw with geometry..."
    psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
UPDATE runmap.cycling_raw c
SET geom = t.geom
FROM runmap.temp_gpx_import t
WHERE c.filename = t.filename
  AND c.geom IS NULL;
EOF
    echo "✅ Updated $MISSING_CYCLES cycles"
fi

# Drop temp table
echo ""
echo "Cleaning up temp table..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "DROP TABLE runmap.temp_gpx_import;"

echo ""
echo "========================================="
echo "Geometry Added Successfully!"
echo "========================================="
echo ""

# Show final stats
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
SELECT 'Runs:   ' ||
    (SELECT COUNT(*) FROM runmap.runs_raw WHERE geom IS NOT NULL) || ' with geometry, ' ||
    (SELECT COUNT(*) FROM runmap.runs_raw WHERE geom IS NULL) || ' without'
UNION ALL
SELECT 'Walks:  ' ||
    (SELECT COUNT(*) FROM runmap.walks_raw WHERE geom IS NOT NULL) || ' with geometry, ' ||
    (SELECT COUNT(*) FROM runmap.walks_raw WHERE geom IS NULL) || ' without'
UNION ALL
SELECT 'Cycles: ' ||
    (SELECT COUNT(*) FROM runmap.cycling_raw WHERE geom IS NOT NULL) || ' with geometry, ' ||
    (SELECT COUNT(*) FROM runmap.cycling_raw WHERE geom IS NULL) || ' without';
EOF

echo ""
echo "Next steps:"
echo "1. Re-enable auto-process trigger: psql -f db/11_auto_process_trigger.sql"
echo "2. Process all runs: See CLAUDE.md for coverage processing"
echo ""
