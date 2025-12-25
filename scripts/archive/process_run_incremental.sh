#!/bin/bash
# Incremental processing for a single run - fast and memory-efficient

set -e

RUN_ID=$1

if [ -z "$RUN_ID" ]; then
  echo "Usage: $0 <run_id>"
  exit 1
fi

echo "Processing run $RUN_ID incrementally..."

# 1. Buffer this run only
echo "Buffering run $RUN_ID..."
psql -d runmap -c "SELECT runmap.buffer_one_run($RUN_ID);"

# 2. Update coverage for streets touched by this run
echo "Updating street coverage..."
psql -d runmap -c "SELECT runmap.apply_run_to_coverage($RUN_ID);"

# 3. Refresh coverage stats (cheap - 1454 rows)
echo "Refreshing coverage stats..."
psql -d runmap -c "REFRESH MATERIALIZED VIEW runmap.coverage_stats;"

echo "✓ Incremental processing complete for run $RUN_ID"
