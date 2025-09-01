-- Make refresh functions resilient: PL/pgSQL, advisory lock, SET LOCAL statement_timeout=0, use CONCURRENTLY with fallback

-- Quick refresh (lightweight)
CREATE OR REPLACE FUNCTION runmap.refresh_quick()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  _msg TEXT := '';
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_quick'));

  -- runs_collect
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.runs_collect;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.runs_collect;
  END;
  _msg := _msg || 'runs_collect refreshed; ';

  -- coverage_buffer_m
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_buffer_m;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
  END;
  _msg := _msg || 'coverage_buffer_m refreshed.';

  RETURN _msg;
END;
$$;

-- Full refresh (heavy)
CREATE OR REPLACE FUNCTION runmap.refresh_all()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  _msg TEXT := '';
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_all'));

  -- 1) runs_collect
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.runs_collect;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.runs_collect;
  END;
  _msg := _msg || 'runs_collect refreshed; ';

  -- 2) coverage_buffer_m
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_buffer_m;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
  END;
  _msg := _msg || 'coverage_buffer_m refreshed; ';

  -- 3) streets_unrun
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.streets_unrun;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.streets_unrun;
  END;
  _msg := _msg || 'streets_unrun refreshed; ';

  -- 4) coverage_stats
  SET LOCAL statement_timeout = 0;
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_stats;
  EXCEPTION WHEN OTHERS THEN
    REFRESH MATERIALIZED VIEW runmap.coverage_stats;
  END;
  _msg := _msg || 'coverage_stats refreshed.';

  RETURN _msg;
END;
$$;
