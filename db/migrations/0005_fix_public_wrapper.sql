-- Fix wrapper to avoid ambiguous identifier names by using positional params
DROP FUNCTION IF EXISTS public.insert_run_from_wkt(text, timestamptz, integer, numeric, text, text);

CREATE OR REPLACE FUNCTION public.insert_run_from_wkt(
  p_wkt          text,
  p_start_time   timestamptz,
  p_duration_s   integer,
  p_distance_km  numeric,
  p_source_file  text,
  p_content_hash text
) RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT runmap.insert_run_from_wkt($1, $2, $3, $4, $5, $6);
$$;

GRANT EXECUTE ON FUNCTION public.insert_run_from_wkt(text, timestamptz, integer, numeric, text, text) TO anon, authenticated;
