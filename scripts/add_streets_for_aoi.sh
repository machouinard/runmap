#!/bin/bash
# ============================================================================
# Add Streets for an AOI (Scalable Multi-Area Workflow)
# ============================================================================
# Usage: ./scripts/add_streets_for_aoi.sh [--prune] <osm_file.pbf> <aoi_name>
#
# This script imports OSM streets that fall within a specified AOI polygon.
# Perfect for adding new areas or expanding existing ones!
#
# Options:
#   --prune   Wipe all existing streets/blocks/segments before importing.
#             Use this when you've modified the AOI boundary and want a clean slate.
#
# Examples:
#   ./scripts/add_streets_for_aoi.sh sacramento_expanded.osm.pbf sacramento
#   ./scripts/add_streets_for_aoi.sh --prune norcal-latest.osm.pbf sacramento
#   ./scripts/add_streets_for_aoi.sh portland_metro.osm.pbf portland
# ============================================================================

set -e

# Load environment variables
source "$(dirname "$0")/common/env.sh"

# Parse flags
PRUNE=false
while [[ $1 == --* ]]; do
  case $1 in
    --prune)
      PRUNE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ $# -ne 2 ]; then
  echo "Usage: $0 [--prune] <osm_file.pbf> <aoi_name>"
  echo ""
  echo "Options:"
  echo "  --prune   Wipe all streets/blocks/segments before importing (clean slate)"
  echo ""
  echo "Examples:"
  echo "  $0 data/sacramento_expanded.osm.pbf sacramento"
  echo "  $0 --prune norcal-latest.osm.pbf sacramento"
  exit 1
fi

OSM_FILE="$1"
AOI_NAME="$2"

if [ ! -f "$OSM_FILE" ]; then
  echo "ERROR: OSM file not found: $OSM_FILE"
  exit 1
fi

echo "========================================="
echo "Adding Streets for AOI: $AOI_NAME"
echo "========================================="
echo ""
echo "Configuration:"
echo "  OSM File: $OSM_FILE"
echo "  Database: $DB_NAME @ $DB_HOST"
echo "  Prune mode: $PRUNE"
echo ""
if [ "$PRUNE" = true ]; then
  echo "⚠️  PRUNE MODE: This will wipe ALL existing streets, blocks, and segments"
  echo "   before importing. Use this when you've modified the AOI boundary."
  echo ""
fi
echo "This script will:"
echo "  1. Import streets from OSM that fall within the AOI"
echo "  2. Split streets into blocks at intersections"
echo "  3. Create ~5m segments for coverage tracking"
echo "  4. (Optional) Reprocess all runs to calculate coverage"
echo ""

