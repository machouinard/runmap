#!/bin/bash
# Minimal slow path: Just refresh runs, skip coverage calculation

set -e

# Limit CPU and I/O priority
renice -n 10 $$ > /dev/null 2>&1 || true
ionice -c 3 -p $$ > /dev/null 2>&1 || true

TILES_DIR=${TILES_DIR:-/home/mark/runmap/tiles}
TMP_DIR=${TMP_DIR:-/tmp}

echo "Starting minimal slow path (runs only)..."

# Just refresh runs_merged
echo "Refreshing runs_merged..."
psql -U runmap_user -d runmap -h localhost -c "SET work_mem='256MB'; REFRESH MATERIALIZED VIEW runmap.runs_merged;"

echo "Exporting runs..."
ogr2ogr -f GeoJSON "$TMP_DIR/runs.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user password=mrmr7246" \
  -sql "SELECT gid, geom FROM runmap.runs_merged"

echo "Generating runs tiles..."
tippecanoe -o "$TMP_DIR/runs.mbtiles" \
  -Z4 -z14 \
  --force \
  "$TMP_DIR/runs.geojson"
pmtiles convert "$TMP_DIR/runs.mbtiles" "$TILES_DIR/runs.pmtiles"

# Update version
psql -U runmap_user -d runmap -h localhost -c "UPDATE runmap.settings SET value = to_jsonb(NOW()::text) WHERE key = 'tiles_version';"

# Cleanup
rm -f "$TMP_DIR/runs.*"

echo "✓ Minimal slow path complete: runs.pmtiles only"
