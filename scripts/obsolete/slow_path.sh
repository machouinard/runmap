#!/bin/bash
# Slow path: Refresh materialized views and export coverage layers

set -e

# Limit CPU and I/O priority to prevent server overload
renice -n 10 $$ > /dev/null 2>&1 || true
ionice -c 3 -p $$ > /dev/null 2>&1 || true

TILES_DIR=${TILES_DIR:-/home/mark/runmap/tiles}
TMP_DIR=${TMP_DIR:-/tmp}

# Cleanup
rm -f "$TMP_DIR/coverage.*" "$TMP_DIR/streets_unrun.*"

echo "Starting slow path: refreshing materialized views..."

# Refresh materialized views one at a time with memory limits
echo "Refreshing runs_merged..."
psql -U runmap_user -d runmap -h localhost -c "SET work_mem='256MB'; REFRESH MATERIALIZED VIEW runmap.runs_merged;"

echo "Refreshing coverage_buffer..."
psql -U runmap_user -d runmap -h localhost -c "SET work_mem='512MB'; REFRESH MATERIALIZED VIEW runmap.coverage_buffer;"

echo "Refreshing streets_unrun..."
psql -U runmap_user -d runmap -h localhost -c "SET work_mem='512MB'; REFRESH MATERIALIZED VIEW runmap.streets_unrun;"

echo "Refreshing coverage_stats..."
psql -U runmap_user -d runmap -h localhost -c "SET work_mem='256MB'; REFRESH MATERIALIZED VIEW runmap.coverage_stats;"

echo "Exporting coverage layers..."

# Export coverage buffer
ogr2ogr -f GeoJSON "$TMP_DIR/coverage.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user password=fucker" \
  -sql "SELECT gid, geom FROM runmap.coverage_buffer"

# Export unrun streets
ogr2ogr -f GeoJSON "$TMP_DIR/streets_unrun.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user password=fucker" \
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

# Update version
psql -U runmap_user -d runmap -h localhost -c "UPDATE runmap.settings SET value = to_jsonb(NOW()::text) WHERE key = 'tiles_version';"

# Cleanup
rm -f "$TMP_DIR/coverage.*" "$TMP_DIR/streets_unrun.*"

echo "✓ Slow path complete: coverage.pmtiles + streets_unrun.pmtiles"
