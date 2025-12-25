#!/bin/bash
# Backfill workout_hash for existing runs
# Calculates hash as: sha256(start_time.isoformat() + "|" + duration_seconds)

set -e

# Database connection (use defaults or environment)
DB_HOST=${DB_HOST:-192.168.68.25}
DB_USER=${DB_USER:-runmap_user}
DB_NAME=${DB_NAME:-runmap}

echo "Backfilling workout_hash for existing runs..."

psql -h $DB_HOST -U $DB_USER -d $DB_NAME << 'EOF'
UPDATE runmap.runs_raw
SET workout_hash = encode(
    digest(
        to_char(start_time, 'YYYY-MM-DD"T"HH24:MI:SS.US"+00:00"') || '|' || duration_seconds::text,
        'sha256'
    ),
    'hex'
)
WHERE workout_hash IS NULL
  AND start_time IS NOT NULL
  AND duration_seconds IS NOT NULL;

SELECT COUNT(*) as updated_runs FROM runmap.runs_raw WHERE workout_hash IS NOT NULL;
EOF

echo "✓ Backfill complete!"
