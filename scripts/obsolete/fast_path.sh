#!/bin/bash
# Fast path: Export runs to PMTiles (no heavy spatial ops)

set -e

TILES_DIR=${TILES_DIR:-/home/mark/runmap/tiles}
TMP_DIR=${TMP_DIR:-/tmp}

echo "Starting fast path: runs.pmtiles"

# Export runs from database
ogr2ogr -f GeoJSON "$TMP_DIR/runs.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user password=fucker" \
  -sql "SELECT id::text, filename, start_time, geom FROM runmap.runs_raw ORDER BY uploaded_at DESC"

# Generate MBTiles
tippecanoe -o "$TMP_DIR/runs.mbtiles" \
  -Z4 -z14 \
  --drop-densest-as-needed \
  --force \
  "$TMP_DIR/runs.geojson"

# Convert to PMTiles
pmtiles convert "$TMP_DIR/runs.mbtiles" "$TILES_DIR/runs.pmtiles"

# Update version
psql -U runmap_user -d runmap -h localhost -c "UPDATE runmap.settings SET value = to_jsonb(NOW()::text) WHERE key = 'tiles_version';"

# Cleanup
rm -f "$TMP_DIR/runs.geojson" "$TMP_DIR/runs.mbtiles"

echo "✓ Fast path complete: $TILES_DIR/runs.pmtiles"
