#!/usr/bin/env python3
"""
Rename GPX files from old server names to new database-assigned names.
This reads each GPX file, extracts metadata, generates the new filename,
and creates a copy with the new name.
"""

import os
import sys
import shutil
from pathlib import Path
from datetime import datetime

try:
    import gpxpy
except ImportError:
    print("ERROR: gpxpy not installed. Run: pip install gpxpy")
    sys.exit(1)

from geopy.distance import geodesic

# Load environment variables
SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
env_file = PROJECT_ROOT / '.env'

env_vars = {}
if env_file.exists():
    with open(env_file) as f:
        for line in f:
            line = line.split('#')[0].strip()
            if '=' in line:
                key, value = line.split('=', 1)
                env_vars[key.strip()] = value.strip()

GPX_DIR = Path(env_vars.get('GPX_DIR', PROJECT_ROOT / 'gpx'))

print("=" * 60)
print("Rename GPX Files to New Format")
print("=" * 60)
print(f"\nGPX Directory: {GPX_DIR}\n")

# Find all GPX files
gpx_files = list(GPX_DIR.glob("*.gpx"))
print(f"Found {len(gpx_files)} GPX files\n")

renamed = 0
skipped = 0
errors = 0

for gpx_path in sorted(gpx_files):
    old_filename = gpx_path.name

    # Skip files that already have the new format (YYYY-MM-DD_HHMM_type_distance.gpx)
    if old_filename.count('_') >= 3 and 'km.gpx' in old_filename:
        print(f"✓ Already new format: {old_filename}")
        skipped += 1
        continue

    try:
        # Parse GPX file
        with open(gpx_path, 'r') as f:
            gpx = gpxpy.parse(f)

        # Detect activity type from GPX metadata
        activity_type = None
        for track in gpx.tracks:
            if track.type:
                track_type = track.type.lower()
                if track_type in ['running', 'run']:
                    activity_type = 'run'
                    break
                elif track_type in ['walking', 'walk']:
                    activity_type = 'walk'
                    break
                elif track_type in ['cycling', 'cycle', 'bike', 'biking']:
                    activity_type = 'cycling'
                    break

        # Extract metadata
        start_time = None
        all_points = []
        for track in gpx.tracks:
            for segment in track.segments:
                for pt in segment.points:
                    all_points.append(pt)
                    if pt.time:
                        if start_time is None or pt.time < start_time:
                            start_time = pt.time

        if not start_time or not all_points:
            print(f"⚠ Skipping {old_filename}: Missing metadata")
            skipped += 1
            continue

        # Calculate distance
        total_m = 0
        for i in range(1, len(all_points)):
            p1 = all_points[i-1]
            p2 = all_points[i]
            dist = geodesic((p1.latitude, p1.longitude), (p2.latitude, p2.longitude)).meters
            total_m += dist

        distance_km = round(total_m / 1000, 1)

        # Detect activity type from speed if not specified
        if not activity_type and all_points:
            end_time = None
            for pt in reversed(all_points):
                if pt.time:
                    end_time = pt.time
                    break

            if start_time and end_time:
                duration_seconds = (end_time - start_time).total_seconds()
                if duration_seconds > 0:
                    avg_speed_ms = total_m / duration_seconds
                    if avg_speed_ms >= 5.0:
                        activity_type = 'cycling'
                    elif avg_speed_ms >= 2.2:
                        activity_type = 'run'
                    else:
                        activity_type = 'walk'

        if not activity_type:
            activity_type = 'run'  # Default

        # Generate new filename
        timestamp_str = start_time.strftime("%Y-%m-%d_%H%M")
        distance_str = f"{distance_km}km"
        new_filename = f"{timestamp_str}_{activity_type}_{distance_str}.gpx"

        new_path = GPX_DIR / new_filename

        # Copy file with new name (don't delete old one yet)
        if new_path.exists():
            print(f"✓ Already exists: {new_filename}")
            skipped += 1
        else:
            shutil.copy2(gpx_path, new_path)
            print(f"✓ Renamed: {old_filename} → {new_filename}")
            renamed += 1

    except Exception as e:
        print(f"✗ Error processing {old_filename}: {e}")
        errors += 1

print(f"\n{'=' * 60}")
print("Summary")
print("=" * 60)
print(f"Renamed: {renamed}")
print(f"Already new format: {skipped}")
print(f"Errors: {errors}")
print(f"\nTotal GPX files now: {len(list(GPX_DIR.glob('*.gpx')))}")
print("=" * 60)
