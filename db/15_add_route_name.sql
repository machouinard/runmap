-- Migration: Add route_name column to activity tables
-- Purpose: Store user-friendly activity names like "Sunday Morning Run"
-- Date: 2025-11-24

-- Add route_name column to all three activity tables
ALTER TABLE runmap.runs_raw ADD COLUMN IF NOT EXISTS route_name TEXT;
ALTER TABLE runmap.walks_raw ADD COLUMN IF NOT EXISTS route_name TEXT;
ALTER TABLE runmap.cycling_raw ADD COLUMN IF NOT EXISTS route_name TEXT;

-- Add comments to document the purpose
COMMENT ON COLUMN runmap.runs_raw.route_name IS 'User-friendly route name (e.g., "Sunday Morning Run"). Auto-generated from start time or extracted from GPX <trk><name> if it matches WorkoutDoors pattern.';
COMMENT ON COLUMN runmap.walks_raw.route_name IS 'User-friendly route name (e.g., "Thursday Night Walk"). Auto-generated from start time or extracted from GPX <trk><name> if it matches WorkoutDoors pattern.';
COMMENT ON COLUMN runmap.cycling_raw.route_name IS 'User-friendly route name (e.g., "Saturday Afternoon Ride"). Auto-generated from start time or extracted from GPX <trk><name> if it matches WorkoutDoors pattern.';

-- No default value - NULL indicates the name hasn't been set yet
-- Backfill will be done via separate script

-- Update the all_activities view to include route_name
DROP VIEW IF EXISTS runmap.all_activities;

CREATE OR REPLACE VIEW runmap.all_activities AS
SELECT
  id,
  filename,
  uploaded_at,
  start_time,
  geom,
  workout_hash,
  'run' as activity_type,
  NULL::float as avg_pace_min_per_mile,
  NULL::float as avg_speed_mph,
  NULL::float as total_distance_m,
  NULL::int as duration_seconds,
  route_name
FROM runmap.runs_raw

UNION ALL

SELECT
  id,
  filename,
  uploaded_at,
  start_time,
  geom,
  workout_hash,
  'walk' as activity_type,
  avg_pace_min_per_mile,
  NULL::float as avg_speed_mph,
  total_distance_m,
  duration_seconds,
  route_name
FROM runmap.walks_raw

UNION ALL

SELECT
  id,
  filename,
  uploaded_at,
  start_time,
  geom,
  workout_hash,
  'cycle' as activity_type,
  NULL::float as avg_pace_min_per_mile,
  avg_speed_mph,
  total_distance_m,
  duration_seconds,
  route_name
FROM runmap.cycling_raw;

COMMIT;
