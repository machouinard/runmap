-- Expose RPCs via the public schema (PostgREST exposes public by default)

-- Wrapper for runmap.insert_run_from_wkt so supabase.rpc("insert_run_from_wkt") works
CREATE OR REPLACE FUNCTION public.insert_run_from_wkt(
  wkt          text,
  start_time   timestamptz,
  duration_s   integer,
  distance_km  numeric,
  source_file  text,
  content_hash text
) RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT runmap.insert_run_from_wkt(wkt, start_time, duration_s, distance_km, source_file, content_hash);
$$;

-- Public stats wrapper (optional convenience for web)
CREATE OR REPLACE FUNCTION public.get_public_stats()
RETURNS TABLE(total_m double precision, covered_m double precision, pct double precision, updated_at timestamptz)
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT total_m, covered_m, pct, updated_at FROM runmap.coverage_stats;
$$;

GRANT EXECUTE ON FUNCTION public.insert_run_from_wkt(text, timestamptz, integer, numeric, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_public_stats() TO anon, authenticated;
