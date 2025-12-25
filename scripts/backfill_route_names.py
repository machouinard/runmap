#!/usr/bin/env python3
"""
Backfill route_name column for existing activities.

This script populates the route_name field for existing activities.
It extracts the name from the GPX file and uses our route naming logic
to preserve WorkoutDoors/custom names while standardizing generic ones.

Usage:
    # Dry run (preview changes without applying them)
    python3 scripts/backfill_route_names.py --dry-run

    # Apply changes to all activities
    python3 scripts/backfill_route_names.py

    # Force overwrite existing names (e.g., to apply new logic)
    python3 scripts/backfill_route_names.py --force

    # Limit to first N activities (for testing)
    python3 scripts/backfill_route_names.py --limit 10
"""

import os
import sys
import argparse
import psycopg2
from psycopg2.extras import RealDictCursor

# Add common scripts directory to path
script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(script_dir, 'common'))

from route_naming import get_route_name
import gpxpy

# Database connection parameters
DB_HOST = os.getenv('DB_HOST', 'localhost')
DB_NAME = os.getenv('DB_NAME', 'runmap')
DB_USER = os.getenv('DB_USER', 'runmap_user')
DB_PASS = os.getenv('PGPASSWORD', 'fucker')

# GPX directory
GPX_DIR = os.getenv('GPX_DIR', os.path.join(os.path.dirname(script_dir), 'gpx'))


def get_db_connection():
    """Create database connection"""
    return psycopg2.connect(
        host=DB_HOST,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )


def extract_gpx_name(gpx_filepath):
    """
    Extract track name and creator from GPX file.
    Returns (name, creator) tuple.
    """
    if not os.path.exists(gpx_filepath):
        return None, None

    try:
        with open(gpx_filepath, 'r', encoding='utf-8') as f:
            gpx = gpxpy.parse(f)
            name = None
            if gpx.tracks and gpx.tracks[0].name:
                name = gpx.tracks[0].name.strip()
            return name, gpx.creator
    except Exception as e:
        print(f"  ⚠ Warning: Failed to parse GPX file {gpx_filepath}: {e}")

    return None, None


def backfill_table(table_name, activity_type, dry_run=False, limit=None, force=False):
    """
    Backfill route_name for a specific activity table.

    Args:
        table_name: Database table name (runs_raw, walks_raw, cycling_raw)
        activity_type: Activity type string (run, walk, cycling)
        dry_run: If True, don't apply changes
        limit: Optional limit on number of rows to process
        force: If True, process all rows even if route_name exists
    """
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)

    # Get activities
    where_clause = "WHERE route_name IS NULL" if not force else ""
    
    query = f"""
        SELECT id, filename, start_time
        FROM runmap.{table_name}
        {where_clause}
        ORDER BY start_time DESC
    """

    if limit:
        query += f" LIMIT {limit}"

    cur.execute(query)
    activities = cur.fetchall()

    if not activities:
        print(f"✓ No activities need backfilling in {table_name}")
        cur.close()
        conn.close()
        return 0

    print(f"\n{'[DRY RUN] ' if dry_run else ''}Processing {len(activities)} activities from {table_name}...")

    updated_count = 0

    for activity in activities:
        activity_id = activity['id']
        filename = activity['filename']
        start_time = activity['start_time']

        # Try to extract name from GPX file
        gpx_path = os.path.join(GPX_DIR, filename)
        gpx_name, creator = extract_gpx_name(gpx_path)

        # Generate route name using our naming logic
        route_name = get_route_name(gpx_name, start_time, activity_type, creator)

        print(f"  {activity_id[:8]}... | {filename:40} | GPX: {gpx_name or 'None':25} (Creator: {creator or 'None'}) → {route_name}")

        if not dry_run:
            # Update the database
            update_query = f"""
                UPDATE runmap.{table_name}
                SET route_name = %s
                WHERE id = %s
            """
            cur.execute(update_query, (route_name, activity_id))
            updated_count += 1

    if not dry_run:
        conn.commit()
        print(f"\n✓ Updated {updated_count} activities in {table_name}")
    else:
        print(f"\n[DRY RUN] Would update {len(activities)} activities in {table_name}")

    cur.close()
    conn.close()

    return updated_count if not dry_run else len(activities)


def main():
    parser = argparse.ArgumentParser(
        description='Backfill route_name column for existing activities',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Preview changes without applying them'
    )
    parser.add_argument(
        '--force',
        action='store_true',
        help='Overwrite existing route names'
    )
    parser.add_argument(
        '--limit',
        type=int,
        help='Limit number of activities to process (for testing)'
    )
    parser.add_argument(
        '--type',
        choices=['run', 'walk', 'cycling', 'all'],
        default='all',
        help='Activity type to backfill (default: all)'
    )

    args = parser.parse_args()

    print("=" * 80)
    print("ROUTE NAME BACKFILL SCRIPT")
    print("=" * 80)

    if args.dry_run:
        print("\n⚠ DRY RUN MODE - No changes will be applied\n")

    # Define which tables to process
    tables = {
        'runs_raw': 'run',
        'walks_raw': 'walk',
        'cycling_raw': 'cycling'
    }

    # Filter by type if specified
    if args.type != 'all':
        tables = {k: v for k, v in tables.items() if v == args.type}

    total_updated = 0

    for table_name, activity_type in tables.items():
        count = backfill_table(table_name, activity_type, args.dry_run, args.limit, args.force)
        total_updated += count

    print("\n" + "=" * 80)
    if args.dry_run:
        print(f"[DRY RUN] Would update {total_updated} total activities")
        print("\nTo apply these changes, run without --dry-run flag")
    else:
        print(f"✓ Successfully updated {total_updated} total activities")
    print("=" * 80)


if __name__ == '__main__':
    main()
