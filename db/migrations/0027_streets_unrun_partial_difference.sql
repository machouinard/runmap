-- streets_unrun should show the portions of streets that remain outside coverage
-- Previous query excluded an entire street if any part intersected the buffer, causing "white" partially-run segments
-- This rebuilds streets_unrun using ST_Difference to keep only the uncovered parts (and fully uncovered streets)

SET statement_timeout = 0;
SET jit = off;
SET work_mem = '256MB';

DROP MATERIALIZED VIEW IF EXISTS runmap.streets_unrun;

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
    NULLIF(TRIM(s.name), '') AS name,
    s.highway,
    COALESCE(s.service, '') AS service
  FROM runmap.all_streets s, bbox
  WHERE s.geom && bbox.g
    AND (
      s.highway IN ('residential','living_street','unclassified',
                     'tertiary','tertiary_link','secondary','secondary_link','primary','primary_link')
      OR (s.highway = 'service' AND COALESCE(s.service,'') = 'alley')
    )
), diff AS (
  -- Keep only the parts outside coverage; if no intersection, the geometry is kept as-is
  SELECT
    bs.name,
    CASE
      WHEN b.geom IS NULL THEN bs.geom
      ELSE ST_Difference(bs.geom, b.geom)
    END AS geom
  FROM base_streets bs
  LEFT JOIN runmap.coverage_buffer_current b
    ON ST_Intersects(bs.geom, b.geom)
)
SELECT
  row_number() OVER () AS gid,
  name,
  (ST_Dump(geom)).geom AS geom
FROM diff
WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom);

CREATE UNIQUE INDEX streets_unrun_gid_uidx ON runmap.streets_unrun (gid);
CREATE INDEX        streets_unrun_gix      ON runmap.streets_unrun USING GIST (geom);
