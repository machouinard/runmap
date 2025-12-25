#!/bin/bash
# Find the GPX files that were deleted, so you can re-upload them for testing

GPX_DIR=${GPX_DIR:-/Volumes/RunMap/data/workout-routes}

echo "========================================"
echo "Finding GPX Files for Testing"
echo "========================================"
echo ""
echo "These 20 files were deleted from the database:"
echo ""

# Read the deleted files list and find their paths
grep "route_" /tmp/deleted_runs.txt | awk '{print $4}' | while read filename; do
  if [ -f "$GPX_DIR/$filename" ]; then
    echo "✓ $GPX_DIR/$filename"
  else
    echo "✗ NOT FOUND: $filename"
  fi
done

echo ""
echo "========================================"
echo "Copy commands for easy testing:"
echo "========================================"
echo ""
echo "# Copy first 5 test files to desktop:"
grep "route_" /tmp/deleted_runs.txt | awk '{print $4}' | head -5 | while read filename; do
  echo "cp '$GPX_DIR/$filename' ~/Desktop/"
done

echo ""
echo "# Or copy all 20:"
echo "mkdir -p ~/Desktop/test_gpx"
grep "route_" /tmp/deleted_runs.txt | awk '{print $4}' | while read filename; do
  echo "cp '$GPX_DIR/$filename' ~/Desktop/test_gpx/"
done

