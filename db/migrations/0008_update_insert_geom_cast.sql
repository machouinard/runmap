-- Ensure insert converts any GPX-derived geometry to MultiLineString 4326
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
  v_id   uuid;
  v_geom geometry(MultiLineString,4326);
BEGIN
  -- Normalize any incoming WKT (LineString, MultiLineString, or GeometryCollection of lines)
  v_geom := ST_Multi(
              ST_LineMerge(
                ST_CollectionExtract(
                  ST_SetSRID(ST_GeomFromText(p_wkt), 4326),
                  2 -- extract lines
                )
              )
            )::geometry(MultiLineString,4326);

  INSERT INTO runmap.runs_raw (start_time, duration_s, distance_km, source_file, content_hash, geom)
  VALUES (p_start_time, p_duration_s, p_distance_km, p_source_file, p_content_hash, v_geom)
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
