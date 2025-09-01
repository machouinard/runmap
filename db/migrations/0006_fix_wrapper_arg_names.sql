-- Recreate wrapper with argument names matching JSON keys from supabase-js
DROP FUNCTION IF EXISTS public.insert_run_from_wkt(text, timestamptz, integer, numeric, text, text);

CREATE OR REPLACE FUNCTION public.insert_run_from_wkt(
  content_hash text,
  distance_km  numeric,
  duration_s   integer,
  source_file  text,
  start_time   timestamptz,
  wkt          text
) RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT runmap.insert_run_from_wkt(wkt, start_time, duration_s, distance_km, source_file, content_hash);
$$;

GRANT EXECUTE ON FUNCTION public.insert_run_from_wkt(text, numeric, integer, text, timestamptz, text) TO anon, authenticated;

-- Ask PostgREST to reload schema cache
DO $$ BEGIN PERFORM pg_notify('pgrst', 'reload schema'); END $$;
