#!/bin/bash
# Parse GPX and insert into STAGING database
# This version does NOT source common/env.sh - environment must be provided by caller

set -e

GPX_FILE=$1

if [ -z "$GPX_FILE" ] || [ ! -f "$GPX_FILE" ]; then
  echo "Usage: $0 <gpx_file>"
  exit 1
fi

# Verify environment variables are set (should come from caller)
if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$PGPASSWORD" ] || [ -z "$DB_HOST" ]; then
  echo "ERROR: Database environment variables not set!"
  echo "DB_NAME=$DB_NAME DB_USER=$DB_USER DB_HOST=$DB_HOST"
  exit 1
fi

# Use venv Python if available (server), otherwise system python3 (Mac)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../api/venv/bin/python" ]; then
  PYTHON_CMD="$SCRIPT_DIR/../api/venv/bin/python"
else
  PYTHON_CMD="python3"
fi

$PYTHON_CMD << EOF
import gpxpy
from shapely.geometry import MultiLineString
try:
    import psycopg2
except ImportError:
    # Fall back to psycopg3 (compatible with Python 3.14+)
    import psycopg as psycopg2
import hashlib
import sys

gpx_file = "$GPX_FILE"

try:
    # Read for hash (binary mode for consistency with API)
    with open(gpx_file, 'rb') as f:
        content_bytes = f.read()

    # Parse GPX (text mode)
    with open(gpx_file, 'r') as f:
        gpx = gpxpy.parse(f)

    # Detect activity type from GPX metadata (WorkOutDoors format)
    # WorkOutDoors includes: <trk><type>running|walking|cycling</type>
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

    # Extract tracks
    lines = []
    for track in gpx.tracks:
        for segment in track.segments:
            coords = [(pt.longitude, pt.latitude) for pt in segment.points]
            if len(coords) > 1:
                lines.append(coords)

    if not lines:
        print("No valid tracks found in GPX")
        sys.exit(1)

    # Create MultiLineString WKT
    multiline = MultiLineString(lines)
    wkt = multiline.wkt

    # Extract metadata
    start_time = None
    end_time = None
    all_points = []
    for track in gpx.tracks:
        for segment in track.segments:
            for pt in segment.points:
                all_points.append(pt)
                if pt.time:
                    if start_time is None or pt.time < start_time:
                        start_time = pt.time
                    if end_time is None or pt.time > end_time:
                        end_time = pt.time

    duration_seconds = None
    if start_time and end_time:
        duration_seconds = int((end_time - start_time).total_seconds())

    # Calculate distance AND moving time (excludes stops/breaks)
    distance_km = None
    moving_time_seconds = None
    if all_points:
        from geopy.distance import geodesic
        total_m = 0
        moving_time = 0
        STOPPED_THRESHOLD = 0.5  # m/s - consider stopped if slower than this

        for i in range(1, len(all_points)):
            p1 = all_points[i-1]
            p2 = all_points[i]

            # Distance between points
            dist = geodesic((p1.latitude, p1.longitude), (p2.latitude, p2.longitude)).meters
            total_m += dist

            # Time between points
            if p1.time and p2.time:
                time_delta = (p2.time - p1.time).total_seconds()

                # Speed for this segment
                if time_delta > 0:
                    segment_speed = dist / time_delta

                    # Only count time if moving
                    if segment_speed > STOPPED_THRESHOLD:
                        moving_time += time_delta

        distance_km = round(total_m / 1000, 2)
        moving_time_seconds = int(moving_time)

    # Fallback: Detect activity type from average MOVING speed if not specified in GPX
    # Uses moving time (excludes stops/breaks) for accurate classification
    # Average cycling speed: 5.0+ m/s (18+ km/h)
    # Average running speed: 2.2-5.0 m/s (8-18 km/h)
    # Average walking speed: 0.5-2.0 m/s (2-7 km/h)
    if not activity_type and distance_km and moving_time_seconds and moving_time_seconds > 0:
        avg_speed_ms = (distance_km * 1000) / moving_time_seconds
        if avg_speed_ms >= 5.0:
            activity_type = 'cycling'
            print(f"ℹ Detected cycling from moving speed: {avg_speed_ms:.2f} m/s ({avg_speed_ms * 3.6:.1f} km/h)")
        elif avg_speed_ms >= 2.2:
            activity_type = 'run'
            print(f"ℹ Detected running from moving speed: {avg_speed_ms:.2f} m/s ({avg_speed_ms * 3.6:.1f} km/h)")
        else:
            activity_type = 'walk'
            print(f"ℹ Detected walking from moving speed: {avg_speed_ms:.2f} m/s ({avg_speed_ms * 3.6:.1f} km/h)")

    # Default to run if still unknown
    if not activity_type:
        activity_type = 'run'
        print("ℹ No activity type detected, defaulting to 'run'")

    # Workout hash for deduplication: date + time rounded to 10-minute bucket
    # Handles multiple runs per day, tolerates slight timing differences between apps
    workout_hash = None
    if start_time:
        # Round to nearest 10 minutes
        minute_bucket = (start_time.minute // 10) * 10
        workout_datetime = start_time.strftime(f"%Y-%m-%d %H:{minute_bucket:02d}")
        workout_hash = hashlib.sha256(workout_datetime.encode()).hexdigest()

    # Generate unique, descriptive filename
    # Format: YYYY-MM-DD_HHMM_<activity_type>_<distance_km>km.gpx
    import os
    import shutil
    original_filename = os.path.basename(gpx_file)

    if start_time and distance_km:
        # Create structured filename with timestamp, activity type, and distance
        timestamp_str = start_time.strftime("%Y-%m-%d_%H%M")
        distance_str = f"{distance_km:.1f}km"
        filename = f"{timestamp_str}_{activity_type}_{distance_str}.gpx"
        print(f"ℹ Generated filename: {filename} (original: {original_filename})")
    else:
        # Fallback to original filename if metadata is missing
        filename = original_filename
        print(f"⚠ Using original filename (missing metadata): {filename}")

    # Copy GPX file to project GPX directory with new filename
    # This makes bulk imports consistent with API uploads
    gpx_dir = os.getenv('GPX_DIR')
    if gpx_dir and os.path.isdir(gpx_dir):
        dest_path = os.path.join(gpx_dir, filename)
        # Only copy if source and destination are different
        if os.path.abspath(gpx_file) != os.path.abspath(dest_path):
            shutil.copy2(gpx_file, dest_path)
            print(f"ℹ Copied to: {dest_path}")

    # Determine target table based on activity type
    table_map = {
        'run': 'runs_raw',
        'walk': 'walks_raw',
        'cycling': 'cycling_raw'
    }
    table_name = table_map.get(activity_type, 'runs_raw')

    # Insert into appropriate database table
    conn = psycopg2.connect(
        dbname="$DB_NAME",
        user="$DB_USER",
        password="$PGPASSWORD",
        host="$DB_HOST"
    )
    cur = conn.cursor()

    # Calculate total_distance_m from distance_km
    total_distance_m = distance_km * 1000 if distance_km else None

    # Calculate avg_pace_min_per_mile for walks (and runs)
    avg_pace_min_per_mile = None
    if moving_time_seconds and moving_time_seconds > 0 and distance_km:
        # Convert to miles
        distance_miles = distance_km * 0.621371
        # Minutes per mile
        avg_pace_min_per_mile = moving_time_seconds / 60.0 / distance_miles if distance_miles > 0 else None

    # Build metadata JSON with useful stats
    import json
    metadata = {
        'moving_time_seconds': moving_time_seconds,
        'avg_speed_ms': round((distance_km * 1000) / moving_time_seconds, 2) if moving_time_seconds and moving_time_seconds > 0 and distance_km else None,
        'avg_speed_mph': round((distance_km * 0.621371) / (moving_time_seconds / 3600.0), 2) if moving_time_seconds and moving_time_seconds > 0 and distance_km else None,
        'avg_pace_min_per_mile': round(avg_pace_min_per_mile, 2) if avg_pace_min_per_mile else None,
        'total_time_seconds': duration_seconds,
        'stopped_time_seconds': (duration_seconds - moving_time_seconds) if duration_seconds and moving_time_seconds else None,
    }
    metadata_json = json.dumps(metadata)

    # Dynamic SQL with table name (safe because table_name comes from controlled dict)
    # Use different columns based on table (walks_raw has avg_pace_min_per_mile column, runs_raw has metadata)
    if table_name == 'walks_raw':
        insert_sql = f"""
            INSERT INTO runmap.{table_name} (filename, geom, workout_hash, start_time, duration_seconds, distance_km, total_distance_m, avg_pace_min_per_mile)
            VALUES (%s, ST_GeomFromText(%s, 4326), %s, %s, %s, %s, %s, %s)
            ON CONFLICT (workout_hash) DO NOTHING
            RETURNING id
        """
        cur.execute(insert_sql, (filename, wkt, workout_hash, start_time, duration_seconds, distance_km, total_distance_m, avg_pace_min_per_mile))
    elif table_name == 'runs_raw':
        insert_sql = f"""
            INSERT INTO runmap.{table_name} (filename, geom, workout_hash, start_time, duration_seconds, distance_km, total_distance_m, metadata)
            VALUES (%s, ST_GeomFromText(%s, 4326), %s, %s, %s, %s, %s, %s::jsonb)
            ON CONFLICT (workout_hash) DO NOTHING
            RETURNING id
        """
        cur.execute(insert_sql, (filename, wkt, workout_hash, start_time, duration_seconds, distance_km, total_distance_m, metadata_json))
    else:  # cycling_raw
        insert_sql = f"""
            INSERT INTO runmap.{table_name} (filename, geom, workout_hash, start_time, duration_seconds, distance_km, total_distance_m)
            VALUES (%s, ST_GeomFromText(%s, 4326), %s, %s, %s, %s, %s)
            ON CONFLICT (workout_hash) DO NOTHING
            RETURNING id
        """
        cur.execute(insert_sql, (filename, wkt, workout_hash, start_time, duration_seconds, distance_km, total_distance_m))

    result = cur.fetchone()
    if result:
        print(f"✓ Inserted {activity_type}: {result[0]} into {table_name}")
    else:
        print(f"⚠ Duplicate {activity_type} (already in database)")

    conn.commit()
    cur.close()
    conn.close()

except Exception as e:
    print(f"✗ Error: {e}")
    sys.exit(1)
EOF
