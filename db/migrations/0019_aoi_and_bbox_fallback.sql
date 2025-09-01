-- Set default AOI and make streets_unrun robust to missing runs by using a bbox fallback

-- 1) Upsert AOI polygon (America/Los_Angeles, EPSG:4326)
-- Provided by user
INSERT INTO runmap.aoi (id, geom)
VALUES (
  1,
  ST_GeomFromText(
    'POLYGON((-121.50520222701810269 38.60082389590029806,
              -121.42010546438312701 38.59368118644613332,
              -121.4186276624270846 38.55181013102515664,
              -121.47306003447435785 38.54651467401603782,
              -121.50840413125618511 38.5441748209189825,
              -121.51456163940632393 38.56350939651043319,
              -121.51616259152535804 38.58111986981984387,
              -121.50520222701810269 38.60082389590029806))',
    4326
  )
)
ON CONFLICT (id) DO UPDATE SET geom = EXCLUDED.geom;

-- 2) Recreate streets_unrun with bbox fallback:
--    bbox := COALESCE(AOI,
--                    envelope(runs_collect) if not NULL,
--                    envelope(all_streets_runnable_aoi))
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
LEFT JOIN runmap.coverage_buffer_m b ON ST_Intersects(s.geom, b.geom)
WHERE bbox.g IS NOT NULL
  AND s.geom && bbox.g
  AND b.geom IS NULL;

CREATE UNIQUE INDEX streets_unrun_gid_uidx ON runmap.streets_unrun (gid);
CREATE INDEX        streets_unrun_gix      ON runmap.streets_unrun USING GIST (geom);
