#!/home/mark/runmap/api/venv/bin/python3
"""
Test workout_hash matching between WorkoutDoors exports and Apple Health exports.
This will prove if the same workout from different sources produces the same hash.
"""

import gpxpy
import hashlib
import os
import sys
from datetime import datetime

def calculate_workout_hash(gpx_path):
    """Calculate workout hash exactly as ingest_gpx.sh does"""
    with open(gpx_path, 'r') as f:
        gpx = gpxpy.parse(f)

    # Extract start_time and duration
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

    if not start_time or not end_time:
        return None, None, None

    duration_seconds = int((end_time - start_time).total_seconds())
    workout_key = f"{start_time.isoformat()}|{duration_seconds}"
    workout_hash = hashlib.sha256(workout_key.encode()).hexdigest()

    return workout_hash, start_time, duration_seconds

# WorkoutDoors exports
workoutdoors_dir = "/Volumes/RunMap/data"
workoutdoors_files = [
    "Saturday Morning Run 2.gpx",
    "Wednesday Morning Run 5.gpx"
]

# Apple Health exports
apple_health_dir = "/Volumes/RunMap/data/dev-runs"
apple_health_files = [f for f in os.listdir(apple_health_dir) if f.endswith('.gpx')]

print("=" * 80)
print("WorkoutDoors Exports (Test Files)")
print("=" * 80)

workoutdoors_hashes = {}
for filename in workoutdoors_files:
    filepath = os.path.join(workoutdoors_dir, filename)
    if os.path.exists(filepath):
        hash_val, start_time, duration = calculate_workout_hash(filepath)
        if hash_val:
            print(f"\n📱 {filename}")
            print(f"   Start: {start_time}")
            print(f"   Duration: {duration}s ({duration // 60}m {duration % 60}s)")
            print(f"   Hash: {hash_val[:16]}...")
            workoutdoors_hashes[hash_val] = {
                'filename': filename,
                'start_time': start_time,
                'duration': duration
            }
        else:
            print(f"\n❌ {filename} - No timestamps found")

print("\n" + "=" * 80)
print("Apple Health Exports (dev-runs)")
print("=" * 80)

apple_health_hashes = {}
for filename in sorted(apple_health_files):
    filepath = os.path.join(apple_health_dir, filename)
    hash_val, start_time, duration = calculate_workout_hash(filepath)
    if hash_val:
        apple_health_hashes[hash_val] = {
            'filename': filename,
            'start_time': start_time,
            'duration': duration
        }

print(f"\nProcessed {len(apple_health_hashes)} Apple Health exports")

print("\n" + "=" * 80)
print("MATCHES FOUND")
print("=" * 80)

matches_found = 0
for wo_hash, wo_data in workoutdoors_hashes.items():
    if wo_hash in apple_health_hashes:
        ah_data = apple_health_hashes[wo_hash]
        matches_found += 1
        print(f"\n✅ MATCH #{matches_found}")
        print(f"   WorkoutDoors: {wo_data['filename']}")
        print(f"   Apple Health: {ah_data['filename']}")
        print(f"   Start Time: {wo_data['start_time']}")
        print(f"   Duration: {wo_data['duration']}s")
        print(f"   Hash: {wo_hash[:32]}...")
    else:
        print(f"\n❌ NO MATCH")
        print(f"   WorkoutDoors: {wo_data['filename']}")
        print(f"   Start Time: {wo_data['start_time']}")
        print(f"   Duration: {wo_data['duration']}s")
        print(f"   (Not found in Apple Health exports)")

print("\n" + "=" * 80)
print(f"Summary: {matches_found} matches found out of {len(workoutdoors_hashes)} test files")
print("=" * 80)

if matches_found == len(workoutdoors_hashes):
    print("\n🎉 SUCCESS! All WorkoutDoors exports matched with Apple Health exports!")
    print("   The workout_hash system correctly identifies the same workout from different sources.")
    sys.exit(0)
else:
    print("\n⚠️  Some files didn't match. This could mean:")
    print("   - Those workouts aren't in the 20 dev-runs")
    print("   - Start times or durations differ between exports")
    sys.exit(1)
