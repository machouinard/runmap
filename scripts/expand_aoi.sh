#!/bin/bash
# ============================================================================
# Expand AOI - Import streets from a new area
# ============================================================================
#
# This script expands the coverage area by:
# 1. Using the AOI polygon (from database or provided) to clip a PBF file
# 2. Importing new streets from the clipped area
# 3. Creating blocks, segments, and initializing coverage tracking
# 4. Optionally reprocessing runs to mark segments in new area
# 5. Exporting updated tiles
#
# Prerequisites:
#   - osmium-tool (brew install osmium-tool / apt install osmium-tool)
#   - ogr2ogr (GDAL)
#   - PostgreSQL client tools (psql)
#
# Usage:
#   ./expand_aoi.sh <pbf_file> [options]
#
# Options:
#   --aoi-geojson <file>   Use this GeoJSON polygon instead of database AOI
#   --replace-aoi          Replace database AOI with the new polygon
#   --reprocess-runs       Reprocess all runs to cover new segments
#   --skip-tiles           Skip tile export
#   --dry-run              Show what would be done without making changes
#
# Examples:
#   # Expand using current database AOI
#   ./expand_aoi.sh sacramento-expanded.osm.pbf
#
#   # Expand with a new AOI polygon and replace the database AOI
#   ./expand_aoi.sh sacramento-metro.osm.pbf --aoi-geojson metro_boundary.geojson --replace-aoi
#
#   # Expand and reprocess runs (if you've already run in the new area)
#   ./expand_aoi.sh sacramento-expanded.osm.pbf --reprocess-runs
#
# ============================================================================

set -e

# Load environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

# Parse arguments
PBF_FILE=""
AOI_GEOJSON=""
REPLACE_AOI=false
REPROCESS_RUNS=false
SKIP_TILES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --aoi-geojson)
      AOI_GEOJSON="$2"
      shift 2
      ;;
    --replace-aoi)
      REPLACE_AOI=true
      shift
      ;;
    --reprocess-runs)
      REPROCESS_RUNS=true
      shift
      ;;
    --skip-tiles)
      SKIP_TILES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      head -50 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      if [ -z "$PBF_FILE" ]; then
        PBF_FILE="$1"
      else
        echo "ERROR: Unknown argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate arguments
if [ -z "$PBF_FILE" ]; then
  echo "ERROR: PBF file is required"
  echo "Usage: $0 <pbf_file> [options]"
  echo "Use --help for more information"
  exit 1
fi

if [ ! -f "$PBF_FILE" ]; then
  echo "ERROR: PBF file not found: $PBF_FILE"
  exit 1
fi

if [ -n "$AOI_GEOJSON" ] && [ ! -f "$AOI_GEOJSON" ]; then
  echo "ERROR: AOI GeoJSON file not found: $AOI_GEOJSON"
  exit 1
fi

# Check for required tools
for tool in osmium ogr2ogr psql; do
  if ! command -v $tool &> /dev/null; then
    echo "ERROR: Required tool not found: $tool"
    if [ "$tool" = "osmium" ]; then
      echo "Install with: brew install osmium-tool (macOS) or apt install osmium-tool (Linux)"
    fi
    exit 1
  fi
done

echo ""
echo "========================================="
echo "Expand AOI - Import New Streets"
echo "========================================="
echo ""
echo "PBF file: $PBF_FILE"
echo "AOI source: ${AOI_GEOJSON:-database}"
echo "Replace AOI: $REPLACE_AOI"
echo "Reprocess runs: $REPROCESS_RUNS"
echo "Skip tiles: $SKIP_TILES"
echo "Dry run: $DRY_RUN"
echo ""

# Create temp directory
mkdir -p "$TMP_DIR"

# ============================================================================
# Step 1: Get AOI polygon
# ============================================================================

echo "Step 1: Getting AOI polygon..."

AOI_CLIP_FILE="$TMP_DIR/aoi_clip.geojson"

