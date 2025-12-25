#!/bin/bash
# Slow path for Mac Studio - uses local user instead of runmap_user

set -e

# Limit CPU and I/O priority to prevent server overload
renice -n 10 $$ > /dev/null 2>&1 || true
ionice -c 3 -p $$ > /dev/null 2>&1 || true

TILES_DIR=${TILES_DIR:-~/runmap/tiles}
TMP_DIR=${TMP_DIR:-/tmp}

# Cleanup
rm -f "$TMP_DIR/coverage.*" "$TMP_DIR/streets_unrun.*"

echo "Starting slow path: refreshing materialized views..."

# Refresh materialized views one at a time with memory limits (Mac - no user specified)
echo "Refreshing runs_merged..."
psql -d runmap -c "SET work_mem='256MB'; REFRESH MATERIALIZED VIEW runmap.runs_merged;"

echo "Refreshing coverage_buffer..."
psql -d runmap -c "SET work_mem='512MB'; REFRESH MATERIALIZED VIEW runmap.coverage_buffer;"

echo "Refreshing streets_unrun..."
psql -d runmap -c "SET work_mem='512MB'; REFRESH MATERIALIZED VIEW runmap.streets_unrun;"

echo "Refreshing coverage_stats..."
psql -d runmap -c "SET work_mem='256MB'; REFRESH MATERIALIZED VIEW runmap.coverage_stats;"

echo "Exporting coverage layers..."

# Export coverage buffer (Mac - no password needed)
ogr2ogr -f GeoJSON "$TMP_DIR/coverage.geojson" \
  PG:"dbname=runmap" \
  -sql "SELECT gid, geom FROM runmap.coverage_buffer"

# Export unrun streets
ogr2ogr -f GeoJSON "$TMP_DIR/streets_unrun.geojson" \
  PG:"dbname=runmap" \
  -sql "SELECT ogc_fid, name, highway, length_m, geom FROM runmap.streets_unrun"

echo "Generating tiles..."

# Coverage tiles
tippecanoe -o "$TMP_DIR/coverage.mbtiles" \
  -Z4 -z14 \
  --force \
  "$TMP_DIR/coverage.geojson"
pmtiles convert "$TMP_DIR/coverage.mbtiles" "$TILES_DIR/coverage.pmtiles"

# Streets unrun tiles
tippecanoe -o "$TMP_DIR/streets_unrun.mbtiles" \
  -Z4 -z14 \
  --force \
  "$TMP_DIR/streets_unrun.geojson"
pmtiles convert "$TMP_DIR/streets_unrun.mbtiles" "$TILES_DIR/streets_unrun.pmtiles"

# Cleanup
rm -f "$TMP_DIR/coverage.*" "$TMP_DIR/streets_unrun.*"

echo "✓ Slow path complete: coverage.pmtiles + streets_unrun.pmtiles"
