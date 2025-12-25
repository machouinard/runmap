#!/bin/bash
# Verify Phase 1: Intersection Split Results

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Phase 1 Verification: Intersection Split"
echo "======================================"
echo ""

echo "1. Block Statistics:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT * FROM runmap.blocks_stats;
EOF

echo ""
echo "2. Blocks per Street (Top 20):"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  name,
  highway,
  ROUND(original_length_m::numeric, 0) as orig_length_m,
  num_blocks,
  avg_block_length_m
FROM runmap.blocks_per_street
WHERE num_blocks > 0
ORDER BY num_blocks DESC
LIMIT 20;
EOF

echo ""
echo "3. Check P Street (should have many blocks):"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  name,
  highway,
  ROUND(original_length_m::numeric, 0) as orig_length_m,
  num_blocks,
  avg_block_length_m
FROM runmap.blocks_per_street
WHERE name LIKE '%P Street%'
ORDER BY num_blocks DESC;
EOF

echo ""
echo "4. Distribution of block lengths:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  CASE
    WHEN block_length_m < 50 THEN '<50m'
    WHEN block_length_m < 100 THEN '50-100m'
    WHEN block_length_m < 150 THEN '100-150m'
    WHEN block_length_m < 200 THEN '150-200m'
    ELSE '>200m'
  END as length_range,
  COUNT(*) as num_blocks,
  ROUND(AVG(block_length_m)::numeric, 1) as avg_m
FROM runmap.streets_blocks_32610
GROUP BY length_range
ORDER BY MIN(block_length_m);
EOF

echo ""
echo "5. Sample blocks from different streets:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  block_id,
  name,
  block_index,
  ROUND(block_length_m::numeric, 1) as length_m
FROM runmap.streets_blocks_32610
WHERE name IN ('P Street', '24th Street', 'V Street')
ORDER BY name, block_index
LIMIT 30;
EOF

echo ""
echo "======================================"
echo "Verification Complete"
echo "======================================"
