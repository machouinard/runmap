#!/usr/bin/env python3
"""
Parse Apple Health export.xml to classify workout types.

Creates a mapping of GPX filename → activity type for bulk import.

Usage:
    python scripts/parse_apple_health_export.py <export_xml_path> [--output JSON_FILE]

Output:
{
    "route_2024-01-11_6.56pm.gpx": {
        "activity_type": "walk",
        "start_date": "2024-01-11T19:36:08-07:00",
        "duration_minutes": 20.82,
        "distance_miles": 1.2
    },
    ...
}
"""

import sys
import json
import xml.etree.ElementTree as ET
from datetime import datetime
import argparse


# Mapping of Apple Health activity types to our simplified types
ACTIVITY_TYPE_MAP = {
    'HKWorkoutActivityTypeRunning': 'run',
    'HKWorkoutActivityTypeWalking': 'walk',
    'HKWorkoutActivityTypeCycling': 'cycle',  # May want to track separately
    'HKWorkoutActivityTypeHiking': 'walk',    # Treat hiking as walking
    # Ignore types without GPS tracks:
    'HKWorkoutActivityTypeTraditionalStrengthTraining': None,
    'HKWorkoutActivityTypeSwimming': None,
    'HKWorkoutActivityTypeClimbing': None,
}


def parse_export_xml(xml_path):
    """
    Parse Apple Health export.xml and extract workout metadata.

    Returns dict mapping GPX filename → workout metadata.
    """
    print(f"Parsing {xml_path}...", file=sys.stderr)
    print(f"This may take 30-60 seconds for large exports...", file=sys.stderr)

    # Parse incrementally to handle large XML files (2GB+)
    workout_map = {}
    current_workout = None
    gpx_filename = None

    try:
        # Use iterparse for memory-efficient parsing of large XML
        context = ET.iterparse(xml_path, events=('start', 'end'))

        for event, elem in context:
            if event == 'start' and elem.tag == 'Workout':
                # Start of workout entry
                current_workout = {
                    'activity_type_raw': elem.get('workoutActivityType'),
                    'start_date': elem.get('startDate'),
                    'end_date': elem.get('endDate'),
                    'duration': elem.get('duration'),
                    'duration_unit': elem.get('durationUnit', 'min'),
                    'total_distance': elem.get('totalDistance'),
                    'total_distance_unit': elem.get('totalDistanceUnit', 'mi'),
                }

            elif event == 'end' and elem.tag == 'FileReference':
                # GPX file reference found
                path = elem.get('path', '')
                if '/workout-routes/' in path:
                    gpx_filename = path.split('/')[-1]  # Extract filename only

            elif event == 'end' and elem.tag == 'Workout':
                # End of workout entry - save if has GPX
                if current_workout and gpx_filename:
                    activity_type_raw = current_workout['activity_type_raw']
                    activity_type = ACTIVITY_TYPE_MAP.get(activity_type_raw)

                    if activity_type:  # Only include activities we care about
                        workout_map[gpx_filename] = {
                            'activity_type': activity_type,
                            'activity_type_raw': activity_type_raw,
                            'start_date': current_workout['start_date'],
                            'end_date': current_workout['end_date'],
                            'duration_minutes': float(current_workout['duration']) if current_workout['duration'] else None,
                            'distance_miles': float(current_workout['total_distance']) if current_workout['total_distance'] else None,
                        }

                # Clear context to avoid memory issues
                elem.clear()
                current_workout = None
                gpx_filename = None

    except ET.ParseError as e:
        print(f"ERROR: Failed to parse XML: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"✅ Parsed {len(workout_map)} workouts with GPX tracks", file=sys.stderr)

    return workout_map


def print_statistics(workout_map):
    """Print summary statistics."""
    type_counts = {}
    for data in workout_map.values():
        activity_type = data['activity_type']
        type_counts[activity_type] = type_counts.get(activity_type, 0) + 1

    print("\n📊 Activity Type Summary:", file=sys.stderr)
    for activity_type in sorted(type_counts.keys()):
        count = type_counts[activity_type]
        print(f"  {activity_type:>6s}: {count:>3d} workouts", file=sys.stderr)

    print(f"  {'TOTAL':>6s}: {len(workout_map):>3d} workouts\n", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description='Parse Apple Health export.xml')
    parser.add_argument('export_xml', help='Path to export.xml file')
    parser.add_argument('--output', '-o', help='Output JSON file (default: stdout)')
    parser.add_argument('--stats', action='store_true', help='Print statistics only')

    args = parser.parse_args()

    workout_map = parse_export_xml(args.export_xml)

    print_statistics(workout_map)

    if not args.stats:
        # Output JSON
        json_output = json.dumps(workout_map, indent=2)

        if args.output:
            with open(args.output, 'w') as f:
                f.write(json_output)
            print(f"✅ Saved mapping to {args.output}", file=sys.stderr)
        else:
            print(json_output)


if __name__ == '__main__':
    main()
