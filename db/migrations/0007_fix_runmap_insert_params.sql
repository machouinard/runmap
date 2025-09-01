-- Avoid ambiguous column/argument names by renaming function parameters and using them explicitly
CREATE OR REPLACE FUNCTION runmap.insert_run_from_wkt(
  p_wkt          text,
  p_start_time   timestamptz,
  p_duration_s   integer,
  p_distance_km  numeric,
  p_source_file  text,
  p_content_hash text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO runmap.runs_raw (start_time, duration_s, distance_km, source_file, content_hash, geom)
  VALUES (p_start_time, p_duration_s, p_distance_km, p_source_file, p_content_hash, ST_SetSRID(ST_GeomFromText(p_wkt),4326))
  ON CONFLICT (content_hash) DO UPDATE
    SET start_time  = EXCLUDED.start_time,
        duration_s  = EXCLUDED.duration_s,
        distance_km = EXCLUDED.distance_km,
        source_file = EXCLUDED.source_file
  RETURNING id INTO v_id;

  PERFORM runmap.refresh_pipeline();
  RETURN v_id;
END;
$$;
