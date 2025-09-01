-- External buffer table + "current" view and rewiring of dependent matviews
-- This enables building the heavy buffer off-DB and letting Postgres only serve it.

SET statement_timeout = 0;
SET jit = off;
SET work_mem = '256MB';

-- 1) External buffer table (single row, gid=1)
CREATE TABLE IF NOT EXISTS runmap.coverage_buffer_external (
  gid        integer PRIMARY KEY CHECK (gid = 1),
  buffer_m   integer NOT NULL,
  geom       geometry(MultiPolygon,4326) NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS coverage_buffer_external_gix
  ON runmap.coverage_buffer_external USING GIST (geom);

-- 2) Current buffer view: prefer external if present, else fall back to existing coverage_buffer_m
CREATE OR REPLACE VIEW runmap.coverage_buffer_current AS
SELECT
  1 AS gid,
  COALESCE(
    (SELECT buffer_m FROM runmap.coverage_buffer_external WHERE gid = 1),
    (SELECT buffer_m FROM runmap.coverage_buffer_m        WHERE gid = 1)
  ) AS buffer_m,
  COALESCE(
    (SELECT geom FROM runmap.coverage_buffer_external WHERE gid = 1),
    (SELECT geom FROM runmap.coverage_buffer_m        WHERE gid = 1)
  ) AS geom;

-- 3) Recreate dependent matviews to read from coverage_buffer_current
-- streets_unrun
DROP MATERIALIZED VIEW IF EXISTS runmap.streets_unrun;
CREATE MATERIALIZED VIEW runmap.streets_unrun AS
WITH aoi AS (
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
)
SELECT
  row_number() OVER () AS gid,
  s.street_id,
  s.name,
  s.geom
FROM runmap.all_streets_runnable_aoi s
CROSS JOIN bbox
LEFT JOIN runmap.coverage_buffer_current b ON ST_Intersects(s.geom, b.geom)
WHERE bbox.g IS NOT NULL
  AND s.geom && bbox.g
  AND b.geom IS NULL;

CREATE UNIQUE INDEX streets_unrun_gid_uidx ON runmap.streets_unrun (gid);
CREATE INDEX        streets_unrun_gix      ON runmap.streets_unrun USING GIST (geom);

-- coverage_stats (uses improved UTM/geometry approach)
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
          (SELECT ST_Transform(geom, 32610) FROM runmap.coverage_buffer_current),
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

-- 4) Helper: refresh dependent views after an external buffer write
CREATE OR REPLACE FUNCTION runmap.refresh_after_external()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('runmap.refresh_after_external'));
  SET LOCAL statement_timeout = 0;
  SET LOCAL work_mem = '256MB';
  SET LOCAL jit = off;
  SET LOCAL lock_timeout = '5s';

  RAISE NOTICE 'Refreshing streets_unrun (CONCURRENTLY)…';
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.streets_unrun;
    RAISE NOTICE 'streets_unrun done (concurrent).';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'streets_unrun concurrent failed (%). Falling back to non-concurrent…', SQLERRM;
    SET LOCAL lock_timeout = '0';
    REFRESH MATERIALIZED VIEW runmap.streets_unrun;
    RAISE NOTICE 'streets_unrun done (non-concurrent).';
  END;

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

CREATE OR REPLACE FUNCTION public.refresh_after_external()
RETURNS void
LANGUAGE sql
AS $$ SELECT runmap.refresh_after_external(); $$;
GRANT EXECUTE ON FUNCTION public.refresh_after_external() TO anon, authenticated;
