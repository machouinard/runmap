-- Robust: normalize any input (LineString, MultiLineString, GeometryCollection) to MultiLineString(4326)
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
  v_in   geometry;
  v_ml   geometry(MultiLineString,4326);
BEGIN
  -- Parse and normalize to 2D
  v_in := ST_Force2D(ST_SetSRID(ST_GeomFromText(p_wkt), 4326));

  -- Keep only linework, union to dissolve touching segments, line-merge to simplify, wrap as Multi
  v_ml := ST_Multi(
            ST_LineMerge(
              ST_UnaryUnion(
                ST_CollectionExtract(v_in, 2)
              )
            )
          )::geometry(MultiLineString,4326);

  IF v_ml IS NULL THEN
    RAISE EXCEPTION 'No linework found in WKT input';
  END IF;

  INSERT INTO runmap.runs_raw (start_time, duration_s, distance_km, source_file, content_hash, geom)
  VALUES (p_start_time, p_duration_s, p_distance_km, p_source_file, p_content_hash, v_ml)
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

-- Nudge PostgREST to reload
DO $$ BEGIN PERFORM pg_notify('pgrst','reload schema'); END $$;
