-- Migration: Replace content_hash with workout_hash
-- Reason: Content hash doesn't detect same workout from different export sources
-- Solution: Hash start_time + duration instead of file content

-- Drop dependent view first
DROP VIEW IF EXISTS runmap.all_activities;

-- Update runs_raw table
ALTER TABLE runmap.runs_raw DROP CONSTRAINT IF EXISTS runs_raw_content_hash_key;
ALTER TABLE runmap.runs_raw DROP COLUMN IF EXISTS content_hash;
ALTER TABLE runmap.runs_raw ADD COLUMN IF NOT EXISTS workout_hash TEXT;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'runs_raw_workout_hash_key') THEN
        ALTER TABLE runmap.runs_raw ADD CONSTRAINT runs_raw_workout_hash_key UNIQUE (workout_hash);
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_runs_raw_workout_hash ON runmap.runs_raw(workout_hash);

-- Update walks_raw table
ALTER TABLE runmap.walks_raw DROP CONSTRAINT IF EXISTS walks_raw_content_hash_key;
ALTER TABLE runmap.walks_raw DROP COLUMN IF EXISTS content_hash;
ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS workout_hash TEXT;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'walks_raw_workout_hash_key') THEN
        ALTER TABLE runmap.walks_raw ADD CONSTRAINT walks_raw_workout_hash_key UNIQUE (workout_hash);
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_walks_raw_workout_hash ON runmap.walks_raw(workout_hash);

-- Update cycling_raw table
ALTER TABLE runmap.cycling_raw DROP CONSTRAINT IF EXISTS cycling_raw_content_hash_key;
ALTER TABLE runmap.cycling_raw DROP COLUMN IF EXISTS content_hash;
ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS workout_hash TEXT;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'cycling_raw_workout_hash_key') THEN
        ALTER TABLE runmap.cycling_raw ADD CONSTRAINT cycling_raw_workout_hash_key UNIQUE (workout_hash);
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_cycling_raw_workout_hash ON runmap.cycling_raw(workout_hash);

-- Recreate all_activities view with workout_hash
CREATE OR REPLACE VIEW runmap.all_activities AS
SELECT
    id,
    filename,
    uploaded_at,
    geom,
    workout_hash,
    'run'::text AS activity_type,
    NULL::double precision AS avg_pace_min_per_mile,
    NULL::double precision AS avg_speed_mph,
    NULL::double precision AS total_distance_m,
    NULL::integer AS duration_seconds
FROM runmap.runs_raw
UNION ALL
SELECT
    id,
    filename,
    uploaded_at,
    geom,
    workout_hash,
    'walk'::text AS activity_type,
    avg_pace_min_per_mile,
    NULL::double precision AS avg_speed_mph,
    total_distance_m,
    duration_seconds
FROM runmap.walks_raw
UNION ALL
SELECT
    id,
    filename,
    uploaded_at,
    geom,
    workout_hash,
    'cycle'::text AS activity_type,
    NULL::double precision AS avg_pace_min_per_mile,
    avg_speed_mph,
    total_distance_m,
    duration_seconds
FROM runmap.cycling_raw;

-- Note: workout_hash will be calculated as:
-- workout_date = start_time.date().isoformat()  # "2025-10-18"
-- start_lat = round(first_point.latitude, 4)     # 38.5620 (~10m precision)
-- start_lon = round(first_point.longitude, 4)    # -121.4690
-- distance_km = round(total_distance_km, 1)      # 15.4 km (0.1km precision)
-- workout_key = f"{workout_date}|{start_lat}|{start_lon}|{distance_km}"
-- workout_hash = hashlib.sha256(workout_key.encode()).hexdigest()
--
-- This detects same workout from different export sources (WorkoutDoors, Apple Health, etc.)
-- Different apps record slightly different start times/durations, but date+location+distance is consistent
