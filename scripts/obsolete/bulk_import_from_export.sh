#!/bin/bash
set -e

# Bulk import GPX files using Apple Health export.xml classification
# This is for the INITIAL bulk import only - uses workout_types.json mapping
#
# For future uploads via iOS shortcut, use the regular ingest_gpx.sh with automatic detection

if [ $# -lt 2 ]; then
  echo "Usage: bash scripts/bulk_import_from_export.sh <workout_types.json> <workout-routes-dir>"
  echo ""
  echo "Example:"
  echo "  bash scripts/bulk_import_from_export.sh data/workout_types.json data/workout-routes"
  exit 1
fi

WORKOUT_TYPES_JSON=$1
GPX_DIR=$2

# Load environment
if [ -f .env ]; then
  export $(cat .env | grep -v '^#' | xargs)
fi

DB_HOST=${DB_HOST:-192.168.68.25}
DB_NAME=${DB_NAME:-runmap}
DB_USER=${DB_USER:-runmap_user}
PROJECT_ROOT=${PROJECT_ROOT:-/Volumes/RunMap}

echo "========================================="
echo "Bulk Import from Apple Health Export"
echo "========================================="
echo ""
echo "Workout types: $WORKOUT_TYPES_JSON"
echo "GPX directory: $GPX_DIR"
echo ""

# Count files
TOTAL_FILES=$(ls "$GPX_DIR"/*.gpx 2>/dev/null | wc -l | tr -d ' ')
echo "📂 Found $TOTAL_FILES GPX files"
echo ""

# Load workout types mapping
if [ ! -f "$WORKOUT_TYPES_JSON" ]; then
  echo "❌ Error: $WORKOUT_TYPES_JSON not found"
  exit 1
fi

echo "📋 Loading workout classifications..."
TOTAL_WORKOUTS=$(jq 'length' "$WORKOUT_TYPES_JSON")
echo "   $TOTAL_WORKOUTS workouts classified in export.xml"
echo ""

# Disable auto-process trigger during bulk import (optimization)
echo "[1/5] Disabling auto-process trigger..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \
  "DROP TRIGGER IF EXISTS trigger_auto_process_run ON runmap.runs_raw;" 2>/dev/null || true
echo ""

# Import all GPX files
echo "[2/5] Importing GPX files..."
echo ""

IMPORTED_RUNS=0
IMPORTED_WALKS=0
IMPORTED_CYCLES=0
DUPLICATE_COUNT=0
UNKNOWN_COUNT=0
FAILED_COUNT=0

for GPX_FILE in "$GPX_DIR"/*.gpx; do
  if [ ! -f "$GPX_FILE" ]; then
    continue
  fi

  FILENAME=$(basename "$GPX_FILE")

  # Look up activity type from workout_types.json
  ACTIVITY_TYPE=$(jq -r ".[\"$FILENAME\"].activity_type // \"unknown\"" "$WORKOUT_TYPES_JSON")

  if [ "$ACTIVITY_TYPE" = "unknown" ] || [ "$ACTIVITY_TYPE" = "null" ]; then
    echo "  ⚠️  $FILENAME: Not in export.xml (skipping)"
    UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
    continue
  fi

  # Determine target table
  case "$ACTIVITY_TYPE" in
    run)
      TARGET_TABLE="runmap.runs_raw"
      ;;
    walk)
      TARGET_TABLE="runmap.walks_raw"
      ;;
    cycle)
      TARGET_TABLE="runmap.cycling_raw"
      ;;
    *)
      echo "  ⚠️  $FILENAME: Unknown activity type '$ACTIVITY_TYPE' (skipping)"
      UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1))
      continue
      ;;
  esac

  # Import to appropriate table
  # Use ogr2ogr to import GPX to PostGIS
  if ogr2ogr -f PostgreSQL \
    PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER" \
    "$GPX_FILE" \
    -nln "$TARGET_TABLE" \
    -append \
    -lco GEOMETRY_NAME=geom \
    -lco FID=gid \
    -sql "SELECT *, ST_AsText(geometry) as wkt_geom FROM tracks" \
    2>&1 | grep -q "ERROR.*duplicate\|ERROR.*unique"; then

    echo "  ⚠️  $FILENAME: Duplicate (skipped)"
    DUPLICATE_COUNT=$((DUPLICATE_COUNT + 1))
  else
    echo "  ✅ $FILENAME: Imported as $ACTIVITY_TYPE"

    case "$ACTIVITY_TYPE" in
      run)
        IMPORTED_RUNS=$((IMPORTED_RUNS + 1))
        ;;
      walk)
        IMPORTED_WALKS=$((IMPORTED_WALKS + 1))
        ;;
      cycle)
        IMPORTED_CYCLES=$((IMPORTED_CYCLES + 1))
        ;;
    esac
  fi
done

echo ""
echo "Import Summary:"
echo "  ✅ Runs:       $IMPORTED_RUNS"
echo "  ✅ Walks:      $IMPORTED_WALKS"
echo "  ✅ Cycles:     $IMPORTED_CYCLES"
echo "  ⚠️  Duplicates: $DUPLICATE_COUNT"
echo "  ⚠️  Unknown:    $UNKNOWN_COUNT"
echo "  ❌ Failed:     $FAILED_COUNT"
echo ""

if [ $IMPORTED_RUNS -eq 0 ]; then
  echo "⚠️  No new runs imported. Skipping coverage processing."

  # Re-enable trigger
  psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f db/11_auto_process_trigger.sql > /dev/null 2>&1 || true

  exit 0
fi

# Buffer all imported runs
echo "[3/5] Creating buffers for $IMPORTED_RUNS runs..."
echo "   This may take 5-10 minutes..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
DO $$
DECLARE
  run_record RECORD;
  processed_count INT := 0;
BEGIN
  FOR run_record IN
    SELECT r.id
    FROM runmap.runs_raw r
    LEFT JOIN runmap.runs_buffered_32610 rb ON r.id = rb.run_id
    WHERE rb.run_id IS NULL
  LOOP
    PERFORM runmap.buffer_one_run(run_record.id);
    processed_count := processed_count + 1;

    IF processed_count % 10 = 0 THEN
      RAISE NOTICE 'Buffered % runs...', processed_count;
    END IF;
  END LOOP;

  RAISE NOTICE 'Buffered % runs total', processed_count;
END $$;
EOF

echo ""
echo "[4/5] Rebuilding block coverage..."
echo "   This may take 5-10 minutes..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \
  "SELECT runmap.rebuild_block_coverage();"

echo ""
echo "[5/5] Refreshing statistics..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \
  "REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;"

# Re-enable auto-process trigger
echo ""
echo "Re-enabling auto-process trigger..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f db/11_auto_process_trigger.sql > /dev/null

# Show final stats
echo ""
echo "========================================="
echo "Final Coverage Statistics:"
echo "========================================="
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
SELECT
  'Total Blocks:     ' || total_blocks as stat,
  ''
FROM runmap.coverage_stats_blocks
UNION ALL
SELECT
  'Complete Blocks:  ' || complete_blocks || ' (' || ROUND(block_completion_pct::numeric, 1) || '%)',
  ''
FROM runmap.coverage_stats_blocks
UNION ALL
SELECT
  'Incomplete Blocks:' || incomplete_blocks,
  ''
FROM runmap.coverage_stats_blocks
UNION ALL
SELECT
  'Total Runs:       ' || COUNT(*),
  ''
FROM runmap.runs_raw
UNION ALL
SELECT
  'Total Walks:      ' || COUNT(*),
  ''
FROM runmap.walks_raw
UNION ALL
SELECT
  'Total Cycles:     ' || COUNT(*),
  ''
FROM runmap.cycling_raw;
EOF

echo ""
echo "========================================="
echo "Next Steps:"
echo "========================================="
echo "1. Export tiles: bash scripts/export_tiles_blocks.sh"
echo "2. View map: open web/build/index.html"
echo ""
