-- Convenience views showing local time (America/Los_Angeles)

CREATE OR REPLACE VIEW runmap.runs_raw_local AS
SELECT
  id,
  start_time,
  (start_time AT TIME ZONE 'America/Los_Angeles') AS start_time_local,
  duration_s,
  distance_km,
  source_file,
  content_hash,
  geom,
  created_at
FROM runmap.runs_raw
ORDER BY created_at DESC;
