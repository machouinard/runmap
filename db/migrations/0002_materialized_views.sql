-- Derived layers and stats

-- 1) All runs collected as one geometry (always 1 row)
DROP MATERIALIZED VIEW IF EXISTS runmap.runs_collect;
CREATE MATERIALIZED VIEW runmap.runs_collect AS
SELECT
  1 AS gid,
  ST_Multi(ST_Force2D(ST_Collect(geom)))::geometry(MultiLineString,4326) AS geom
FROM runmap.runs_raw
WHERE geom IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS runs_collect_gid_uidx ON runmap.runs_collect (gid);
CREATE INDEX        IF NOT EXISTS runs_collect_gix      ON runmap.runs_collect USING GIST (geom);

-- 2) Buffered footprint in meters (uses settings.buffer_m)
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_buffer_m;
CREATE MATERIALIZED VIEW runmap.coverage_buffer_m AS
WITH p AS (
  SELECT buffer_m FROM runmap.settings LIMIT 1
), g AS (
  SELECT ST_SimplifyPreserveTopology(
           ST_Transform(geom, 32610), -- meters
           2.0                         -- ~2 m simplify
         ) AS g
  FROM runmap.runs_collect
)
SELECT
  1 AS gid,
  (SELECT buffer_m FROM p) AS buffer_m,
  ST_Transform(ST_Buffer(g, (SELECT buffer_m FROM p)::double precision), 4326)::geometry(Polygon,4326) AS geom
FROM g;

CREATE UNIQUE INDEX IF NOT EXISTS coverage_buffer_gid_uidx ON runmap.coverage_buffer_m (gid);
CREATE INDEX        IF NOT EXISTS coverage_buffer_gix      ON runmap.coverage_buffer_m USING GIST (geom);

-- 3) Streets not yet covered (prefer buffer/intersects for daily "to-do" speed)
DROP MATERIALIZED VIEW IF EXISTS runmap.streets_unrun;
CREATE MATERIALIZED VIEW runmap.streets_unrun AS
WITH bbox AS (
  SELECT COALESCE(
           (SELECT geom FROM runmap.aoi WHERE id = 1),
           ST_Expand(ST_Envelope((SELECT geom FROM runmap.runs_collect)), 0.01) -- ~1.1 km pad
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

CREATE UNIQUE INDEX IF NOT EXISTS streets_unrun_gid_uidx ON runmap.streets_unrun (gid);
CREATE INDEX        IF NOT EXISTS streets_unrun_gix      ON runmap.streets_unrun USING GIST (geom);

-- 4) Coverage stats (dedup per street via ST_DWithin)
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats;
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

CREATE UNIQUE INDEX IF NOT EXISTS coverage_stats_gid_uidx ON runmap.coverage_stats (gid);