# Check if AOI exists
AOI_EXISTS=$(PGPASSWORD="$PGPASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -t -c "SELECT COUNT(*) FROM runmap.aoi WHERE name = '$AOI_NAME';")
if [ "$AOI_EXISTS" -eq 0 ]; then
  echo "ERROR: AOI '$AOI_NAME' not found in runmap.aoi table"
  echo ""
  echo "First create the AOI polygon:"
  echo "  INSERT INTO runmap.aoi (name, geom) VALUES ('$AOI_NAME', ST_GeomFromText('POLYGON((...))'));"
  exit 1
fi

echo "✓ AOI '$AOI_NAME' found"
echo ""

# Prune existing data if requested
if [ "$PRUNE" = true ]; then
  echo "========================================="
  echo "PRUNE: Wiping existing streets/blocks/segments..."
  echo "========================================="
  PGPASSWORD="$PGPASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" << 'EOF'
-- Wipe in correct order (respects FK dependencies)
TRUNCATE runmap.block_segment_visited CASCADE;
TRUNCATE runmap.block_coverage_segments CASCADE;
TRUNCATE runmap.block_segments CASCADE;
TRUNCATE runmap.streets_blocks_32610 CASCADE;
TRUNCATE runmap.streets_reference_32610 CASCADE;
TRUNCATE runmap.streets_reference CASCADE;
EOF
  echo "✓ All street data wiped"
  echo ""
fi

# Step 1: Import OSM streets to temp table
echo "Step 1: Importing OSM streets to temp table..."
ogr2ogr -f "PostgreSQL" \
  PG:"host=$DB_HOST dbname=$DB_NAME user=$DB_USER password=$PGPASSWORD" \
  -sql "SELECT osm_id, name, highway FROM lines WHERE highway IN ('residential', 'primary', 'secondary', 'tertiary') AND highway != 'service'" \
  -nln runmap.streets_import_temp \
  -nlt LINESTRING \
  -t_srs EPSG:4326 \
  -lco GEOMETRY_NAME=geom \
  -overwrite \
  "$OSM_FILE"

echo "✓ OSM import complete"
echo ""

# Step 2: Filter streets by AOI and merge into reference tables
echo "Step 2: Filtering streets that fall within AOI '$AOI_NAME'..."
PGPASSWORD="$PGPASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" << EOF
-- Add new streets that fall within the AOI (avoid duplicates by osm_id)
INSERT INTO runmap.streets_reference (osm_id, name, highway, geom, runnable)
SELECT DISTINCT ON (st.osm_id)
  st.osm_id,
  st.name,
  st.highway,
  st.geom,
  TRUE
FROM runmap.streets_import_temp st
JOIN runmap.aoi a ON a.name = '$AOI_NAME'
WHERE ST_Intersects(st.geom, a.geom)
  AND st.osm_id NOT IN (SELECT osm_id FROM runmap.streets_reference WHERE osm_id IS NOT NULL)
  AND st.highway != 'service';

-- Add to UTM-projected table
INSERT INTO runmap.streets_reference_32610 (ogc_fid, name, highway, geom_32610, total_length_m)
SELECT
  ogc_fid,
  name,
  highway,
  ST_Transform(geom, 32610),
  ST_Length(ST_Transform(geom, 32610))
FROM runmap.streets_reference
WHERE ogc_fid NOT IN (SELECT COALESCE(parent_ogc_fid, -1) FROM runmap.streets_blocks_32610);

-- Cleanup temp table
DROP TABLE IF EXISTS runmap.streets_import_temp;

-- Report
SELECT
  COUNT(*) as new_streets,
  ROUND((SUM(ST_Length(ST_Transform(geom, 32610))) / 1609.34)::numeric, 2) as total_miles
FROM runmap.streets_reference
WHERE ogc_fid NOT IN (SELECT COALESCE(parent_ogc_fid, -1) FROM runmap.streets_blocks_32610);
EOF

echo "✓ Streets filtered and added"
echo ""

# Step 3: Split new streets into blocks at intersections
echo "Step 3: Splitting new streets into blocks..."
echo "NOTE: This may take several minutes for large imports"

PGPASSWORD="$PGPASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" << 'EOF'
-- Split only NEW streets (those not yet in blocks table)
-- This is incremental - doesn't touch existing blocks
WITH new_streets AS (
  SELECT ogc_fid, name, highway, geom_32610, total_length_m
  FROM runmap.streets_reference_32610
  WHERE ogc_fid NOT IN (SELECT COALESCE(parent_ogc_fid, -1) FROM runmap.streets_blocks_32610)
),
intersections AS (
  -- Find where new streets intersect with ALL streets (new + existing)
  SELECT DISTINCT
    ns.ogc_fid as street_id,
    ST_Intersection(ns.geom_32610, s.geom_32610) as point
  FROM new_streets ns
  JOIN runmap.streets_reference_32610 s ON s.ogc_fid != ns.ogc_fid
  WHERE ST_Intersects(ns.geom_32610, s.geom_32610)
    AND ST_GeometryType(ST_Intersection(ns.geom_32610, s.geom_32610)) = 'ST_Point'
),
split_lines AS (
  -- Split each new street at its intersection points
  SELECT
    ns.ogc_fid as parent_id,
    ns.name,
    ns.highway,
    (ST_Dump(ST_Split(
      ns.geom_32610,
      ST_Collect(i.point)
    ))).geom as geom_32610
  FROM new_streets ns
  LEFT JOIN intersections i ON i.street_id = ns.ogc_fid
  GROUP BY ns.ogc_fid, ns.name, ns.highway, ns.geom_32610
)
INSERT INTO runmap.streets_blocks_32610 (name, highway, geom_32610, block_length_m, parent_ogc_fid)
SELECT
  name,
  highway,
  geom_32610,
  ST_Length(geom_32610),
  parent_id
FROM split_lines;

-- Report
SELECT COUNT(*) as new_blocks FROM runmap.streets_blocks_32610
WHERE block_id NOT IN (SELECT COALESCE(block_id, -1) FROM runmap.block_segments);
EOF

echo "✓ Blocks created"
echo ""

# Step 4: Create 5m segments for new blocks
echo "Step 4: Creating 5m segments for coverage tracking..."
PGPASSWORD="$PGPASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" << 'EOF'
-- Segment new blocks into ~5m pieces using ST_DumpSegments
-- First densify vertices with ST_Segmentize, then extract each segment
INSERT INTO runmap.block_segments (block_id, segment_geom, segment_length_m)
SELECT
  b.block_id,
  (ST_DumpSegments(ST_Segmentize(b.geom_32610, 5.0))).geom AS segment_geom,
  ST_Length((ST_DumpSegments(ST_Segmentize(b.geom_32610, 5.0))).geom) AS segment_length_m
FROM runmap.streets_blocks_32610 b
WHERE b.block_id NOT IN (SELECT COALESCE(block_id, -1) FROM runmap.block_segments);

-- Initialize visited flags (all FALSE)
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE
FROM runmap.block_segments
WHERE segment_id NOT IN (SELECT segment_id FROM runmap.block_segment_visited);

-- Initialize aggregate coverage (0%) for ALL blocks missing coverage records
-- Use block_length_m from streets_blocks_32610 as source of truth
INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
SELECT
  b.block_id,
  0,
  b.block_length_m
FROM runmap.streets_blocks_32610 b
WHERE b.block_id NOT IN (SELECT block_id FROM runmap.block_coverage_segments);

-- Report
SELECT
  COUNT(*) as new_segments,
  ROUND((SUM(segment_length_m) / 1609.34)::numeric, 2) as total_miles
FROM runmap.block_segments
WHERE segment_id NOT IN (SELECT segment_id FROM runmap.block_segment_visited);
EOF

echo "✓ Segments initialized"
echo ""

# Step 5: Reprocess existing runs to mark new segments
echo "========================================="
echo "Step 5: Reprocess Existing Runs"
echo "========================================="
echo ""
echo "To calculate coverage for the new streets, all existing runs must be"
echo "reprocessed. This will:"
echo "  - Create run buffers"
echo "  - Mark segments as visited where runs intersect"
echo "  - Update coverage statistics"
echo "  - Export new tiles"
echo ""
echo "⚠️  This typically takes 5-10 minutes depending on run count."
echo ""
read -p "Reprocess all runs now? (Y/n) " -n 1 -r
echo ""

RUNS_PROCESSED=false
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo ""
  echo "Reprocessing all runs..."
  bash "$(dirname "$0")/rebuild_all_coverage.sh"
  RUNS_PROCESSED=true
else
  echo ""
  echo "⚠️  Skipped run reprocessing."
  echo "   Coverage stats will be incorrect until you run:"
  echo "   bash scripts/rebuild_all_coverage.sh"
fi

echo ""
echo "========================================="
echo "✓ Street Import Complete!"
echo "========================================="
echo ""

# Show summary stats
PGPASSWORD="$PGPASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" << EOF
SELECT 
  (SELECT COUNT(*) FROM runmap.streets_blocks_32610) as total_blocks,
  (SELECT ROUND((SUM(block_length_m) / 1609.34)::numeric, 2) FROM runmap.streets_blocks_32610) as total_miles
EOF

echo ""
if [ "$RUNS_PROCESSED" = true ]; then
  echo "✓ Streets imported, coverage calculated, and tiles exported."
  echo ""
  echo "Next steps:"
  echo "  - Hard refresh your browser: Cmd+Shift+R (Mac) or Ctrl+Shift+R (Windows)"
else
  echo "Streets imported but coverage not yet calculated."
  echo ""
  echo "Next steps:"
  echo "  1. Run: bash scripts/rebuild_all_coverage.sh"
  echo "  2. Hard refresh your browser: Cmd+Shift+R (Mac) or Ctrl+Shift+R (Windows)"
fi
echo ""
