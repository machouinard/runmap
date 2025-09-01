-- Pipeline function + RPC insert + basic policies

-- Rebuilds all derived objects in order
CREATE OR REPLACE FUNCTION runmap.refresh_pipeline()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW runmap.runs_collect;
  REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
  REFRESH MATERIALIZED VIEW runmap.streets_unrun;
  REFRESH MATERIALIZED VIEW runmap.coverage_stats;
END;
$$;

-- RPC: insert a run from WKT MultiLineString and refresh
CREATE OR REPLACE FUNCTION runmap.insert_run_from_wkt(
  wkt          text,
  start_time   timestamptz,
  duration_s   integer,
  distance_km  numeric,
  source_file  text,
  content_hash text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER -- allow calling via anon/auth but run as owner
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO runmap.runs_raw (start_time, duration_s, distance_km, source_file, content_hash, geom)
  VALUES (start_time, duration_s, distance_km, source_file, content_hash, ST_SetSRID(ST_GeomFromText(wkt),4326))
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

-- Public stats RPC (read-only for web)
CREATE OR REPLACE FUNCTION runmap.get_public_stats()
RETURNS TABLE(total_m double precision, covered_m double precision, pct double precision, updated_at timestamptz)
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT total_m, covered_m, pct, updated_at FROM runmap.coverage_stats;
$$;

-- Basic RLS: lock write tables; allow only service_role to write; allow read of stats to anon/auth
DO $$ BEGIN
  -- runs_raw
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='runmap' AND tablename='runs_raw'
  ) THEN
    CREATE POLICY runs_raw_service_all ON runmap.runs_raw FOR ALL TO service_role USING (true) WITH CHECK (true);
    CREATE POLICY runs_raw_no_read     ON runmap.runs_raw FOR SELECT TO anon, authenticated USING (false);
  END IF;

  -- all_streets_runnable_aoi
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='runmap' AND tablename='all_streets_runnable_aoi'
  ) THEN
    CREATE POLICY streets_read_all ON runmap.all_streets_runnable_aoi FOR SELECT TO service_role, authenticated USING (true);
    CREATE POLICY streets_write    ON runmap.all_streets_runnable_aoi FOR ALL    TO service_role USING (true) WITH CHECK (true);
  END IF;

  -- settings
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='runmap' AND tablename='settings'
  ) THEN
    CREATE POLICY settings_read ON runmap.settings FOR SELECT TO service_role, authenticated USING (true);
    CREATE POLICY settings_write ON runmap.settings FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

-- Grant read of stats to anon/auth (matview)
GRANT SELECT ON runmap.coverage_stats TO anon, authenticated;
