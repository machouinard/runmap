#!/usr/bin/env python3
"""
Test activity classification accuracy by comparing:
1. Apple Health export.xml classification (ground truth)
2. Pace-based automatic classification (for iOS shortcut)

Usage:
    python scripts/test_classification.py <workout_types.json> <workout-routes-dir> [--sample N]

Example:
    python scripts/test_classification.py data/workout_types.json data/workout-routes --sample 20
"""

import sys
import json
import argparse
from pathlib import Path
from detect_activity_type import analyze_gpx


def load_ground_truth(workout_types_file):
    """Load Apple Health classification as ground truth."""
    with open(workout_types_file, 'r') as f:
        return json.load(f)


def test_classification(ground_truth, gpx_dir, sample_size=None):
    """
    Compare automatic classification against Apple Health ground truth.

    Returns dict with accuracy metrics and mismatches.
    """
    gpx_files = list(Path(gpx_dir).glob('*.gpx'))

    if sample_size:
        # Sample evenly across activity types
        runs = [f for f in gpx_files if ground_truth.get(f.name, {}).get('activity_type') == 'run']
        walks = [f for f in gpx_files if ground_truth.get(f.name, {}).get('activity_type') == 'walk']
        cycles = [f for f in gpx_files if ground_truth.get(f.name, {}).get('activity_type') == 'cycle']

        sample = []
        if runs:
            sample.extend(runs[:sample_size // 2])
        if walks:
            sample.extend(walks[:sample_size // 2])
        if cycles:
            sample.extend(cycles[:min(len(cycles), 5)])

        gpx_files = sample[:sample_size]

    results = {
        'total': 0,
        'correct': 0,
        'mismatches': [],
        'confusion_matrix': {
            'run': {'run': 0, 'walk': 0, 'cycle': 0, 'unknown': 0},
            'walk': {'run': 0, 'walk': 0, 'cycle': 0, 'unknown': 0},
            'cycle': {'run': 0, 'walk': 0, 'cycle': 0, 'unknown': 0}
        }
    }

    print(f"Testing {len(gpx_files)} files...\n")

    for gpx_file in gpx_files:
        filename = gpx_file.name

        # Get ground truth from Apple Health
        ground_truth_data = ground_truth.get(filename)
        if not ground_truth_data:
            print(f"⚠️  {filename}: Not in Apple Health export (skipping)")
            continue

        expected_type = ground_truth_data['activity_type']

        # Run automatic classification
        classification = analyze_gpx(str(gpx_file))
        detected_type = classification['type']

        results['total'] += 1

        # Update confusion matrix
        if expected_type in results['confusion_matrix']:
            results['confusion_matrix'][expected_type][detected_type] += 1

        # Check if match
        if expected_type == detected_type:
            results['correct'] += 1
            print(f"✅ {filename}: {expected_type} (correct)")
        else:
            results['mismatches'].append({
                'filename': filename,
                'expected': expected_type,
                'detected': detected_type,
                'reason': classification.get('reason', 'N/A'),
                'avg_pace': classification.get('avg_pace_min_per_mile'),
                'avg_speed_mph': classification.get('avg_speed_mph'),
                'distance_miles': classification.get('total_distance_miles'),
                'duration_minutes': classification.get('duration_minutes')
            })
            print(f"❌ {filename}: Expected {expected_type}, got {detected_type}")
            print(f"   Reason: {classification.get('reason', 'N/A')}")

    return results


def print_summary(results):
    """Print test results summary."""
    print("\n" + "=" * 60)
    print("CLASSIFICATION ACCURACY REPORT")
    print("=" * 60)

    accuracy = (results['correct'] / results['total'] * 100) if results['total'] > 0 else 0

    print(f"\n📊 Overall Accuracy: {results['correct']}/{results['total']} ({accuracy:.1f}%)")

    print("\n📈 Confusion Matrix:")
    print(f"{'':>10s} | {'Run':>8s} | {'Walk':>8s} | {'Cycle':>8s} | {'Unknown':>8s}")
    print("-" * 60)

    for actual_type in ['run', 'walk', 'cycle']:
        counts = results['confusion_matrix'][actual_type]
        print(f"{actual_type.capitalize():>10s} | {counts['run']:>8d} | {counts['walk']:>8d} | {counts['cycle']:>8d} | {counts['unknown']:>8d}")

    if results['mismatches']:
        print(f"\n❌ Mismatches ({len(results['mismatches'])}):")
        print("-" * 60)

        for mismatch in results['mismatches']:
            print(f"\n  File: {mismatch['filename']}")
            print(f"  Expected: {mismatch['expected']} → Detected: {mismatch['detected']}")
            print(f"  Pace: {mismatch['avg_pace']} min/mile, Speed: {mismatch['avg_speed_mph']} mph")
            print(f"  Distance: {mismatch['distance_miles']} mi, Duration: {mismatch['duration_minutes']} min")
            print(f"  Reason: {mismatch['reason']}")

    print("\n" + "=" * 60)

    # Recommendations
    if accuracy >= 95:
        print("✅ Classification accuracy is excellent (≥95%)")
        print("   Safe to proceed with automatic classification for iOS shortcut.")
    elif accuracy >= 90:
        print("⚠️  Classification accuracy is good (≥90%) but has some errors.")
        print("   Consider reviewing mismatches and adjusting thresholds.")
    else:
        print("❌ Classification accuracy is below 90%.")
        print("   Review mismatches and adjust classification logic before using.")

    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(description='Test activity classification accuracy')
    parser.add_argument('workout_types', help='Path to workout_types.json (from export.xml)')
    parser.add_argument('gpx_dir', help='Path to workout-routes directory')
    parser.add_argument('--sample', '-n', type=int, help='Number of files to sample (default: all)')
    parser.add_argument('--output', '-o', help='Save results to JSON file')

    args = parser.parse_args()

    # Load ground truth
    ground_truth = load_ground_truth(args.workout_types)
    print(f"Loaded ground truth for {len(ground_truth)} workouts")

    # Run tests
    results = test_classification(ground_truth, args.gpx_dir, args.sample)

    # Print summary
    print_summary(results)

    # Save results if requested
    if args.output:
        with open(args.output, 'w') as f:
            json.dump(results, f, indent=2)
        print(f"\n💾 Saved detailed results to {args.output}")


if __name__ == '__main__':
    main()
