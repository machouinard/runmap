-- Fix fast buffer: aggregate all rows before union to produce a single row (gid=1)
SET statement_timeout = 0;
SET jit = off;
SET work_mem = '256MB';

DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_buffer_m_fast;
CREATE MATERIALIZED VIEW runmap.coverage_buffer_m_fast
AS
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
FROM unioned
WITH NO DATA;

CREATE UNIQUE INDEX coverage_buffer_fast_gid_uidx ON runmap.coverage_buffer_m_fast (gid);
CREATE INDEX        coverage_buffer_fast_gix      ON runmap.coverage_buffer_m_fast USING GIST (geom);
