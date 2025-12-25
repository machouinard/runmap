#!/usr/bin/env python3
"""
Backfill workout_hash for existing runs in database.
Calculates hash exactly as ingest_gpx.sh and app.py do:
  hashlib.sha256(f"{start_time.isoformat()}|{duration_seconds}".encode()).hexdigest()
"""

import psycopg2
import hashlib
import sys

# Database connection
DB_HOST = "192.168.68.25"
DB_USER = "runmap_user"
DB_NAME = "runmap"
DB_PASSWORD = "fucker"  # TODO: Move to .pgpass

try:
    conn = psycopg2.connect(
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        host=DB_HOST
    )
    cur = conn.cursor()

    # Get all runs without workout_hash
    cur.execute("""
        SELECT id, start_time, duration_seconds
        FROM runmap.runs_raw
        WHERE workout_hash IS NULL
          AND start_time IS NOT NULL
          AND duration_seconds IS NOT NULL
    """)

    runs = cur.fetchall()
    print(f"Found {len(runs)} runs to backfill...")

    updated = 0
    for run_id, start_time, duration_seconds in runs:
        # Calculate workout hash exactly as Python code does
        workout_key = f"{start_time.isoformat()}|{duration_seconds}"
        workout_hash = hashlib.sha256(workout_key.encode()).hexdigest()

        # Update the run
        cur.execute("""
            UPDATE runmap.runs_raw
            SET workout_hash = %s
            WHERE id = %s
        """, (workout_hash, run_id))

        updated += 1
        if updated % 5 == 0:
            print(f"  Updated {updated} runs...")

    conn.commit()
    print(f"✓ Backfill complete! Updated {updated} runs.")

    # Verify
    cur.execute("SELECT COUNT(*) FROM runmap.runs_raw WHERE workout_hash IS NOT NULL")
    total = cur.fetchone()[0]
    print(f"  Total runs with workout_hash: {total}")

    cur.close()
    conn.close()

except Exception as e:
    print(f"✗ Error: {e}")
    sys.exit(1)
