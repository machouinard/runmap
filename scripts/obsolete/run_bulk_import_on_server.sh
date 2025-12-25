#!/bin/bash
# Run bulk import on server (where venv and database are)
# This script SSH's to the server and runs the import there

set -e

SERVER_USER="mark"
SERVER_HOST="192.168.68.25"
SERVER_PORT="2222"
PROJECT_DIR="/home/mark/runmap"

echo "========================================="
echo "Run Bulk Import on Server"
echo "========================================="
echo ""
echo "This will:"
echo "1. SSH to $SERVER_USER@$SERVER_HOST"
echo "2. Run bulk import with Apple Health classification"
echo "3. Process 311 runs, 306 walks, 7 cycles"
echo ""

read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "❌ Cancelled"
    exit 1
fi

echo ""
echo "Connecting to server..."

# Run bulk import on server
ssh -p $SERVER_PORT $SERVER_USER@$SERVER_HOST << 'ENDSSH'
cd /home/mark/runmap

# Activate venv
source venv/bin/activate

echo ""
echo "========================================="
echo "Starting Bulk Import"
echo "========================================="
echo ""

# Run Python bulk import script
python3 scripts/bulk_import_with_classification.py \
    data/workout_types.json \
    data/workout-routes

ENDSSH

echo ""
echo "========================================="
echo "Bulk Import Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Export tiles: ssh mark@192.168.68.25 'cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh'"
echo "2. Or from Mac: bash scripts/export_tiles_on_server.sh"
echo ""