if [ -n "$AOI_GEOJSON" ]; then
  echo "  Using provided GeoJSON: $AOI_GEOJSON"
  cp "$AOI_GEOJSON" "$AOI_CLIP_FILE"
else
  echo "  Exporting from database..."
  ogr2ogr -f GeoJSON "$AOI_CLIP_FILE" \
    PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
    -sql "SELECT ST_Transform(geom, 4326) as geometry FROM runmap.aoi LIMIT 1" \
    -t_srs EPSG:4326

  # Check if AOI exists
  if ! grep -q '"type"' "$AOI_CLIP_FILE"; then
    echo "ERROR: No AOI found in database. Please provide --aoi-geojson"
    exit 1
  fi
fi

echo "  ✓ AOI polygon ready"
echo ""

# ============================================================================
# Step 2: Clip PBF to AOI
# ============================================================================

echo "Step 2: Clipping PBF to AOI boundary..."

CLIPPED_PBF="$TMP_DIR/clipped_streets.osm.pbf"

if [ "$DRY_RUN" = true ]; then
  echo "  [DRY RUN] Would clip $PBF_FILE to AOI boundary"
else
  # Extract polygon coordinates for osmium
  # osmium needs a polygon file in a specific format
  AOI_POLY="$TMP_DIR/aoi.poly"

  # Convert GeoJSON to osmium poly format
  python3 - "$AOI_CLIP_FILE" "$AOI_POLY" << 'PYTHON_SCRIPT'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

# Get coordinates from GeoJSON
if data['type'] == 'FeatureCollection':
    coords = data['features'][0]['geometry']['coordinates'][0]
elif data['type'] == 'Feature':
    coords = data['geometry']['coordinates'][0]
else:
    coords = data['coordinates'][0]

# Write osmium poly format
with open(sys.argv[2], 'w') as f:
    f.write("aoi\n")
    f.write("1\n")
    for lon, lat in coords:
        f.write(f"   {lon}   {lat}\n")
    f.write("END\n")
    f.write("END\n")
PYTHON_SCRIPT

  # Clip the PBF
  osmium extract -p "$AOI_POLY" "$PBF_FILE" -o "$CLIPPED_PBF" --overwrite

  echo "  ✓ Clipped PBF created: $(du -h "$CLIPPED_PBF" | cut -f1)"
fi
echo ""

# ============================================================================
# Step 3: Import streets from clipped PBF
# ============================================================================

echo "Step 3: Importing streets from clipped PBF..."

if [ "$DRY_RUN" = true ]; then
  echo "  [DRY RUN] Would import streets to runmap.streets_new_import"
else
  # Import to temp table
  ogr2ogr -f "PostgreSQL" \
    PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
    "$CLIPPED_PBF" \
    -sql "SELECT osm_id, name, highway FROM lines WHERE highway IN ('residential', 'primary', 'secondary', 'tertiary', 'unclassified', 'living_street', 'pedestrian', 'footway', 'path', 'cycleway', 'track')" \
    -nln runmap.streets_new_import \
    -t_srs EPSG:4326 \
    -lco GEOMETRY_NAME=geom \
    -overwrite

  # Count imported streets
  NEW_COUNT=$(psql -d "$DB_NAME" -t -A -c "SELECT COUNT(*) FROM runmap.streets_new_import;")
  echo "  ✓ Imported $NEW_COUNT streets to temp table"
fi
echo ""

# ============================================================================
# Step 4: Merge new streets (avoiding duplicates)
# ============================================================================

echo "Step 4: Merging new streets into reference tables..."

if [ "$DRY_RUN" = true ]; then
  echo "  [DRY RUN] Would merge streets and create blocks/segments"
else
  psql -d "$DB_NAME" << 'EOF'
-- Count streets before
\echo '  Streets before merge:'
SELECT COUNT(*) as existing_streets FROM runmap.streets_reference;

