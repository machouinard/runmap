#!/bin/bash
# Export tiles using incremental coverage data

set -e

rm -f /tmp/coverage.* /tmp/streets_*.* /tmp/runs.*

TILES_DIR=${TILES_DIR:-~/runmap/tiles}
TMP_DIR=${TMP_DIR:-/tmp}

echo "Exporting runs, coverage and street layers..."

# Export runs
ogr2ogr -f GeoJSON "$TMP_DIR/runs.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user" \
  -sql "SELECT id::text AS gid, geom FROM runmap.runs_raw"

# Export coverage (per-run buffers, tiler handles overlaps)
ogr2ogr -f GeoJSON "$TMP_DIR/coverage.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user" \
  -sql "SELECT gid, geom FROM runmap.coverage_buffer"

# Export unrun streets (<5% coverage)
ogr2ogr -f GeoJSON "$TMP_DIR/streets_unrun.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user" \
  -sql "SELECT ogc_fid, name, highway, length_m, coverage_pct, geom FROM runmap.streets_unrun"

# Export partial streets (5-95% coverage)
ogr2ogr -f GeoJSON "$TMP_DIR/streets_partial.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user" \
  -sql "SELECT ogc_fid, name, highway, length_m, coverage_pct, geom FROM runmap.streets_partial"

# Export complete streets (>=95% coverage)
ogr2ogr -f GeoJSON "$TMP_DIR/streets_complete.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user" \
  -sql "SELECT ogc_fid, name, highway, length_m, coverage_pct, geom FROM runmap.streets_complete"

# Export partial streets (5-95% coverage)
ogr2ogr -f GeoJSON "$TMP_DIR/streets_partial.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user" \
  -sql "SELECT ogc_fid, name, highway, length_m, coverage_pct, geom FROM runmap.streets_partial"

# Export complete streets (>=95% coverage)
ogr2ogr -f GeoJSON "$TMP_DIR/streets_complete.geojson" \
  PG:"host=localhost dbname=runmap user=runmap_user" \
  -sql "SELECT ogc_fid, name, highway, length_m, coverage_pct, geom FROM runmap.streets_complete"

echo "Generating tiles..."

# Runs tiles (skip if empty)
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/runs.geojson"; then
  tippecanoe -o "$TMP_DIR/runs.mbtiles" \
    -Z4 -z14 \
    --force \
    "$TMP_DIR/runs.geojson"
  pmtiles convert "$TMP_DIR/runs.mbtiles" "$TILES_DIR/runs.pmtiles"
else
  echo "Skipping runs.pmtiles (no runs in database)"
fi

# Coverage tiles (skip if empty)
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/coverage.geojson"; then
  tippecanoe -o "$TMP_DIR/coverage.mbtiles" \
    -Z4 -z14 \
    --force \
    "$TMP_DIR/coverage.geojson"
  pmtiles convert "$TMP_DIR/coverage.mbtiles" "$TILES_DIR/coverage.pmtiles"
else
  echo "Skipping coverage.pmtiles (no coverage buffer)"
fi

# Streets unrun tiles
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/streets_unrun.geojson"; then
  tippecanoe -o "$TMP_DIR/streets_unrun.mbtiles" -Z4 -z14 --force "$TMP_DIR/streets_unrun.geojson"
  pmtiles convert "$TMP_DIR/streets_unrun.mbtiles" "$TILES_DIR/streets_unrun.pmtiles"
fi

# Streets partial tiles  
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/streets_partial.geojson"; then
  tippecanoe -o "$TMP_DIR/streets_partial.mbtiles" -Z4 -z14 --force "$TMP_DIR/streets_partial.geojson"
  pmtiles convert "$TMP_DIR/streets_partial.mbtiles" "$TILES_DIR/streets_partial.pmtiles"
fi

# Streets complete tiles
if grep -q '"type"[[:space:]]*:[[:space:]]*"Feature"' "$TMP_DIR/streets_complete.geojson"; then
  tippecanoe -o "$TMP_DIR/streets_complete.mbtiles" -Z4 -z14 --force "$TMP_DIR/streets_complete.geojson"
  pmtiles convert "$TMP_DIR/streets_complete.mbtiles" "$TILES_DIR/streets_complete.pmtiles"
fi

# Cleanup
rm -f "$TMP_DIR/coverage.*" "$TMP_DIR/streets_*.*" "$TMP_DIR/runs.*"

echo "✓ Tiles exported"
