-- Merged runs (union all tracks)
CREATE MATERIALIZED VIEW IF NOT EXISTS runmap.runs_merged AS
SELECT
  1 AS gid,
  ST_Union(geom)::geometry(MultiLineString, 4326) AS geom
FROM runmap.runs_raw;

CREATE UNIQUE INDEX runs_merged_gid_uidx ON runmap.runs_merged(gid);
CREATE INDEX runs_merged_gix ON runmap.runs_merged USING GIST(geom);

-- Coverage buffer (20m buffer in UTM) - simplified for performance
CREATE MATERIALIZED VIEW IF NOT EXISTS runmap.coverage_buffer AS
SELECT
  1 AS gid,
  ST_Transform(
    ST_Buffer(
      ST_Transform(geom, 32610),
      (SELECT (value::text)::numeric FROM runmap.settings WHERE key = 'buffer_distance_m')
    ),
    4326
  )::geometry(Polygon, 4326) AS geom
FROM runmap.runs_merged;

CREATE UNIQUE INDEX coverage_buffer_gid_uidx ON runmap.coverage_buffer(gid);
CREATE INDEX coverage_buffer_gix ON runmap.coverage_buffer USING GIST(geom);

-- Uncovered streets (using ST_DWithin for accuracy)
CREATE MATERIALIZED VIEW IF NOT EXISTS runmap.streets_unrun AS
SELECT
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

-- Coverage stats (overall coverage)
CREATE MATERIALIZED VIEW IF NOT EXISTS runmap.coverage_stats AS
WITH covered AS (
  SELECT 
    s.ogc_fid,
    ST_Length(ST_Intersection(s.geom, cb.geom)::geography) AS covered_length_m
  FROM runmap.streets_reference s
  CROSS JOIN runmap.coverage_buffer cb
  WHERE s.runnable = TRUE
    AND ST_Intersects(s.geom, cb.geom)
)
SELECT
  1 AS id,
  COALESCE(SUM(c.covered_length_m), 0) AS covered_m,
  (SELECT SUM(ST_Length(geom::geography)) FROM runmap.streets_reference WHERE runnable = TRUE) AS total_m,
  ROUND((COALESCE(SUM(c.covered_length_m), 0) / (SELECT SUM(ST_Length(geom::geography)) FROM runmap.streets_reference WHERE runnable = TRUE) * 100)::numeric, 2) AS coverage_pct
FROM covered c;

CREATE UNIQUE INDEX coverage_stats_id_uidx ON runmap.coverage_stats(id);