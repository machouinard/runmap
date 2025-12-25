#!/bin/bash
# Debug: Check why coverage isn't being calculated

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Coverage Debug Information"
echo "======================================"
echo ""

echo "1. Check runs_raw table:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT gid, filename, uploaded_at FROM runmap.runs_raw ORDER BY gid;
EOF

echo ""
echo "2. Check runs_buffered_32610 table:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  run_id,
  ST_GeometryType(geom) as geom_type,
  ROUND(ST_Area(geom)::numeric, 2) as area_sq_m
FROM runmap.runs_buffered_32610
ORDER BY run_id;
EOF

echo ""
echo "3. Check if any chunks intersect run buffers:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  rb.run_id,
  COUNT(DISTINCT c.chunk_id) as intersecting_chunks
FROM runmap.runs_buffered_32610 rb
CROSS JOIN runmap.streets_chunks_32610 c
WHERE ST_Intersects(c.geom_32610, rb.geom)
GROUP BY rb.run_id;
EOF

echo ""
echo "4. Check buffer distance setting:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT key, value FROM runmap.settings WHERE key = 'buffer_distance_m';
EOF

echo ""
echo "5. Sample chunk geometries (first 5):"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  chunk_id,
  name,
  ST_GeometryType(geom_32610) as geom_type,
  ROUND(chunk_length_m::numeric, 1) as length_m,
  ST_SRID(geom_32610) as srid
FROM runmap.streets_chunks_32610
LIMIT 5;
EOF

echo ""
echo "6. Check if buffer_one_run function was called:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  'Total runs in runs_raw' as check_name,
  COUNT(*) as count
FROM runmap.runs_raw
UNION ALL
SELECT
  'Runs with buffers in runs_buffered_32610' as check_name,
  COUNT(*) as count
FROM runmap.runs_buffered_32610;
EOF

echo ""
echo "======================================"
echo "Debug Complete"
echo "======================================"
