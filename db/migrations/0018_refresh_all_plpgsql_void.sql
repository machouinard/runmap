-- Recreate refresh functions with PL/pgSQL while preserving original VOID signatures
-- Adds advisory locks, SET LOCAL statement_timeout=0, and CONCURRENTLY with fallback

-- Quick refresh (lightweight)
CREATE OR REPLACE FUNCTION runmap.refresh_quick()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_quick'));

  -- runs_collect
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.runs_collect;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.runs_collect;
  END;

  -- coverage_buffer_m
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_buffer_m;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
  END;
END;
$$;

-- Full refresh (heavy)
CREATE OR REPLACE FUNCTION runmap.refresh_all()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_all'));

  -- 1) runs_collect
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.runs_collect;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.runs_collect;
  END;

  -- 2) coverage_buffer_m
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_buffer_m;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
  END;

  -- 3) streets_unrun
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.streets_unrun;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.streets_unrun;
  END;

  -- 4) coverage_stats
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_stats;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.coverage_stats;
  END;
END;
$$;
