-- Expose refresh RPCs via public schema for PostgREST

CREATE OR REPLACE FUNCTION public.refresh_quick()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT runmap.refresh_quick();
$$;
GRANT EXECUTE ON FUNCTION public.refresh_quick() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_all()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT runmap.refresh_all();
$$;
GRANT EXECUTE ON FUNCTION public.refresh_all() TO anon, authenticated;