-- Add new streets (skip duplicates by osm_id)
INSERT INTO runmap.streets_reference (osm_id, name, highway, geom, runnable)
SELECT osm_id, name, highway, geom, TRUE
FROM runmap.streets_new_import
WHERE osm_id NOT IN (SELECT osm_id FROM runmap.streets_reference WHERE osm_id IS NOT NULL)
  AND highway != 'service';

-- Count how many were added
\echo '  New streets added to streets_reference:'
SELECT COUNT(*) as added FROM runmap.streets_new_import
WHERE osm_id NOT IN (SELECT osm_id FROM runmap.streets_reference WHERE osm_id IS NOT NULL)
  AND highway != 'service';

-- Add to UTM-projected table
INSERT INTO runmap.streets_reference_32610 (name, highway, geom_32610, total_length_m)
SELECT
  name,
  highway,
  ST_Transform(geom, 32610),
  ST_Length(ST_Transform(geom, 32610))
FROM runmap.streets_new_import
WHERE osm_id NOT IN (
  SELECT sr.osm_id FROM runmap.streets_reference sr
  JOIN runmap.streets_reference_32610 sr32 ON sr.name = sr32.name AND sr.highway = sr32.highway
  WHERE sr.osm_id IS NOT NULL
)
  AND highway != 'service';

-- Cleanup temp table
DROP TABLE IF EXISTS runmap.streets_new_import;
EOF

  echo "  ✓ Streets merged"
fi
echo ""

# ============================================================================
# Step 5: Create blocks for new streets
# ============================================================================

echo "Step 5: Creating blocks for new streets..."

if [ "$DRY_RUN" = true ]; then
  echo "  [DRY RUN] Would create blocks for new streets"
else
  psql -d "$DB_NAME" << 'EOF'
-- Count new streets that need blocks
DO $$
DECLARE
  v_new_count INT;
BEGIN
  SELECT COUNT(*) INTO v_new_count
  FROM runmap.streets_reference_32610 s
  WHERE NOT EXISTS (
    SELECT 1 FROM runmap.streets_blocks_32610 b
    WHERE b.parent_ogc_fid = s.ogc_fid
  );

  RAISE NOTICE '  Creating blocks for % new streets...', v_new_count;
END $$;

-- Add blocks for new streets
-- (Simplified: treats each street as one block)
INSERT INTO runmap.streets_blocks_32610 (name, highway, geom_32610, block_length_m, parent_ogc_fid)
SELECT
  s.name,
  s.highway,
  s.geom_32610,
  s.total_length_m,
  s.ogc_fid
FROM runmap.streets_reference_32610 s
WHERE NOT EXISTS (
  SELECT 1 FROM runmap.streets_blocks_32610 b
  WHERE b.parent_ogc_fid = s.ogc_fid
);

\echo '  ✓ Blocks created'
EOF
fi
echo ""

# ============================================================================
# Step 6: Segment new blocks and initialize tracking
# ============================================================================

echo "Step 6: Creating segments and initializing coverage tracking..."

if [ "$DRY_RUN" = true ]; then
  echo "  [DRY RUN] Would create 5m segments and initialize tracking"
else
  psql -d "$DB_NAME" << 'EOF'
-- Segment new blocks into ~5m pieces using ST_DumpSegments
-- First densify vertices with ST_Segmentize, then extract each segment
INSERT INTO runmap.block_segments (block_id, segment_geom, segment_length_m)
SELECT
  b.block_id,
  (ST_DumpSegments(ST_Segmentize(b.geom_32610, 5.0))).geom AS segment_geom,
  ST_Length((ST_DumpSegments(ST_Segmentize(b.geom_32610, 5.0))).geom) AS segment_length_m
FROM runmap.streets_blocks_32610 b
WHERE NOT EXISTS (
  SELECT 1 FROM runmap.block_segments bs
  WHERE bs.block_id = b.block_id
);

\echo '  Segments created'

