#!/bin/bash
# Test workout_hash matching between WorkoutDoors and Apple Health exports

set -e

echo "========================================"
echo "Testing Workout Hash Matching"
echo "========================================"
echo ""

# Source environment for Python venv
source /home/mark/runmap/api/.env

# Test the 2 WorkoutDoors files
echo "WorkoutDoors Exports:"
echo "---------------------"

for FILE in "/home/mark/runmap/data/Saturday Morning Run 2.gpx" "/home/mark/runmap/data/Wednesday Morning Run 5.gpx"; do
    if [ -f "$FILE" ]; then
        BASENAME=$(basename "$FILE")
        echo ""
        echo "📱 $BASENAME"

        # Calculate hash using same Python code as ingest_gpx.sh
        /home/mark/runmap/api/venv/bin/python3 << EOF
import gpxpy
import hashlib

with open("$FILE", 'r') as f:
    gpx = gpxpy.parse(f)

start_time = None
end_time = None
for track in gpx.tracks:
    for segment in track.segments:
        for pt in segment.points:
            if pt.time:
                if start_time is None or pt.time < start_time:
                    start_time = pt.time
                if end_time is None or pt.time > end_time:
                    end_time = pt.time

if start_time and end_time:
    duration_seconds = int((end_time - start_time).total_seconds())
    workout_key = f"{start_time.isoformat()}|{duration_seconds}"
    workout_hash = hashlib.sha256(workout_key.encode()).hexdigest()

    print(f"   Start: {start_time}")
    print(f"   Duration: {duration_seconds}s ({duration_seconds // 60}m {duration_seconds % 60}s)")
    print(f"   Hash: {workout_hash[:32]}...")

    # Store for matching
    with open("/tmp/workoutdoors_hashes.txt", "a") as f:
        f.write(f"{workout_hash}|$BASENAME|{start_time}|{duration_seconds}\n")
else:
    print("   ❌ No timestamps")
EOF
    fi
done

echo ""
echo "========================================"
echo "Checking Database for Matches"
echo "========================================"
echo ""

# Check each hash against database (use localhost when on server)
while IFS='|' read -r HASH FILENAME START DURATION; do
    MATCH=$(psql -h localhost -U runmap_user -d runmap -t -A -c \
        "SELECT filename FROM runmap.runs_raw WHERE workout_hash = '$HASH'")

    if [ -n "$MATCH" ]; then
        echo "✅ MATCH FOUND!"
        echo "   WorkoutDoors: $FILENAME"
        echo "   Apple Health: $MATCH"
        echo "   Start: $START"
        echo "   Duration: ${DURATION}s"
        echo ""
    else
        echo "❌ NO MATCH"
        echo "   WorkoutDoors: $FILENAME"
        echo "   (Not found in database)"
        echo ""
    fi
done < /tmp/workoutdoors_hashes.txt

# Cleanup
rm -f /tmp/workoutdoors_hashes.txt

echo "========================================"
echo "Test Complete"
echo "========================================"
