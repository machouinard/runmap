#!/bin/bash
# Export block-based tiles for map display

set -e

# Load common environment configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

echo "======================================"
echo "Export Block-Based Tiles"
echo "======================================"
echo ""

# Create directories
mkdir -p "$TMP_DIR"
mkdir -p "$TILES_DIR"

echo "Exporting GeoJSON layers..."
echo ""

# Export blocks by status (transform to EPSG:4326 for Tippecanoe)
echo "1. Exporting incomplete blocks (unrun + partial)..."
ogr2ogr -f GeoJSON "$TMP_DIR/blocks_incomplete.geojson" \
  PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
  -sql "SELECT block_id, ST_Transform(geom_32610, 4326) as geometry, name, highway, block_length_m, coverage_pct FROM runmap.streets_unrun
         UNION ALL
         SELECT block_id, ST_Transform(geom_32610, 4326) as geometry, name, highway, block_length_m, coverage_pct FROM runmap.streets_partial" \
  -t_srs EPSG:4326

echo "2. Exporting complete blocks..."
ogr2ogr -f GeoJSON "$TMP_DIR/blocks_complete.geojson" \
  PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
  -sql "SELECT block_id, ST_Transform(geom_32610, 4326) as geometry, name, highway, block_length_m, coverage_pct FROM runmap.streets_complete" \
  -t_srs EPSG:4326

echo "3. Exporting all runs (all locations)..."
ogr2ogr -f GeoJSON "$TMP_DIR/runs.geojson" \
  PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
  -sql "SELECT id, ST_Transform(geom, 4326) as geometry, filename, start_time, total_distance_m, duration_seconds, 'run' as activity_type FROM runmap.runs_raw" \
  -t_srs EPSG:4326

echo "4. Exporting walks from 'other' locations only..."
ogr2ogr -f GeoJSON "$TMP_DIR/walks.geojson" \
  PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
  -sql "SELECT id, ST_Transform(geom, 4326) as geometry, filename, start_time, total_distance_m, duration_seconds, 'walk' as activity_type FROM runmap.walks_raw WHERE location = 'other'" \
  -t_srs EPSG:4326

echo "5. Exporting cycling from 'other' locations only..."
ogr2ogr -f GeoJSON "$TMP_DIR/cycling.geojson" \
  PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
  -sql "SELECT id, ST_Transform(geom, 4326) as geometry, filename, start_time, total_distance_m, duration_seconds, 'cycling' as activity_type FROM runmap.cycling_raw WHERE location = 'other'" \
  -t_srs EPSG:4326

echo ""
echo "Converting to PMTiles..."
echo ""

# Convert incomplete blocks to PMTiles (grey - not yet run)
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/blocks_incomplete.geojson"; then
  echo "1. Converting streets_incomplete.pmtiles..."
  tippecanoe -o "$TMP_DIR/streets_incomplete.mbtiles" \
    -Z4 -z14 --force \
    -l "streets_incomplete" \
    -n "Incomplete Streets" \
    -A "Streets with <90% coverage (not yet run)" \
    "$TMP_DIR/blocks_incomplete.geojson"

  pmtiles convert "$TMP_DIR/streets_incomplete.mbtiles" "$TILES_DIR/streets_incomplete.pmtiles"
  rm "$TMP_DIR/streets_incomplete.mbtiles"
  echo "   ✓ streets_incomplete.pmtiles ($(du -h "$TILES_DIR/streets_incomplete.pmtiles" | cut -f1))"
else
  echo "   ⚠ No incomplete blocks to export"
fi

# Convert complete blocks to PMTiles (green - done!)
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/blocks_complete.geojson"; then
  echo "2. Converting streets_complete.pmtiles..."
  tippecanoe -o "$TMP_DIR/streets_complete.mbtiles" \
    -Z4 -z14 --force \
    -l "streets_complete" \
    -n "Complete Streets" \
    -A "Streets with ≥90% coverage" \
    "$TMP_DIR/blocks_complete.geojson"

  pmtiles convert "$TMP_DIR/streets_complete.mbtiles" "$TILES_DIR/streets_complete.pmtiles"
  rm "$TMP_DIR/streets_complete.mbtiles"
  echo "   ✓ streets_complete.pmtiles ($(du -h "$TILES_DIR/streets_complete.pmtiles" | cut -f1))"
else
  echo "   ⚠ No complete blocks to export"
fi

# Convert runs to PMTiles (red lines)
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/runs.geojson"; then
  echo "3. Converting runs.pmtiles..."
  tippecanoe -o "$TMP_DIR/runs.mbtiles" \
    -Z4 -z14 --force \
    -l "runs" \
    -n "Running Routes" \
    -A "All running GPS tracks" \
    "$TMP_DIR/runs.geojson"

  pmtiles convert "$TMP_DIR/runs.mbtiles" "$TILES_DIR/runs.pmtiles"
  rm "$TMP_DIR/runs.mbtiles"
  echo "   ✓ runs.pmtiles ($(du -h "$TILES_DIR/runs.pmtiles" | cut -f1))"
else
  echo "   ⚠ No runs to export"
fi

# Convert walks to PMTiles (blue lines)
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/walks.geojson"; then
  echo "4. Converting walks.pmtiles..."
  tippecanoe -o "$TMP_DIR/walks.mbtiles" \
    -Z4 -z14 --force \
    -l "walks" \
    -n "Walking Routes" \
    -A "Walking routes (other locations only)" \
    "$TMP_DIR/walks.geojson"

  pmtiles convert "$TMP_DIR/walks.mbtiles" "$TILES_DIR/walks.pmtiles"
  rm "$TMP_DIR/walks.mbtiles"
  echo "   ✓ walks.pmtiles ($(du -h "$TILES_DIR/walks.pmtiles" | cut -f1))"
else
  echo "   ⚠ No walks to export (expected if all in Sacramento/Portland)"
fi

# Convert cycling to PMTiles (green lines)
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/cycling.geojson"; then
  echo "5. Converting cycling.pmtiles..."
  tippecanoe -o "$TMP_DIR/cycling.mbtiles" \
    -Z4 -z14 --force \
    -l "cycling" \
    -n "Cycling Routes" \
    -A "Cycling routes (other locations only)" \
    "$TMP_DIR/cycling.geojson"

  pmtiles convert "$TMP_DIR/cycling.mbtiles" "$TILES_DIR/cycling.pmtiles"
  rm "$TMP_DIR/cycling.mbtiles"
  echo "   ✓ cycling.pmtiles ($(du -h "$TILES_DIR/cycling.pmtiles" | cut -f1))"
else
  echo "   ⚠ No cycling routes to export (expected if all in Sacramento/Portland)"
fi

# Clean up temp files
echo ""
echo "Cleaning up temporary files..."
rm -f "$TMP_DIR/blocks_incomplete.geojson"
rm -f "$TMP_DIR/blocks_complete.geojson"
rm -f "$TMP_DIR/runs.geojson"
rm -f "$TMP_DIR/walks.geojson"
rm -f "$TMP_DIR/cycling.geojson"

echo ""
echo "======================================"
echo "Tile Export Complete!"
echo "======================================"
echo ""
echo "Tiles exported to: $TILES_DIR/"
ls -lh "$TILES_DIR"/*.pmtiles 2>/dev/null || echo "No tiles found"
echo ""
echo "Total size: $(du -sh "$TILES_DIR" | cut -f1)"
