-- Fast buffer path that bypasses runs_collect for quick refreshes
-- Builds coverage_buffer_m_fast directly from runs_raw with aggressive simplify

DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_buffer_m_fast;
CREATE MATERIALIZED VIEW runmap.coverage_buffer_m_fast AS
WITH p AS (
  SELECT buffer_m FROM runmap.settings LIMIT 1
), raw AS (
  SELECT ST_Transform(geom, 32610) AS g
  FROM runmap.runs_raw
  WHERE geom IS NOT NULL
), simp AS (
  SELECT ST_SimplifyPreserveTopology(g, 5.0) AS g FROM raw
), unioned AS (
  SELECT ST_UnaryUnion(ST_Collect(g)) AS g FROM simp
)
SELECT
  1 AS gid,
  (SELECT buffer_m FROM p) AS buffer_m,
  ST_Multi(ST_Transform(g, 4326))::geometry(MultiPolygon,4326) AS geom
FROM unioned;

CREATE UNIQUE INDEX coverage_buffer_fast_gid_uidx ON runmap.coverage_buffer_m_fast (gid);
CREATE INDEX        coverage_buffer_fast_gix      ON runmap.coverage_buffer_m_fast USING GIST (geom);

-- New ultra-fast quick refresh that only refreshes the fast buffer
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

-- Optional: public wrapper
CREATE OR REPLACE FUNCTION public.refresh_quick_fast()
RETURNS void
LANGUAGE sql
AS $$ SELECT runmap.refresh_quick_fast(); $$;
GRANT EXECUTE ON FUNCTION public.refresh_quick_fast() TO anon, authenticated;
