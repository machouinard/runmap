-- Tuning: increase work_mem and disable JIT in refresh sessions to speed geospatial unions
-- Safe session-local settings; no persistent parameter changes required

CREATE OR REPLACE FUNCTION runmap.refresh_quick()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_quick'));
  -- Session-local tuning
  SET LOCAL statement_timeout = 0;
  SET LOCAL lock_timeout = '5s';
  SET LOCAL work_mem = '256MB';
  SET LOCAL jit = off;

  -- runs_collect
  RAISE NOTICE 'Refreshing runs_collect (CONCURRENTLY)…';
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.runs_collect;
    RAISE NOTICE 'runs_collect done (concurrent).';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'runs_collect concurrent failed (%). Falling back to non-concurrent…', SQLERRM;
    SET LOCAL lock_timeout = '0';
    REFRESH MATERIALIZED VIEW runmap.runs_collect;
    RAISE NOTICE 'runs_collect done (non-concurrent).';
  END;

  -- coverage_buffer_m
  RAISE NOTICE 'Refreshing coverage_buffer_m (CONCURRENTLY)…';
  SET LOCAL lock_timeout = '5s';
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_buffer_m;
    RAISE NOTICE 'coverage_buffer_m done (concurrent).';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'coverage_buffer_m concurrent failed (%). Falling back to non-concurrent…', SQLERRM;
    SET LOCAL lock_timeout = '0';
    REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
    RAISE NOTICE 'coverage_buffer_m done (non-concurrent).';
  END;
END;
$$;

CREATE OR REPLACE FUNCTION runmap.refresh_all()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_all'));
  -- Session-local tuning
  SET LOCAL statement_timeout = 0;
  SET LOCAL lock_timeout = '5s';
  SET LOCAL work_mem = '256MB';
  SET LOCAL jit = off;

  -- 1) runs_collect
  RAISE NOTICE 'Refreshing runs_collect (CONCURRENTLY)…';
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.runs_collect;
    RAISE NOTICE 'runs_collect done (concurrent).';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'runs_collect concurrent failed (%). Falling back to non-concurrent…', SQLERRM;
    SET LOCAL lock_timeout = '0';
    REFRESH MATERIALIZED VIEW runmap.runs_collect;
    RAISE NOTICE 'runs_collect done (non-concurrent).';
  END;

  -- 2) coverage_buffer_m
  RAISE NOTICE 'Refreshing coverage_buffer_m (CONCURRENTLY)…';
  SET LOCAL lock_timeout = '5s';
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_buffer_m;
    RAISE NOTICE 'coverage_buffer_m done (concurrent).';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'coverage_buffer_m concurrent failed (%). Falling back to non-concurrent…', SQLERRM;
    SET LOCAL lock_timeout = '0';
    REFRESH MATERIALIZED VIEW runmap.coverage_buffer_m;
    RAISE NOTICE 'coverage_buffer_m done (non-concurrent).';
  END;

  -- 3) streets_unrun
  RAISE NOTICE 'Refreshing streets_unrun (CONCURRENTLY)…';
  SET LOCAL lock_timeout = '5s';
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.streets_unrun;
    RAISE NOTICE 'streets_unrun done (concurrent).';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'streets_unrun concurrent failed (%). Falling back to non-concurrent…', SQLERRM;
    SET LOCAL lock_timeout = '0';
    REFRESH MATERIALIZED VIEW runmap.streets_unrun;
    RAISE NOTICE 'streets_unrun done (non-concurrent).';
  END;

  -- 4) coverage_stats
  RAISE NOTICE 'Refreshing coverage_stats (CONCURRENTLY)…';
  SET LOCAL lock_timeout = '5s';
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_stats;
    RAISE NOTICE 'coverage_stats done (concurrent).';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'coverage_stats concurrent failed (%). Falling back to non-concurrent…', SQLERRM;
    SET LOCAL lock_timeout = '0';
    REFRESH MATERIALIZED VIEW runmap.coverage_stats;
    RAISE NOTICE 'coverage_stats done (non-concurrent).';
  END;
END;
$$;
