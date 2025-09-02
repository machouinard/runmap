#!/usr/bin/env bash
set -euo pipefail

# Simple exporter: refresh -> pull layers from Supabase -> build PMTiles -> upload to 'tiles' bucket.
# Requirements: ogr2ogr (GDAL), tippecanoe, curl
# Configure via .env at repo root (auto-loaded) or environment variables:
#   PGHOST, PGPORT=6543, PGDATABASE=postgres, PGUSER=postgres.<project-ref>, PGPASSWORD
#   SUPABASE_URL=https://<ref>.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY=...  (for RPC + upload)
#   DEST_UNRUN=streets_unrun.pmtiles (or legacy DEST)
#   DEST_RUNS=runs_collect.pmtiles
#   DEST_BUFFER=coverage_buffer.pmtiles
#   TMPDIR (optional)

# Auto-load .env from repo root (works regardless of current working directory)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -f "${REPO_ROOT}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

: "${PGHOST:?Set PGHOST or add to .env}"
: "${PGPORT:=6543}"
: "${PGDATABASE:=postgres}"
: "${PGUSER:?Set PGUSER (e.g., postgres.<ref>) or add to .env}"
: "${PGPASSWORD:?Set PGPASSWORD or add to .env}"
: "${SUPABASE_URL:?Set SUPABASE_URL or add to .env}"
: "${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY or add to .env}"
DEST_UNRUN=${DEST_UNRUN:-${DEST:-streets_unrun.pmtiles}}
DEST_RUNS=${DEST_RUNS:-runs_collect.pmtiles}
DEST_BUFFER=${DEST_BUFFER:-coverage_buffer.pmtiles}
# Create a unique work dir and clean up on exit
WORK=$(mktemp -d "${TMPDIR:-/tmp}/runmap_export.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
 
# 0) Refresh heavy layers using local helper to avoid HTTP timeout
REFRESH_MODE=${REFRESH:-all}
if [ "$REFRESH_MODE" != "none" ]; then
  echo "[0/6] Refreshing materialized views ($REFRESH_MODE) via psql"
 "${SCRIPT_DIR}/refresh_all.sh" "$REFRESH_MODE"
fi
 
# 1) Export streets_unrun → GeoJSON
echo "[1/6] Export streets_unrun → GeoJSON"
CONN="PG:host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} password=${PGPASSWORD} sslmode=require target_session_attrs=read-write"
ogr2ogr -f GeoJSON "$WORK/streets_unrun.geojson" "$CONN" -sql "SELECT gid,name,geom FROM runmap.streets_unrun" -nln streets_unrun
 
# 2) Export runs_collect → GeoJSON (if present)
echo "[2/6] Export runs_collect → GeoJSON"
set +e
ogr2ogr -f GeoJSON "$WORK/runs_collect.geojson" "$CONN" -sql "SELECT geom FROM runmap.runs_raw WHERE geom IS NOT NULL" -nln runs_collect
RUNS_STATUS=$?
set -e

# 3) Export coverage_buffer_current → GeoJSON
echo "[3/6] Export coverage_buffer_current → GeoJSON"
ogr2ogr -f GeoJSON "$WORK/coverage_buffer.geojson" "$CONN" -sql "SELECT gid,geom FROM runmap.coverage_buffer_current" -nln coverage_buffer
 
# 4) Build MBTiles then convert to PMTiles
echo "[4/6] Build MBTiles then PMTiles"
# streets_unrun
# Keep all features: do not drop densest; allow big tiles for fidelity on dense grids
tippecanoe -o "$WORK/streets_unrun.mbtiles" -l streets_unrun -Z 10 -z 16 --no-feature-limit --no-tile-size-limit --extend-zooms-if-still-dropping "$WORK/streets_unrun.geojson" --force
pmtiles convert "$WORK/streets_unrun.mbtiles" "$WORK/streets_unrun.pmtiles"
# runs (optional)
if [ $RUNS_STATUS -eq 0 ]; then
  tippecanoe -o "$WORK/runs_collect.mbtiles" -l runs_collect -Z 10 -z 16 --no-feature-limit --no-tile-size-limit --extend-zooms-if-still-dropping "$WORK/runs_collect.geojson" --force
  pmtiles convert "$WORK/runs_collect.mbtiles" "$WORK/runs_collect.pmtiles"
else
  echo "runs_collect export failed or not present; skipping runs PMTiles"
fi
# buffer (auto zoom)
tippecanoe -o "$WORK/coverage_buffer.mbtiles" -l coverage_buffer -zg "$WORK/coverage_buffer.geojson" --force
pmtiles convert "$WORK/coverage_buffer.mbtiles" "$WORK/coverage_buffer.pmtiles"
 
# 5) Upload to Supabase Storage 'tiles' bucket
echo "[5/6] Upload to Supabase Storage 'tiles' bucket"
# unrun
curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/tiles/${DEST_UNRUN}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "x-upsert: true" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$WORK/streets_unrun.pmtiles"
# runs (optional)
if [ -f "$WORK/runs_collect.pmtiles" ]; then
  curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/tiles/${DEST_RUNS}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "x-upsert: true" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$WORK/runs_collect.pmtiles"
fi
# buffer
curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/tiles/${DEST_BUFFER}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "x-upsert: true" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$WORK/coverage_buffer.pmtiles"

# version.json for cache-busting
printf '{"v":"%s"}' "$TILES_VERSION" > "$WORK/version.json"
curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/tiles/version.json" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "x-upsert: true" \
  -H "Content-Type: application/json" \
  --data-binary @"$WORK/version.json"
 
# 6) Done
echo "[6/6] Done. Public URLs (if bucket is public):"
TILES_VERSION=${TILES_VERSION:-$(date -u +%Y%m%dT%H%MZ)}
echo "unrun:   ${SUPABASE_URL}/storage/v1/object/public/tiles/${DEST_UNRUN}?v=${TILES_VERSION}"
echo "runs:    ${SUPABASE_URL}/storage/v1/object/public/tiles/${DEST_RUNS}?v=${TILES_VERSION}"
echo "buffer:  ${SUPABASE_URL}/storage/v1/object/public/tiles/${DEST_BUFFER}?v=${TILES_VERSION}"
echo "hint: set VITE_TILES_VERSION=${TILES_VERSION} in web/.env.local to bust cache"}

