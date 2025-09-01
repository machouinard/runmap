-- Speed up coverage_stats using geometry in meters + expression GIST index
-- Improve refresh functions with progress NOTICEs and sane lock timeouts

-- 1) Ensure expression GIST index on transformed streets for fast DWithin in meters
CREATE INDEX IF NOT EXISTS all_streets_runnable_aoi_utm_gix
ON runmap.all_streets_runnable_aoi
USING GIST (ST_Transform(geom, 32610));

-- 2) Recreate coverage_stats to use ST_DWithin on geometry(UTM) instead of geography
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats;
CREATE MATERIALIZED VIEW runmap.coverage_stats AS
WITH p AS (
  SELECT buffer_m FROM runmap.settings LIMIT 1
), aoi AS (
  SELECT geom FROM runmap.aoi WHERE id = 1
), rc AS (
  SELECT geom FROM runmap.runs_collect WHERE geom IS NOT NULL
), asn AS (
  SELECT ST_Envelope(ST_Collect(geom)) AS g FROM runmap.all_streets_runnable_aoi
), bbox AS (
  SELECT COALESCE(
           (SELECT geom FROM aoi),
           (SELECT ST_Envelope(geom) FROM rc),
           (SELECT g FROM asn)
         ) AS g
), total AS (
  SELECT SUM(ST_Length(s.geom::geography)) AS total_m
  FROM runmap.all_streets_runnable_aoi s, bbox
  WHERE bbox.g IS NOT NULL
    AND s.geom && bbox.g
), covered_ids AS (
  SELECT DISTINCT s.street_id
  FROM runmap.all_streets_runnable_aoi s
  WHERE ST_DWithin(
          ST_Transform(s.geom, 32610),
          (SELECT ST_Transform(geom, 32610) FROM runmap.coverage_buffer_m),
          (SELECT buffer_m FROM p)::double precision
        )
), covered AS (
  SELECT SUM(ST_Length(s.geom::geography)) AS covered_m
  FROM runmap.all_streets_runnable_aoi s
  JOIN covered_ids c USING (street_id)
)
SELECT
  1 AS gid,
  COALESCE(total_m, 0) AS total_m,
  COALESCE(covered_m, 0) AS covered_m,
  CASE WHEN COALESCE(total_m,0) > 0 THEN (COALESCE(covered_m,0) / COALESCE(total_m,1)) * 100.0 ELSE 0 END AS pct,
  now() AS updated_at
FROM total, covered;

CREATE UNIQUE INDEX coverage_stats_gid_uidx ON runmap.coverage_stats (gid);

-- 3) Refresh functions: add progress NOTICEs + lock_timeout for CONCURRENTLY, fallback to non-concurrent
CREATE OR REPLACE FUNCTION runmap.refresh_quick()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_quick'));

  -- runs_collect
  RAISE NOTICE 'Refreshing runs_collect (CONCURRENTLY)…';
  SET LOCAL statement_timeout = 0;
  SET LOCAL lock_timeout = '5s';
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
  SET LOCAL statement_timeout = 0;
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

  -- 1) runs_collect
  RAISE NOTICE 'Refreshing runs_collect (CONCURRENTLY)…';
  SET LOCAL statement_timeout = 0;
  SET LOCAL lock_timeout = '5s';
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
  SET LOCAL statement_timeout = 0;
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
  SET LOCAL statement_timeout = 0;
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
  SET LOCAL statement_timeout = 0;
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
