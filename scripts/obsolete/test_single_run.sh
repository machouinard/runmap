#!/bin/bash
# Test applying a single run manually

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Test: Apply Single Run Coverage"
echo "======================================"
echo ""

echo "1. Get first run ID:"
echo "-----------------------------------"
RUN_ID=$(psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT id FROM runmap.runs_raw ORDER BY uploaded_at LIMIT 1;" | xargs)
echo "Run ID: $RUN_ID"

echo ""
echo "2. Clear existing coverage:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << EOF
TRUNCATE runmap.chunk_coverage_32610;
EOF

echo ""
echo "3. Apply this single run:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << EOF
SELECT runmap.apply_run_to_chunk_coverage('$RUN_ID'::uuid);
EOF

echo ""
echo "4. Check results:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  COUNT(*) as chunks_with_coverage,
  COUNT(*) FILTER (WHERE status = 'complete') as complete,
  COUNT(*) FILTER (WHERE status = 'partial') as partial,
  COUNT(*) FILTER (WHERE status = 'unrun') as unrun
FROM runmap.chunk_coverage_32610;
EOF

echo ""
echo "5. Sample covered chunks:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  c.name,
  cc.status,
  ROUND(cc.coverage_pct::numeric, 1) as pct,
  ROUND(cc.covered_length_m::numeric, 1) as covered_m,
  ROUND(cc.total_length_m::numeric, 1) as total_m
FROM runmap.chunk_coverage_32610 cc
JOIN runmap.streets_chunks_32610 c USING (chunk_id)
ORDER BY cc.coverage_pct DESC
LIMIT 10;
EOF

echo ""
echo "======================================"
echo "Test Complete"
echo "======================================"
