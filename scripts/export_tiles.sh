#!/usr/bin/env bash
set -euo pipefail

# Simple exporter: refresh -> pull streets_unrun from Supabase -> build PMTiles -> upload to 'tiles' bucket.
# Requirements: ogr2ogr (GDAL), tippecanoe, curl
# Configure via .env at repo root (auto-loaded) or environment variables:
#   PGHOST, PGPORT=6543, PGDATABASE=postgres, PGUSER=postgres.<project-ref>, PGPASSWORD
#   SUPABASE_URL=https://<ref>.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY=...  (for RPC + upload)
#   DEST=streets_unrun.pmtiles
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
DEST=${DEST:-streets_unrun.pmtiles}
# Create a unique work dir and clean up on exit
WORK=$(mktemp -d "${TMPDIR:-/tmp}/runmap_export.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT

# 0) Refresh heavy layers using local helper to avoid HTTP timeout
REFRESH_MODE=${REFRESH:-all}
if [ "$REFRESH_MODE" != "none" ]; then
  echo "[0/4] Refreshing materialized views ($REFRESH_MODE) via psql"
  "${SCRIPT_DIR}/refresh_all.sh" "$REFRESH_MODE"
fi

# 1) Export streets_unrun → GeoJSON
echo "[1/4] Export streets_unrun → GeoJSON"
CONN="PG:host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} password=${PGPASSWORD} sslmode=require target_session_attrs=read-write"
ogr2ogr -f GeoJSON "$WORK/streets_unrun.geojson" "$CONN" -sql "SELECT street_id,name,geom FROM runmap.streets_unrun" -nln streets_unrun

# 2) Build PMTiles with tippecanoe
echo "[2/4] Build PMTiles with tippecanoe"
tippecanoe -o "$WORK/streets_unrun.pmtiles" -l streets_unrun -zg --drop-densest-as-needed "$WORK/streets_unrun.geojson" --force

# 3) Upload to Supabase Storage 'tiles' bucket as $DEST
echo "[3/4] Upload to Supabase Storage 'tiles' bucket as $DEST"
curl -sS -X POST "${SUPABASE_URL}/storage/v1/object/tiles/${DEST}" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "x-upsert: true" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"$WORK/streets_unrun.pmtiles"

# 4) Done
echo "[4/4] Done. Public URL (if bucket is public):"
echo "${SUPABASE_URL}/storage/v1/object/public/tiles/${DEST}"
