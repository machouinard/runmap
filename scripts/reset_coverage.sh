#!/bin/bash
# Reset coverage processing (clear buffers/coverage but keep imported runs)
# Usage: ./scripts/reset_coverage.sh

set -e

# Load common environment configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

echo "========================================"
echo "Reset Coverage Processing"
echo "========================================"
echo ""
echo "This will clear all processing results but preserve imported runs."
echo ""

# Show current state
echo "Current database state:"
psql -d "$DB_NAME" -t -A -c \
    "SELECT
        'Runs: ' || COUNT(*) FROM runmap.runs_raw
     UNION ALL
     SELECT 'Walks: ' || COUNT(*) FROM runmap.walks_raw
     UNION ALL
     SELECT 'Cycling: ' || COUNT(*) FROM runmap.cycling_raw
     UNION ALL
     SELECT 'Buffered runs: ' || COUNT(*) FROM runmap.runs_buffered_subdiv
     UNION ALL
     SELECT 'Blocks with coverage: ' || COUNT(*) FROM runmap.block_coverage_segments
     UNION ALL
     SELECT 'Visited segments: ' || COUNT(*) FROM runmap.block_segment_visited WHERE visited = true;"

echo ""
read -p "Reset processing? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Resetting..."
psql -d "$DB_NAME" -c "SELECT runmap.reset_coverage_processing();"

echo ""
echo "✓ Reset complete!"
echo ""
echo "Next steps:"
echo "  ./scripts/process_all_runs.sh"
echo ""
