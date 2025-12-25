#!/bin/bash
set -e

# Clear test data from database before bulk import
# This removes existing runs, buffers, and coverage to start fresh

DB_HOST=${DB_HOST:-192.168.68.25}
DB_NAME=${DB_NAME:-runmap}
DB_USER=${DB_USER:-runmap_user}

echo "========================================="
echo "Clear Test Data (Fresh Start)"
echo "========================================="
echo ""
echo "⚠️  WARNING: This will delete:"
echo "  - All runs from runs_raw"
echo "  - All buffers from runs_buffered_32610"
echo "  - All coverage data from block_coverage_32610"
echo "  - All walks from walks_raw"
echo "  - All cycling from cycling_raw"
echo ""
read -p "Are you sure you want to proceed? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "❌ Cancelled"
    exit 1
fi

echo ""
echo "[1/5] Counting current data..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
SELECT
  (SELECT COUNT(*) FROM runmap.runs_raw) as runs,
  (SELECT COUNT(*) FROM runmap.runs_buffered_32610) as buffers,
  (SELECT COUNT(*) FROM runmap.block_coverage_32610) as coverage_blocks,
  (SELECT COUNT(*) FROM runmap.walks_raw) as walks,
  (SELECT COUNT(*) FROM runmap.cycling_raw) as cycles;
EOF

echo ""
echo "[2/5] Truncating runs_buffered_32610..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "TRUNCATE runmap.runs_buffered_32610;"

echo "[3/5] Truncating block_coverage_32610..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "TRUNCATE runmap.block_coverage_32610;"

echo "[4/5] Truncating runs_raw..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "TRUNCATE runmap.runs_raw CASCADE;"

echo "[5/5] Truncating walks_raw and cycling_raw..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "TRUNCATE runmap.walks_raw;"
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "TRUNCATE runmap.cycling_raw;"

echo ""
echo "✅ All test data cleared"
echo ""
echo "Verifying empty tables..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
SELECT
  (SELECT COUNT(*) FROM runmap.runs_raw) as runs,
  (SELECT COUNT(*) FROM runmap.runs_buffered_32610) as buffers,
  (SELECT COUNT(*) FROM runmap.block_coverage_32610) as coverage_blocks,
  (SELECT COUNT(*) FROM runmap.walks_raw) as walks,
  (SELECT COUNT(*) FROM runmap.cycling_raw) as cycles;
EOF

echo ""
echo "========================================="
echo "Ready for bulk import!"
echo "========================================="
