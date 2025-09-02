-- Rebuild streets_unrun and coverage_stats from runmap.all_streets with a clear whitelist
-- Fixes "white" streets that were excluded from the candidate network

SET statement_timeout = 0;
SET jit = off;
SET work_mem = '256MB';

-- Ensure spatial index on the baseline streets table
CREATE INDEX IF NOT EXISTS all_streets_gix ON runmap.all_streets USING GIST (geom);

-- Helper CTE used by both views: whitelist + dump to pure LineString
-- Includes: residential, living_street, unclassified, tertiary(+_link), secondary(+_link), primary(+_link), and service=alley
-- Excludes driveways and other service types
-- Adjust here if you want to include/exclude more classes

DROP MATERIALIZED VIEW IF EXISTS runmap.streets_unrun;
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats;

CREATE MATERIALIZED VIEW runmap.streets_unrun AS
WITH aoi AS (
  SELECT geom FROM runmap.aoi WHERE id = 1
), rc AS (
  SELECT geom FROM runmap.runs_collect WHERE geom IS NOT NULL
), asn AS (
  SELECT ST_Envelope(ST_Collect(geom)) AS g FROM runmap.all_streets
), bbox AS (
  SELECT COALESCE(
           (SELECT geom FROM aoi),
           (SELECT ST_Envelope(geom) FROM rc),
           (SELECT g FROM asn)
         ) AS g
), base_streets AS (
  SELECT
    (ST_Dump(ST_CollectionExtract(s.geom, 2))).geom AS geom,
    s.name,
    s.highway,
    COALESCE(s.service, '') AS service
  FROM runmap.all_streets s, bbox
  WHERE s.geom && bbox.g
    AND (
      s.highway IN ('residential','living_street','unclassified',
                     'tertiary','tertiary_link','secondary','secondary_link','primary','primary_link')
      OR (s.highway = 'service' AND COALESCE(s.service,'') = 'alley')
    )
)
SELECT
  row_number() OVER () AS gid,
  NULLIF(TRIM(name), '') AS name,
  s.geom AS geom
FROM base_streets s
LEFT JOIN runmap.coverage_buffer_current b ON ST_Intersects(s.geom, b.geom)
WHERE b.geom IS NULL;

CREATE UNIQUE INDEX streets_unrun_gid_uidx ON runmap.streets_unrun (gid);
CREATE INDEX        streets_unrun_gix      ON runmap.streets_unrun USING GIST (geom);

-- coverage_stats aligned to the same base set
CREATE MATERIALIZED VIEW runmap.coverage_stats AS
WITH p AS (
  SELECT buffer_m FROM runmap.settings LIMIT 1
), aoi AS (
  SELECT geom FROM runmap.aoi WHERE id = 1
), rc AS (
  SELECT geom FROM runmap.runs_collect WHERE geom IS NOT NULL
), asn AS (
  SELECT ST_Envelope(ST_Collect(geom)) AS g FROM runmap.all_streets
), bbox AS (
  SELECT COALESCE(
           (SELECT geom FROM aoi),
           (SELECT ST_Envelope(geom) FROM rc),
           (SELECT g FROM asn)
         ) AS g
), base_streets AS (
  SELECT
    (ST_Dump(ST_CollectionExtract(s.geom, 2))).geom AS geom,
    s.highway,
    COALESCE(s.service, '') AS service
  FROM runmap.all_streets s, bbox
  WHERE s.geom && bbox.g
    AND (
      s.highway IN ('residential','living_street','unclassified',
                     'tertiary','tertiary_link','secondary','secondary_link','primary','primary_link')
      OR (s.highway = 'service' AND COALESCE(s.service,'') = 'alley')
    )
), total AS (
  SELECT SUM(ST_Length(s.geom::geography)) AS total_m
  FROM base_streets s
), covered_ids AS (
  SELECT DISTINCT s.geom
  FROM base_streets s
  WHERE ST_DWithin(
          ST_Transform(s.geom, 32610),
          (SELECT ST_Transform(geom, 32610) FROM runmap.coverage_buffer_current),
          (SELECT buffer_m FROM p)::double precision
        )
), covered AS (
  SELECT SUM(ST_Length(s.geom::geography)) AS covered_m
  FROM base_streets s
  JOIN covered_ids c ON ST_Equals(s.geom, c.geom)
)
SELECT
  1 AS gid,
  COALESCE(total_m, 0) AS total_m,
  COALESCE(covered_m, 0) AS covered_m,
  CASE WHEN COALESCE(total_m,0) > 0 THEN (COALESCE(covered_m,0) / COALESCE(total_m,1)) * 100.0 ELSE 0 END AS pct,
  now() AS updated_at
FROM total, covered;

CREATE UNIQUE INDEX coverage_stats_gid_uidx ON runmap.coverage_stats (gid);
