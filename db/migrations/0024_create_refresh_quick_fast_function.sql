-- Create the refresh_quick_fast function and public wrapper (without redefining the matview)

CREATE OR REPLACE FUNCTION runmap.refresh_quick_fast()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_quick_fast'));
  SET LOCAL statement_timeout = 0;
  SET LOCAL work_mem = '256MB';
  SET LOCAL jit = off;
  SET LOCAL lock_timeout = '5s';

  RAISE NOTICE 'Refreshing coverage_buffer_m_fast (CONCURRENTLY)…';
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_buffer_m_fast;
    RAISE NOTICE 'coverage_buffer_m_fast done (concurrent).';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'coverage_buffer_m_fast concurrent failed (%). Falling back to non-concurrent…', SQLERRM;
    SET LOCAL lock_timeout = '0';
    REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m_fast;
    RAISE NOTICE 'coverage_buffer_m_fast done (non-concurrent).';
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_quick_fast()
RETURNS void
LANGUAGE sql
AS $$ SELECT runmap.refresh_quick_fast(); $$;

GRANT EXECUTE ON FUNCTION public.refresh_quick_fast() TO anon, authenticated;
