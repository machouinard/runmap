#!/bin/bash
# Run Phase 1: Split Streets at Intersections

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Phase 1: Split Streets at Intersections"
echo "======================================"
echo ""
echo "This will:"
echo "  - Read 1,456 streets from streets_reference_32610"
echo "  - Find intersection points for each street"
echo "  - Split streets into blocks at those intersections"
echo "  - Create ~3,000-5,000 blocks in streets_blocks_32610"
echo ""
echo "Estimated time: 2-5 minutes"
echo "Peak RAM usage: ~500 MB - 1 GB"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo "Starting intersection split..."
echo ""

psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
-- Run the split with timing
\timing on
SELECT runmap.split_streets_at_intersections();
\timing off
EOF

echo ""
echo "======================================"
echo "Phase 1 Complete!"
echo "======================================"
echo ""
echo "Run verification script to see results:"
echo "  bash scripts/verify_phase1.sh"
