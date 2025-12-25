#!/bin/bash
# Run Phase 2: Subdivide Blocks into Chunks

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

CHUNK_SIZE=${1:-50}

echo "======================================"
echo "Phase 2: Subdivide Blocks into Chunks"
echo "======================================"
echo ""
echo "Max chunk size: ${CHUNK_SIZE}m"
echo ""
echo "This will:"
echo "  - Read 2,597 blocks from streets_blocks_32610"
echo "  - Keep blocks ≤${CHUNK_SIZE}m as single chunks"
echo "  - Split blocks >${CHUNK_SIZE}m into uniform chunks"
echo "  - Create ~5,900 chunks in streets_chunks_32610"
echo ""
echo "Estimated time: 1-2 minutes"
echo "Peak RAM usage: ~200-500 MB"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo "Starting chunk subdivision..."
echo ""

psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << EOF
-- Run the subdivision with timing
\timing on
SELECT runmap.subdivide_blocks_to_chunks(${CHUNK_SIZE}.0);
\timing off
EOF

echo ""
echo "======================================"
echo "Phase 2 Complete!"
echo "======================================"
echo ""
echo "Run verification script to see results:"
echo "  bash scripts/verify_phase2.sh"
