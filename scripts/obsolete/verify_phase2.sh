#!/bin/bash
# Verify Phase 2: Chunk Subdivision Results

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Phase 2 Verification: Chunk Subdivision"
echo "======================================"
echo ""

echo "1. Chunk Statistics:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT * FROM runmap.chunks_stats;
EOF

echo ""
echo "2. Chunks per Street (Top 20):"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  name,
  highway,
  ROUND(original_length_m::numeric, 0) as orig_length_m,
  num_chunks,
  avg_chunk_length_m
FROM runmap.chunks_per_street
WHERE num_chunks > 0
ORDER BY num_chunks DESC
LIMIT 20;
EOF

echo ""
echo "3. Check P Street (should have many chunks):"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  name,
  highway,
  ROUND(original_length_m::numeric, 0) as orig_length_m,
  num_chunks,
  avg_chunk_length_m
FROM runmap.chunks_per_street
WHERE name LIKE '%P Street%'
ORDER BY num_chunks DESC;
EOF

echo ""
echo "4. Distribution of chunk lengths:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  CASE
    WHEN chunk_length_m < 20 THEN '<20m'
    WHEN chunk_length_m < 30 THEN '20-30m'
    WHEN chunk_length_m < 40 THEN '30-40m'
    WHEN chunk_length_m < 50 THEN '40-50m'
    ELSE '>50m'
  END as length_range,
  COUNT(*) as num_chunks,
  ROUND(AVG(chunk_length_m)::numeric, 1) as avg_m
FROM runmap.streets_chunks_32610
GROUP BY length_range
ORDER BY MIN(chunk_length_m);
EOF

echo ""
echo "5. Blocks that got subdivided (top 20):"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  name,
  ROUND(block_length_m::numeric, 1) as block_m,
  num_chunks,
  avg_chunk_length_m
FROM runmap.chunks_per_block
WHERE num_chunks > 1
ORDER BY num_chunks DESC
LIMIT 20;
EOF

echo ""
echo "6. Sample chunks from P Street:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  chunk_id,
  block_id,
  chunk_index,
  ROUND(chunk_length_m::numeric, 1) as length_m
FROM runmap.streets_chunks_32610
WHERE name = 'P Street' AND parent_ogc_fid = (
  SELECT ogc_fid FROM runmap.streets_reference_32610
  WHERE name = 'P Street' ORDER BY total_length_m DESC LIMIT 1
)
ORDER BY block_id, chunk_index
LIMIT 30;
EOF

echo ""
echo "7. Comparison: Streets → Blocks → Chunks:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  'Streets' as level,
  COUNT(*) as count,
  ROUND(AVG(total_length_m)::numeric, 1) as avg_length_m
FROM runmap.streets_reference_32610
UNION ALL
SELECT
  'Blocks' as level,
  COUNT(*) as count,
  ROUND(AVG(block_length_m)::numeric, 1) as avg_length_m
FROM runmap.streets_blocks_32610
UNION ALL
SELECT
  'Chunks' as level,
  COUNT(*) as count,
  ROUND(AVG(chunk_length_m)::numeric, 1) as avg_length_m
FROM runmap.streets_chunks_32610;
EOF

echo ""
echo "======================================"
echo "Verification Complete"
echo "======================================"
