#!/bin/bash
# Verify Phase 3: Coverage Tracking Results

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Phase 3 Verification: Coverage Tracking"
echo "======================================"
echo ""

echo "1. Overall Coverage Statistics:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT * FROM runmap.coverage_stats_chunks;
EOF

echo ""
echo "2. Coverage Summary by Status:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  status,
  num_chunks,
  avg_coverage_pct,
  total_length_m,
  covered_length_m,
  ROUND((num_chunks::FLOAT / (SELECT COUNT(*) FROM runmap.streets_chunks_32610) * 100)::numeric, 1) as pct_of_total
FROM runmap.coverage_summary;
EOF

echo ""
echo "3. Streets with Most Coverage:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  name,
  highway,
  total_chunks,
  complete_chunks,
  partial_chunks,
  unrun_chunks,
  avg_coverage_pct
FROM runmap.streets_most_complete
LIMIT 15;
EOF

echo ""
echo "4. Streets with Least Coverage:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  name,
  highway,
  total_chunks,
  complete_chunks,
  partial_chunks,
  unrun_chunks,
  avg_coverage_pct
FROM runmap.streets_least_complete
LIMIT 15;
EOF

echo ""
echo "5. Chunk Status Distribution:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  'Total chunks' as category,
  COUNT(*) as count
FROM runmap.streets_chunks_32610
UNION ALL
SELECT
  'Chunks with any coverage' as category,
  COUNT(*) as count
FROM runmap.chunk_coverage_32610
UNION ALL
SELECT
  'Complete chunks (≥90%)' as category,
  COUNT(*) as count
FROM runmap.chunk_coverage_32610
WHERE status = 'complete'
UNION ALL
SELECT
  'Partial chunks (5-90%)' as category,
  COUNT(*) as count
FROM runmap.chunk_coverage_32610
WHERE status = 'partial'
UNION ALL
SELECT
  'Barely touched (<5%)' as category,
  COUNT(*) as count
FROM runmap.chunk_coverage_32610
WHERE status = 'unrun';
EOF

echo ""
echo "6. Sample of Covered Chunks:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  c.name,
  c.highway,
  cc.status,
  ROUND(cc.coverage_pct::numeric, 1) as pct,
  ROUND(cc.covered_length_m::numeric, 1) as covered_m,
  ROUND(cc.total_length_m::numeric, 1) as total_m
FROM runmap.chunk_coverage_32610 cc
JOIN runmap.streets_chunks_32610 c USING (chunk_id)
ORDER BY cc.coverage_pct DESC
LIMIT 20;
EOF

echo ""
echo "7. Coverage by Highway Type:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  c.highway,
  COUNT(DISTINCT c.chunk_id) as total_chunks,
  COUNT(DISTINCT cc.chunk_id) as covered_chunks,
  COUNT(DISTINCT cc.chunk_id) FILTER (WHERE cc.status = 'complete') as complete_chunks,
  ROUND(AVG(COALESCE(cc.coverage_pct, 0))::numeric, 1) as avg_coverage_pct
FROM runmap.streets_chunks_32610 c
LEFT JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
GROUP BY c.highway
ORDER BY avg_coverage_pct DESC;
EOF

echo ""
echo "======================================"
echo "Verification Complete"
echo "======================================"
