-- Rebuild derived matviews using robust line normalization to avoid GeometryCollection casts

-- Drop in dependency order
DROP MATERIALIZED VIEW IF EXISTS runmap.streets_unrun;
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats;
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_buffer_m;
DROP MATERIALIZED VIEW IF EXISTS runmap.runs_collect;

-- Robust runs_collect: always MultiLineString(4326)
CREATE MATERIALIZED VIEW runmap.runs_collect AS
WITH collected AS (
  SELECT ST_Collect(geom) AS g
  FROM runmap.runs_raw
  WHERE geom IS NOT NULL
), only_lines AS (
  SELECT ST_CollectionExtract(g, 2) AS g
  FROM collected
), unified AS (
  SELECT ST_UnaryUnion(g) AS g
  FROM only_lines
), merged AS (
  SELECT ST_LineMerge(g) AS g
  FROM unified
)
SELECT
  1 AS gid,
  ST_Multi(g)::geometry(MultiLineString,4326) AS geom
FROM merged;

CREATE UNIQUE INDEX runs_collect_gid_uidx ON runmap.runs_collect (gid);
CREATE INDEX        runs_collect_gix      ON runmap.runs_collect USING GIST (geom);

-- coverage_buffer_m (unchanged logic, now fed by robust runs_collect)
CREATE MATERIALIZED VIEW runmap.coverage_buffer_m AS
WITH p AS (
  SELECT buffer_m FROM runmap.settings LIMIT 1
), g AS (
  SELECT ST_SimplifyPreserveTopology(
           ST_Transform(geom, 32610),
           2.0
         ) AS g
  FROM runmap.runs_collect
)
SELECT
  1 AS gid,
  (SELECT buffer_m FROM p) AS buffer_m,
  ST_Transform(ST_Buffer(g, (SELECT buffer_m FROM p)::double precision), 4326)::geometry(Polygon,4326) AS geom
FROM g;

CREATE UNIQUE INDEX coverage_buffer_gid_uidx ON runmap.coverage_buffer_m (gid);
CREATE INDEX        coverage_buffer_gix      ON runmap.coverage_buffer_m USING GIST (geom);

-- streets_unrun (same semantics)
CREATE MATERIALIZED VIEW runmap.streets_unrun AS
WITH bbox AS (
  SELECT COALESCE(
           (SELECT geom FROM runmap.aoi WHERE id = 1),
           ST_Expand(ST_Envelope((SELECT geom FROM runmap.runs_collect)), 0.01)
         ) AS g
)
SELECT
  row_number() OVER () AS gid,
  s.street_id,
  s.name,
  s.geom
FROM runmap.all_streets_runnable_aoi s
CROSS JOIN bbox
LEFT JOIN runmap.coverage_buffer_m b ON ST_Intersects(s.geom, b.geom)
WHERE s.geom && bbox.g
  AND b.geom IS NULL;

CREATE UNIQUE INDEX streets_unrun_gid_uidx ON runmap.streets_unrun (gid);
CREATE INDEX        streets_unrun_gix      ON runmap.streets_unrun USING GIST (geom);

-- coverage_stats (same as 0002)
CREATE MATERIALIZED VIEW runmap.coverage_stats AS
WITH p AS (
  SELECT buffer_m FROM runmap.settings LIMIT 1
), bbox AS (
  SELECT COALESCE(
           (SELECT geom FROM runmap.aoi WHERE id = 1),
           ST_Expand(ST_Envelope((SELECT geom FROM runmap.runs_collect)), 0.01)
         ) AS g
), total AS (
  SELECT SUM(ST_Length(s.geom::geography)) AS total_m
  FROM runmap.all_streets_runnable_aoi s, bbox
  WHERE s.geom && bbox.g
), covered_ids AS (
  SELECT DISTINCT s.street_id
  FROM runmap.all_streets_runnable_aoi s
  WHERE ST_DWithin(
          s.geom::geography,
          (SELECT geom FROM runmap.coverage_buffer_m)::geography,
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
