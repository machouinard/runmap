#!/usr/bin/env python3
"""
Detect activity type (run vs walk vs cycle) from GPX file using pace calculation.

Used for iOS shortcut uploads where Apple Health export.xml is not available.

Classification rules:
- Running: <= 12 min/mile (>= 4.0 mph)
- Walking: > 12 min/mile and <= 4.0 mph (< 15 mph)
- Cycling: > 15 mph
- Unknown: < 100m distance or < 60 seconds duration

Also checks for fast segments to catch runs with walk breaks.

Usage:
    python scripts/detect_activity_type.py <gpx_file>

Output (JSON):
{
    "type": "run" | "walk" | "cycle" | "unknown",
    "avg_pace_min_per_mile": float,
    "total_distance_m": float,
    "duration_seconds": int,
    "fastest_mile_pace": float | null
}

Exit codes:
    0 = run
    1 = walk
    2 = cycle
    3 = unknown
"""

import sys
import json
import gpxpy
import gpxpy.gpx


def meters_to_miles(meters):
    """Convert meters to miles."""
    return meters / 1609.34


def meters_per_second_to_min_per_mile(mps):
    """Convert meters/second to minutes/mile."""
    if mps == 0:
        return float('inf')
    mph = mps * 2.23694  # m/s to mph
    if mph == 0:
        return float('inf')
    return 60.0 / mph  # minutes per mile


def analyze_gpx(file_path):
    """
    Analyze GPX file to determine activity type.

    Returns dict with activity type and statistics.
    """
    try:
        with open(file_path, 'r') as gpx_file:
            gpx = gpxpy.parse(gpx_file)
    except Exception as e:
        return {
            'type': 'unknown',
            'error': f'Failed to parse GPX: {str(e)}',
            'avg_pace_min_per_mile': None,
            'avg_speed_mph': None,
            'total_distance_m': None,
            'duration_seconds': None,
            'fastest_segment_pace': None
        }

    # Calculate total distance and time
    total_distance = 0.0
    total_time = 0.0
    fastest_segment_pace = None
    segment_stats = []

    for track in gpx.tracks:
        for segment in track.segments:
            if len(segment.points) < 2:
                continue

            # Calculate segment statistics
            segment_distance = 0.0
            segment_time = 0.0

            for i in range(1, len(segment.points)):
                p1 = segment.points[i - 1]
                p2 = segment.points[i]

                # Distance between points
                distance = p1.distance_3d(p2) if p1.elevation and p2.elevation else p1.distance_2d(p2)
                if distance:
                    segment_distance += distance
                    total_distance += distance

                # Time between points
                if p1.time and p2.time:
                    time_diff = (p2.time - p1.time).total_seconds()
                    if time_diff > 0:
                        segment_time += time_diff
                        total_time += time_diff

            # Calculate segment pace (for detecting run segments in mixed activities)
            if segment_distance > 100 and segment_time > 10:  # Ignore very short segments
                segment_speed_mps = segment_distance / segment_time
                segment_pace = meters_per_second_to_min_per_mile(segment_speed_mps)
                segment_stats.append({
                    'distance': segment_distance,
                    'time': segment_time,
                    'pace': segment_pace
                })

                # Track fastest segment
                if fastest_segment_pace is None or segment_pace < fastest_segment_pace:
                    fastest_segment_pace = segment_pace

    # Handle edge cases
    if total_distance < 100:  # Less than 100m - probably GPS test
        return {
            'type': 'unknown',
            'reason': 'Activity too short (< 100m)',
            'avg_pace_min_per_mile': None,
            'avg_speed_mph': None,
            'total_distance_m': round(total_distance, 2),
            'total_distance_miles': round(meters_to_miles(total_distance), 2),
            'duration_seconds': int(total_time),
            'fastest_segment_pace': None
        }

    if total_time < 60:  # Less than 1 minute
        return {
            'type': 'unknown',
            'reason': 'Duration too short (< 1 minute)',
            'avg_pace_min_per_mile': None,
            'avg_speed_mph': None,
            'total_distance_m': round(total_distance, 2),
            'total_distance_miles': round(meters_to_miles(total_distance), 2),
            'duration_seconds': int(total_time),
            'fastest_segment_pace': None
        }

    # Calculate average speed and pace
    avg_speed_mps = total_distance / total_time
    avg_speed_mph = avg_speed_mps * 2.23694
    avg_pace_min_per_mile = meters_per_second_to_min_per_mile(avg_speed_mps)

    # Classification logic
    activity_type = 'unknown'
    reason = ''

    # Rule 1: Very fast = cycling
    if avg_speed_mph > 15.0:
        activity_type = 'cycle'
        reason = f'Average speed {avg_speed_mph:.1f} mph (cycling threshold: > 15 mph)'

    # Rule 2: Has fast segment = run (even if average is slow due to walk breaks)
    elif fastest_segment_pace and fastest_segment_pace < 10.0:
        activity_type = 'run'
        reason = f'Has fast segment ({fastest_segment_pace:.1f} min/mile, threshold: < 10 min/mile)'

    # Rule 3: Average pace determines run vs walk
    elif avg_pace_min_per_mile <= 12.0:
        activity_type = 'run'
        reason = f'Average pace {avg_pace_min_per_mile:.1f} min/mile (run threshold: ≤ 12 min/mile)'
    else:
        activity_type = 'walk'
        reason = f'Average pace {avg_pace_min_per_mile:.1f} min/mile (walk threshold: > 12 min/mile)'

    return {
        'type': activity_type,
        'reason': reason,
        'avg_pace_min_per_mile': round(avg_pace_min_per_mile, 2) if avg_pace_min_per_mile != float('inf') else None,
        'avg_speed_mph': round(avg_speed_mph, 2),
        'total_distance_m': round(total_distance, 2),
        'total_distance_miles': round(meters_to_miles(total_distance), 2),
        'duration_seconds': int(total_time),
        'duration_minutes': round(total_time / 60, 1),
        'fastest_segment_pace': round(fastest_segment_pace, 2) if fastest_segment_pace and fastest_segment_pace != float('inf') else None
    }


def main():
    if len(sys.argv) != 2:
        print(json.dumps({
            'type': 'unknown',
            'error': 'Usage: detect_activity_type.py <gpx_file>'
        }))
        sys.exit(3)

    gpx_file = sys.argv[1]
    result = analyze_gpx(gpx_file)

    # Output JSON for easy parsing in shell scripts
    print(json.dumps(result, indent=2))

    # Exit code: 0 = run, 1 = walk, 2 = cycle, 3 = unknown
    if result['type'] == 'run':
        sys.exit(0)
    elif result['type'] == 'walk':
        sys.exit(1)
    elif result['type'] == 'cycle':
        sys.exit(2)
    else:
        sys.exit(3)


if __name__ == '__main__':
    main()
