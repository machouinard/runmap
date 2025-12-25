#!/bin/bash
# Alter coverage table geometry type without dropping

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Alter Coverage Table Geometry Type"
echo "======================================"
echo ""
echo "This will alter chunk_coverage_32610.covered_geom"
echo "from geometry(LineString, 32610) to geometry(Geometry, 32610)"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo "Altering column type..."
psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
-- Remove the typed geometry constraint
ALTER TABLE runmap.chunk_coverage_32610
  ALTER COLUMN covered_geom TYPE geometry(Geometry, 32610);
EOF

echo ""
echo "======================================"
echo "Column type altered successfully!"
echo "======================================"
echo ""
echo "Now run: bash scripts/test_single_run.sh"
