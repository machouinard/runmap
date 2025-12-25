#!/bin/bash
# Fix coverage table geometry type

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Fix Coverage Table Geometry Type"
echo "======================================"
echo ""
echo "This will drop and recreate chunk_coverage_32610"
echo "with correct geometry type (Geometry instead of LineString)"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo "Dropping old table..."
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
DROP TABLE IF EXISTS runmap.chunk_coverage_32610 CASCADE;
EOF

echo ""
echo "Recreating table with correct geometry type..."
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
CREATE TABLE runmap.chunk_coverage_32610 (
  chunk_id INT PRIMARY KEY REFERENCES runmap.streets_chunks_32610(chunk_id),
  covered_geom geometry(Geometry, 32610),
  covered_length_m FLOAT,
  total_length_m FLOAT,
  coverage_pct FLOAT GENERATED ALWAYS AS (
    CASE
      WHEN total_length_m > 0 THEN ROUND((covered_length_m / total_length_m * 100)::numeric, 2)
      ELSE 0
    END
  ) STORED,
  status TEXT GENERATED ALWAYS AS (
    CASE
      WHEN covered_length_m < total_length_m * 0.05 THEN 'unrun'
      WHEN covered_length_m < total_length_m * 0.90 THEN 'partial'
      ELSE 'complete'
    END
  ) STORED
);

CREATE INDEX idx_chunk_coverage_geom ON runmap.chunk_coverage_32610 USING GIST(covered_geom);
CREATE INDEX idx_chunk_coverage_status ON runmap.chunk_coverage_32610(status);
EOF

echo ""
echo "======================================"
echo "Table recreated successfully!"
echo "======================================"
echo ""
echo "Now run: bash scripts/test_single_run.sh"
