CREATE TEMP TABLE coverage_chunks AS
WITH bounds AS (
  SELECT ST_Extent(geom) as bbox FROM runmap.runs_raw
),
grid AS (
  SELECT
    row_number() OVER () as chunk_id,
    ST_MakeEnvelope(
      ST_XMin(bbox) + (ST_XMax(bbox) - ST_XMin(bbox)) * (n-1) / 4.0,
      ST_YMin(bbox) + (ST_YMax(bbox) - ST_YMin(bbox)) * (m-1) / 4.0,
      ST_XMin(bbox) + (ST_XMax(bbox) - ST_XMin(bbox)) * n / 4.0,
      ST_YMin(bbox) + (ST_YMax(bbox) - ST_YMin(bbox)) * m / 4.0,
      4326
    ) as chunk_geom
  FROM bounds,
       generate_series(1, 4) n,
       generate_series(1, 4) m
)
SELECT chunk_id, chunk_geom FROM grid;

DROP MATERIALIZED VIEW IF EXISTS runmap.streets_unrun CASCADE;
CREATE MATERIALIZED VIEW runmap.streets_unrun AS
SELECT DISTINCT ON (s.ogc_fid)
  s.ogc_fid,
  s.osm_id,
  s.name,
  s.highway,
  ST_Length(s.geom::geography) AS length_m,
  s.geom
FROM runmap.streets_reference s
WHERE s.runnable = TRUE
  AND NOT EXISTS (
    SELECT 1
    FROM runmap.runs_merged r
    WHERE ST_DWithin(
      s.geom::geography,
      r.geom::geography,
      (SELECT (value::text)::numeric FROM runmap.settings WHERE key = 'buffer_distance_m')
    )
  );

CREATE UNIQUE INDEX streets_unrun_ogc_fid_uidx ON runmap.streets_unrun(ogc_fid);
CREATE INDEX streets_unrun_gix ON runmap.streets_unrun USING GIST(geom);

DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats CASCADE;
CREATE MATERIALIZED VIEW runmap.coverage_stats AS
SELECT
  1 AS id,
  COALESCE(SUM(ST_Length(s.geom::geography)), 0) AS covered_m,
  (SELECT SUM(ST_Length(geom::geography)) FROM runmap.streets_reference WHERE runnable = TRUE) AS total_m,
  ROUND((COALESCE(SUM(ST_Length(s.geom::geography)), 0) / (SELECT SUM(ST_Length(geom::geography)) FROM runmap.streets_reference WHERE runnable = TRUE) * 100)::numeric, 2) AS coverage_pct
FROM runmap.streets_reference s
WHERE s.runnable = TRUE
  AND s.ogc_fid NOT IN (SELECT ogc_fid FROM runmap.streets_unrun);

CREATE UNIQUE INDEX coverage_stats_id_uidx ON runmap.coverage_stats(id);
