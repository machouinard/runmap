#!/bin/bash
# Run Phase 3: Build Coverage from Existing Runs

set -e

DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}
export PGPASSWORD=${PGPASSWORD:-fucker}

echo "======================================"
echo "Phase 3: Build Chunk Coverage"
echo "======================================"
echo ""
echo "This will:"
echo "  - Read your 3 existing runs from runs_raw"
echo "  - Apply each run's buffer to intersecting chunks"
echo "  - Calculate coverage for ~100-500 chunks (per run)"
echo "  - Store results in chunk_coverage_32610"
echo "  - Refresh overall statistics"
echo ""
echo "Estimated time: 30-60 seconds"
echo "Peak RAM usage: ~300-500 MB"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo "Building coverage from existing runs..."
echo ""

psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" << 'EOF'
-- Run the coverage rebuild with timing
\timing on
SELECT runmap.rebuild_chunk_coverage();
\timing off

-- Refresh stats
\timing on
REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;
\timing off
EOF

echo ""
echo "======================================"
echo "Phase 3 Complete!"
echo "======================================"
echo ""
echo "Run verification script to see results:"
echo "  bash scripts/verify_phase3.sh"
