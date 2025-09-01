-- Split refresh into quick and full; update insert to call quick only to avoid timeouts

-- Quick refresh: just the lightweight derived layers
CREATE OR REPLACE FUNCTION runmap.refresh_quick()
RETURNS void
LANGUAGE sql
AS $$
  REFRESH MATERIALIZED VIEW runmap.runs_collect;
  REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
$$;

-- Full refresh: everything (can be called manually or via scheduled job)
CREATE OR REPLACE FUNCTION runmap.refresh_all()
RETURNS void
LANGUAGE sql
AS $$
  REFRESH MATERIALIZED VIEW runmap.runs_collect;
  REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
  REFRESH MATERIALIZED VIEW runmap.streets_unrun;
  REFRESH MATERIALIZED VIEW runmap.coverage_stats;
$$;

-- Update insert to call quick refresh only
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
  -- Robust: extract only linework, force 2D, dump parts, and re-collect to MultiLineString(4326)
  SELECT ST_Multi(ST_Collect(d.geom))::geometry(MultiLineString,4326)
    INTO v_geom
  FROM (
    SELECT (ST_Dump(
             ST_CollectionExtract(
               ST_Force2D(ST_SetSRID(ST_GeomFromText(p_wkt),4326)),
               2
             )
           )).geom
  ) AS d;

  IF v_geom IS NULL THEN
    RAISE EXCEPTION 'No linework found in WKT input';
  END IF;

  INSERT INTO runmap.runs_raw (start_time, duration_s, distance_km, source_file, content_hash, geom)
  VALUES (p_start_time, p_duration_s, p_distance_km, p_source_file, p_content_hash, v_geom)
  ON CONFLICT (content_hash) DO UPDATE
    SET start_time  = EXCLUDED.start_time,
        duration_s  = EXCLUDED.duration_s,
        distance_km = EXCLUDED.distance_km,
        source_file = EXCLUDED.source_file
  RETURNING id INTO v_id;

  -- Quick refresh only to keep the ingest path fast
  PERFORM runmap.refresh_quick();
  RETURN v_id;
END;
$$;
