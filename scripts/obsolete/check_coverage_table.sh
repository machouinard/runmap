#!/bin/bash
# Check the current state of coverage table

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Check Coverage Table Schema"
echo "======================================"
echo ""

echo "Table structure:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
\d runmap.chunk_coverage_32610
EOF

echo ""
echo "Geometry column details:"
echo "-----------------------------------"
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
SELECT
  f_table_schema,
  f_table_name,
  f_geometry_column,
  coord_dimension,
  srid,
  type
FROM geometry_columns
WHERE f_table_name = 'chunk_coverage_32610';
EOF
