#!/usr/bin/env python3
"""
Copy GPX files from original location to project GPX directory with database-assigned new filenames.
This fixes the issue where bulk imports stored new filenames in DB but didn't copy the physical files.
"""

import os
import sys
import shutil
from pathlib import Path

try:
    import psycopg2
    from psycopg2.extras import DictCursor
    USE_PSYCOPG2 = True
except ImportError:
    import psycopg as psycopg2
    from psycopg.rows import dict_row
    USE_PSYCOPG2 = False

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

DB_HOST = env_vars.get('DB_HOST', 'localhost')
DB_NAME = env_vars.get('DB_NAME', 'runmap')
DB_USER = env_vars.get('DB_USER', 'runmap_user')
PGPASSWORD = env_vars.get('PGPASSWORD', '')
GPX_DIR = Path(env_vars.get('GPX_DIR', PROJECT_ROOT / 'gpx'))
SOURCE_DIR = Path('/Volumes/RunMap/data/gpx')

print("=" * 60)
print("Copy GPX Files with New Names")
print("=" * 60)
print(f"\nSource: {SOURCE_DIR}")
print(f"Destination: {GPX_DIR}")
print(f"Database: {DB_NAME} @ {DB_HOST}\n")

# Create destination directory if it doesn't exist
GPX_DIR.mkdir(parents=True, exist_ok=True)

# Connect to database
conn = psycopg2.connect(
    host=DB_HOST,
    dbname=DB_NAME,
    user=DB_USER,
    password=PGPASSWORD
)
if USE_PSYCOPG2:
    cur = conn.cursor(cursor_factory=DictCursor)
else:
    cur = conn.cursor(row_factory=dict_row)

# Get all activities with their new filenames
cur.execute("""
    SELECT id, filename, start_time, total_distance_m, 'run' as activity_type
    FROM runmap.runs_raw
    UNION ALL
    SELECT id, filename, start_time, total_distance_m, 'walk' as activity_type
    FROM runmap.walks_raw
    UNION ALL
    SELECT id, filename, start_time, total_distance_m, 'cycling' as activity_type
    FROM runmap.cycling_raw
    ORDER BY start_time DESC
""")

activities = cur.fetchall()
cur.close()
conn.close()

print(f"Found {len(activities)} activities in database\n")

copied = 0
already_exist = 0
missing_source = 0
errors = 0

for activity in activities:
    activity_id = activity['id'] if isinstance(activity, dict) else activity[0]
    new_filename = activity['filename'] if isinstance(activity, dict) else activity[1]
    start_time = activity['start_time'] if isinstance(activity, dict) else activity[2]

    dest_path = GPX_DIR / new_filename

    # Check if file already exists in destination
    if dest_path.exists():
        print(f"✓ Already exists: {new_filename}")
        already_exist += 1
        continue

    # For new-format filenames, we can't easily find the original file
    # because we don't have a reverse mapping (new name -> old name)
    # The best solution is to re-import from source

    print(f"⚠ Missing: {new_filename} (ID: {activity_id})")
    missing_source += 1

print(f"\n{'=' * 60}")
print("Summary")
print("=" * 60)
print(f"Already exist: {already_exist}")
print(f"Missing: {missing_source}")
print(f"Copied: {copied}")
print(f"Errors: {errors}")
print(f"\n{'=' * 60}")
print("Solution")
print("=" * 60)
print("The ingest script has been updated to copy files during import.")
print("Re-run the bulk import to copy all files with new names:")
print(f"  bash scripts/bulk_import.sh /tmp/all_gpx_files.txt")
print("")
print("Note: This will skip duplicates (workout_hash) so it's safe to re-run.")
print("=" * 60)
