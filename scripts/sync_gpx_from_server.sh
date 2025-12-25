#!/bin/bash
# Sync GPX files from server and reorganize with new database-assigned filenames
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/env.sh"

SERVER_USER="mark"
SERVER_HOST="192.168.68.25"
SERVER_PORT="2222"
SERVER_GPX_DIR="/home/mark/runmap/gpx"
LOCAL_GPX_DIR="$GPX_DIR"

echo "========================================"
echo "Sync GPX Files from Server"
echo "========================================"
echo ""
echo "Server: $SERVER_HOST:$SERVER_PORT"
echo "Server GPX dir: $SERVER_GPX_DIR"
echo "Local GPX dir: $LOCAL_GPX_DIR"
echo ""

# Create local GPX directory if it doesn't exist
mkdir -p "$LOCAL_GPX_DIR"

# Download all GPX files from server
echo "Downloading GPX files from server..."
rsync -avz --progress -e "ssh -p $SERVER_PORT" \
  "$SERVER_USER@$SERVER_HOST:$SERVER_GPX_DIR/" \
  "$LOCAL_GPX_DIR/"

echo ""
echo "✓ Sync complete!"
echo ""

# Count files
LOCAL_COUNT=$(find "$LOCAL_GPX_DIR" -name "*.gpx" -type f | wc -l | tr -d ' ')
echo "Local GPX files: $LOCAL_COUNT"
echo ""
echo "Note: Files synced with their current server names."
echo "To reorganize with new database names, the ingest script now handles this."