-- Initialize visited flags for new segments (all FALSE)
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE
FROM runmap.block_segments
WHERE segment_id NOT IN (SELECT segment_id FROM runmap.block_segment_visited);

\echo '  Visited flags initialized'

-- Initialize aggregate coverage for new blocks (0%)
INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
SELECT
  block_id,
  0,
  SUM(segment_length_m)
FROM runmap.block_segments
WHERE block_id NOT IN (SELECT block_id FROM runmap.block_coverage_segments)
GROUP BY block_id;

\echo '  Coverage tracking initialized'

-- Show summary
\echo ''
\echo '  Summary:'
SELECT
  COUNT(*) as new_blocks,
  ROUND(SUM(total_length_m)::numeric, 0) as new_length_m,
  ROUND(SUM(total_length_m)::numeric / 1609.34, 1) as new_miles
FROM runmap.block_coverage_segments
WHERE visited_length_m = 0;
EOF
fi
echo ""

# ============================================================================
# Step 7: Update AOI in database (if requested)
# ============================================================================

if [ "$REPLACE_AOI" = true ] && [ -n "$AOI_GEOJSON" ]; then
  echo "Step 7: Updating AOI in database..."

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would replace database AOI with $AOI_GEOJSON"
  else
    psql -d "$DB_NAME" << EOF
-- Clear existing AOI
DELETE FROM runmap.aoi WHERE name = 'sacramento';

-- Insert new AOI from the GeoJSON we used for clipping
EOF

    # Import the GeoJSON polygon to the AOI table
    ogr2ogr -f "PostgreSQL" \
      PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
      "$AOI_CLIP_FILE" \
      -nln runmap.aoi \
      -t_srs EPSG:4326 \
      -lco GEOMETRY_NAME=geom \
      -sql "SELECT 'sacramento' as name, geometry FROM (SELECT * FROM \"$(basename "$AOI_CLIP_FILE" .geojson)\")" \
      -append

    echo "  ✓ AOI updated in database"
  fi
  echo ""
fi

# ============================================================================
# Step 8: Reprocess runs (if requested)
# ============================================================================

if [ "$REPROCESS_RUNS" = true ]; then
  echo "Step 8: Reprocessing runs to cover new segments..."

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would run: bash scripts/rebuild_all_coverage.sh"
  else
    bash "$SCRIPT_DIR/rebuild_all_coverage.sh"
  fi
  echo ""
fi

# ============================================================================
# Step 9: Export tiles
# ============================================================================

if [ "$SKIP_TILES" = false ]; then
  echo "Step 9: Exporting tiles..."

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would run: bash scripts/export_tiles_blocks.sh"
  else
    bash "$SCRIPT_DIR/export_tiles_blocks.sh"

    # Update tiles version
    psql -d "$DB_NAME" -c "UPDATE runmap.settings SET value = to_jsonb(extract(epoch from now())::bigint) WHERE key = 'tiles_version';"
    echo "  ✓ Tiles version updated"
  fi
  echo ""
fi

# ============================================================================
# Cleanup
# ============================================================================

echo "Cleaning up temporary files..."
rm -f "$TMP_DIR/aoi_clip.geojson"
rm -f "$TMP_DIR/aoi.poly"
rm -f "$TMP_DIR/clipped_streets.osm.pbf"
echo ""

# ============================================================================
# Done
# ============================================================================

echo "========================================="
echo "AOI Expansion Complete!"
echo "========================================="
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "This was a dry run. No changes were made."
  echo "Remove --dry-run to actually perform the expansion."
else
  echo "New streets have been imported and are ready for coverage tracking."
  echo ""
  if [ "$REPROCESS_RUNS" = false ]; then
    echo "NOTE: New blocks show as 0% coverage (orange)."
    echo "If you've already run in the new area, use:"
    echo "  bash scripts/rebuild_all_coverage.sh"
    echo "to mark those segments as visited."
  fi
  echo ""
  echo "View the updated map at: https://runmap.chouinard.me"
fi
echo ""
