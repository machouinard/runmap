-- Create tables for non-running activities (walks, cycling, etc.)
-- These are tracked separately and don't affect running coverage statistics

-- Walks table (similar structure to runs_raw)
CREATE TABLE IF NOT EXISTS runmap.walks_raw (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  filename TEXT NOT NULL,
  uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  geom geometry(MultiLineString, 4326),
  content_hash TEXT UNIQUE NOT NULL,
  avg_pace_min_per_mile FLOAT,  -- For analysis
  total_distance_m FLOAT,
  duration_seconds INT
);

CREATE INDEX IF NOT EXISTS idx_walks_geom ON runmap.walks_raw USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_walks_uploaded_at ON runmap.walks_raw(uploaded_at);
CREATE INDEX IF NOT EXISTS idx_walks_content_hash ON runmap.walks_raw(content_hash);

-- Cycling table (optional - for separate tracking)
CREATE TABLE IF NOT EXISTS runmap.cycling_raw (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  filename TEXT NOT NULL,
  uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  geom geometry(MultiLineString, 4326),
  content_hash TEXT UNIQUE NOT NULL,
  avg_speed_mph FLOAT,
  total_distance_m FLOAT,
  duration_seconds INT
);

CREATE INDEX IF NOT EXISTS idx_cycling_geom ON runmap.cycling_raw USING GIST(geom);
CREATE INDEX IF NOT EXISTS idx_cycling_uploaded_at ON runmap.cycling_raw(uploaded_at);
CREATE INDEX IF NOT EXISTS idx_cycling_content_hash ON runmap.cycling_raw(content_hash);

-- Add activity_type column to runs_raw (for future reference)
ALTER TABLE runmap.runs_raw
  ADD COLUMN IF NOT EXISTS activity_type TEXT DEFAULT 'run';

ALTER TABLE runmap.walks_raw
  ADD COLUMN IF NOT EXISTS activity_type TEXT DEFAULT 'walk';

ALTER TABLE runmap.cycling_raw
  ADD COLUMN IF NOT EXISTS activity_type TEXT DEFAULT 'cycle';

-- Create index on activity_type for filtering
CREATE INDEX IF NOT EXISTS idx_runs_activity_type ON runmap.runs_raw(activity_type);
CREATE INDEX IF NOT EXISTS idx_walks_activity_type ON runmap.walks_raw(activity_type);
CREATE INDEX IF NOT EXISTS idx_cycling_activity_type ON runmap.cycling_raw(activity_type);

-- View to see all activities combined (for analysis)
CREATE OR REPLACE VIEW runmap.all_activities AS
SELECT
  id,
  filename,
  uploaded_at,
  geom,
  content_hash,
  'run' as activity_type,
  NULL::float as avg_pace_min_per_mile,
  NULL::float as avg_speed_mph,
  NULL::float as total_distance_m,
  NULL::int as duration_seconds
FROM runmap.runs_raw

UNION ALL

SELECT
  id,
  filename,
  uploaded_at,
  geom,
  content_hash,
  'walk' as activity_type,
  avg_pace_min_per_mile,
  NULL::float as avg_speed_mph,
  total_distance_m,
  duration_seconds
FROM runmap.walks_raw

UNION ALL

SELECT
  id,
  filename,
  uploaded_at,
  geom,
  content_hash,
  'cycle' as activity_type,
  NULL::float as avg_pace_min_per_mile,
  avg_speed_mph,
  total_distance_m,
  duration_seconds
FROM runmap.cycling_raw;

-- Summary statistics view
CREATE OR REPLACE VIEW runmap.activity_stats AS
SELECT
  activity_type,
  COUNT(*) as total_count,
  SUM(total_distance_m) / 1609.34 as total_miles,
  SUM(duration_seconds) / 3600.0 as total_hours
FROM (
  SELECT 'run' as activity_type, NULL::float as total_distance_m, NULL::int as duration_seconds
  FROM runmap.runs_raw
  UNION ALL
  SELECT 'walk', total_distance_m, duration_seconds FROM runmap.walks_raw
  UNION ALL
  SELECT 'cycle', total_distance_m, duration_seconds FROM runmap.cycling_raw
) combined
GROUP BY activity_type
ORDER BY activity_type;

COMMENT ON TABLE runmap.walks_raw IS 'Walking activities - not included in running coverage calculations';
COMMENT ON TABLE runmap.cycling_raw IS 'Cycling activities - tracked separately from running';
COMMENT ON VIEW runmap.all_activities IS 'Combined view of all activity types for analysis';
COMMENT ON VIEW runmap.activity_stats IS 'Summary statistics across all activity types';
