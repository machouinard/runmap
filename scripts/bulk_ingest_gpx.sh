#!/usr/bin/env bash
set -euo pipefail

# Bulk-ingest GPX files via the gpx_ingest_upload Edge Function.
# - Reads .env at repo root for SUPABASE_URL and SUPABASE_ANON_KEY
# - Default source directory: ./WorkOutDoors (change with GPX_DIR)
#
# Usage:
#   ./scripts/bulk_ingest_gpx.sh                 # ingest all .gpx under ./WorkOutDoors
#   GPX_DIR=/path/to/gpx ./scripts/bulk_ingest_gpx.sh
#
# Notes:
# - The Edge Function dedupes by content_hash, so re-running is safe.
# - After ingest, run: ./scripts/refresh_all.sh all && REFRESH=none ./scripts/export_tiles.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -f "${REPO_ROOT}/.env" ]; then
  set -a; # export
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

: "${SUPABASE_URL:?Set SUPABASE_URL or add to .env}"
: "${SUPABASE_ANON_KEY:?Set SUPABASE_ANON_KEY or add to .env}"
FUNCTION_URL="${SUPABASE_URL%/}/functions/v1/gpx_ingest_upload"

GPX_DIR=${GPX_DIR:-"${REPO_ROOT}/WorkOutDoors"}
if [ ! -d "$GPX_DIR" ]; then
  echo "GPX_DIR not found: $GPX_DIR" >&2
  exit 1
fi

shopt -s nullglob
mapfile -t files < <(find "$GPX_DIR" -type f -name '*.gpx' -print | sort)
if [ ${#files[@]} -eq 0 ]; then
  echo "No .gpx files found under $GPX_DIR" >&2
  exit 1
fi

echo "Ingesting ${#files[@]} GPX files from: $GPX_DIR"

ok=0; skip=0; err=0
for f in "${files[@]}"; do
  base=$(basename "$f")
  # Use curl multipart form: file + filename; let server auto-generate path and infer metadata
  res=$(curl -sS -X POST "$FUNCTION_URL" \
    -H "Authorization: Bearer ${SUPABASE_ANON_KEY}" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@${f}" \
    -F "filename=${base}" || true)

  if echo "$res" | grep -q '"id"'; then
    echo "[OK] $base -> $(echo "$res" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    ok=$((ok+1))
  elif echo "$res" | grep -qi 'duplicate\|conflict\|unique'; then
    echo "[SKIP] $base (duplicate)"
    skip=$((skip+1))
  else
    echo "[ERR] $base -> $res" >&2
    err=$((err+1))
  fi
  # Gentle pacing to avoid rate limits
  sleep 0.2
done

echo "Done. ok=$ok skip=$skip err=$err"
