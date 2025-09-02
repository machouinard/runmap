#!/usr/bin/env bash
set -euo pipefail

# Build and upload PMTiles for unrun, runs, and buffer on the droplet.
# Requires: ogr2ogr (GDAL), tippecanoe, curl
# Env (read from /etc/runmap/runmap-buffer.env or exported in the shell):
#   PGHOST, PGPORT=5432, PGDATABASE, PGUSER, PGPASSWORD
#   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
#   DEST_UNRUN (default streets_unrun.pmtiles)
#   DEST_RUNS  (default runs_collect.pmtiles)
#   DEST_BUFFER(default coverage_buffer.pmtiles)

: "${PGHOST:?PGHOST required}"
: "${PGPORT:?PGPORT required}"
: "${PGDATABASE:?PGDATABASE required}"
: "${PGUSER:?PGUSER required}"
: "${PGPASSWORD:?PGPASSWORD required}"
: "${SUPABASE_URL:?SUPABASE_URL required}"
: "${SUPABASE_SERVICE_ROLE_KEY:?SUPABASE_SERVICE_ROLE_KEY required}"

DEST_UNRUN=${DEST_UNRUN:-streets_unrun.pmtiles}
DEST_RUNS=${DEST_RUNS:-runs_collect.pmtiles}
DEST_BUFFER=${DEST_BUFFER:-coverage_buffer.pmtiles}

WORK=$(mktemp -d "/tmp/runmap_tiles.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT

CONN="PG:host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} password=${PGPASSWORD} sslmode=require target_session_attrs=read-write"

# 1) Export GeoJSONs
ogr2ogr -f GeoJSON "$WORK/streets_unrun.geojson" "$CONN" -sql "SELECT gid,name,geom FROM runmap.streets_unrun" -nln streets_unrun
ogr2ogr -f GeoJSON "$WORK/runs.geojson"         "$CONN" -sql "SELECT geom FROM runmap.runs_raw WHERE geom IS NOT NULL" -nln runs
ogr2ogr -f GeoJSON "$WORK/buffer.geojson"       "$CONN" -sql "SELECT gid,geom FROM runmap.coverage_buffer_current" -nln coverage_buffer

# 2) Build PMTiles
# Keep detail at city zooms
tippecanoe -o "$WORK/streets_unrun.pmtiles" -l streets_unrun -Z 10 -z 16 --no-feature-limit --no-tile-size-limit --extend-zooms-if-still-dropping "$WORK/streets_unrun.geojson" --force
# runs
tippecanoe -o "$WORK/runs_collect.pmtiles" -l runs_collect -Z 10 -z 16 --no-feature-limit --no-tile-size-limit --extend-zooms-if-still-dropping "$WORK/runs.geojson" --force
# buffer
tippecanoe -o "$WORK/coverage_buffer.pmtiles" -l coverage_buffer -zg "$WORK/buffer.geojson" --force

# 3) Upload
curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/tiles/${DEST_UNRUN}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "x-upsert: true" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$WORK/streets_unrun.pmtiles"

curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/tiles/${DEST_RUNS}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "x-upsert: true" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$WORK/runs_collect.pmtiles"

curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/tiles/${DEST_BUFFER}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "x-upsert: true" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$WORK/coverage_buffer.pmtiles"

# 4) Output URLs
echo "unrun:  ${SUPABASE_URL}/storage/v1/object/public/tiles/${DEST_UNRUN}"
echo "runs:   ${SUPABASE_URL}/storage/v1/object/public/tiles/${DEST_RUNS}"
echo "buffer: ${SUPABASE_URL}/storage/v1/object/public/tiles/${DEST_BUFFER}"
