-- Incremental coverage system - processes only new runs, not all runs
-- Uses UTM 32610 for accurate meter-based calculations

-- 1. Streets in UTM with precomputed length
CREATE TABLE IF NOT EXISTS runmap.streets_reference_32610 AS
SELECT
  s.ogc_fid,
  s.osm_id,
  s.name,
  s.highway,
  s.runnable,
  ST_Transform(s.geom, 32610) AS geom_32610,
  ST_Length(ST_Transform(s.geom, 32610))::double precision AS total_length_m
FROM runmap.streets_reference s
WHERE s.runnable = TRUE;

CREATE INDEX IF NOT EXISTS streets_ref_32610_gix ON runmap.streets_reference_32610 USING GIST (geom_32610);

-- 2. Per-run buffer table (no global union needed)
CREATE TABLE IF NOT EXISTS runmap.runs_buffered_32610 (
  run_id bigint PRIMARY KEY,
  geom geometry(MultiPolygon, 32610) NOT NULL
);

CREATE INDEX IF NOT EXISTS runs_buffered_32610_gix ON runmap.runs_buffered_32610 USING GIST (geom);

-- 3. Per-street incremental coverage state
CREATE TABLE IF NOT EXISTS runmap.street_coverage_32610 (
  ogc_fid bigint PRIMARY KEY,
  covered_geom geometry(MultiLineString, 32610),
  covered_length_m double precision NOT NULL DEFAULT 0,
  total_length_m double precision NOT NULL
);

CREATE INDEX IF NOT EXISTS street_cov_32610_cov_gix ON runmap.street_coverage_32610 USING GIST (covered_geom);

-- Seed coverage table
INSERT INTO runmap.street_coverage_32610 (ogc_fid, covered_geom, covered_length_m, total_length_m)
SELECT s.ogc_fid, NULL::geometry(MultiLineString,32610), 0, s.total_length_m
FROM runmap.streets_reference_32610 s
ON CONFLICT (ogc_fid) DO NOTHING;

-- 4. Function to buffer one run (called on each upload)
CREATE OR REPLACE FUNCTION runmap.buffer_one_run(p_run_id bigint) RETURNS void AS $$
DECLARE
  buf_m numeric := (SELECT (value::text)::numeric FROM runmap.settings WHERE key = 'buffer_distance_m');
BEGIN
  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  SELECT
    r.gid AS run_id,
    ST_Subdivide(
      ST_Buffer(
        ST_SimplifyPreserveTopology(
          ST_Transform(r.geom, 32610),
          GREATEST(buf_m/24.0, 0.25)
        ),
        buf_m
      ),
      2048
    )::geometry(MultiPolygon, 32610)
  FROM runmap.runs_raw r
  WHERE r.gid = p_run_id
  ON CONFLICT (run_id) DO UPDATE
  SET geom = EXCLUDED.geom;
END;
$$ LANGUAGE plpgsql;

-- 5. Function to incrementally update coverage for one run
CREATE OR REPLACE FUNCTION runmap.apply_run_to_coverage(p_run_id bigint) RETURNS void AS $$
DECLARE
  bgeom geometry(MultiPolygon,32610);
BEGIN
  -- Get buffered geometry for this run
  SELECT ST_UnaryUnion(geom) INTO bgeom
  FROM runmap.runs_buffered_32610
  WHERE run_id = p_run_id;

  IF bgeom IS NULL THEN
    RAISE EXCEPTION 'No buffered geom for run_id %', p_run_id;
  END IF;

  -- Update only streets that intersect this run's buffer
  WITH cand AS (
    SELECT s.ogc_fid, s.geom_32610 AS street_geom, sc.covered_geom
    FROM runmap.streets_reference_32610 s
    JOIN runmap.street_coverage_32610 sc USING (ogc_fid)
    WHERE ST_Intersects(s.geom_32610, bgeom)
  ),
  newbits AS (
    SELECT
      c.ogc_fid,
      CASE
        WHEN c.covered_geom IS NULL
          THEN ST_Intersection(c.street_geom, bgeom)
        ELSE ST_Difference(ST_Intersection(c.street_geom, bgeom), c.covered_geom)
      END AS new_seg
    FROM cand c
  ),
  cleaned AS (
    SELECT ogc_fid, ST_SnapToGrid(new_seg, 0.05) AS new_seg
    FROM newbits
    WHERE new_seg IS NOT NULL AND NOT ST_IsEmpty(new_seg)
  )
  UPDATE runmap.street_coverage_32610 sc
  SET
    covered_geom = CASE
      WHEN sc.covered_geom IS NULL THEN ST_LineMerge(c.new_seg)
      ELSE ST_UnaryUnion(ST_Collect(sc.covered_geom, c.new_seg))
    END,
    covered_length_m = ST_Length(
      CASE
        WHEN sc.covered_geom IS NULL THEN ST_LineMerge(c.new_seg)
        ELSE ST_UnaryUnion(ST_Collect(sc.covered_geom, c.new_seg))
      END
    )
  FROM cleaned c
  WHERE sc.ogc_fid = c.ogc_fid
    AND NOT ST_IsEmpty(c.new_seg);
END;
$$ LANGUAGE plpgsql;

-- 6. Drop old views and create new lightweight ones
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats CASCADE;
DROP MATERIALIZED VIEW IF EXISTS runmap.streets_unrun CASCADE;
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_buffer CASCADE;
DROP VIEW IF EXISTS runmap.streets_unrun CASCADE;
DROP VIEW IF EXISTS runmap.coverage_buffer CASCADE;

-- Coverage stats (cheap over 1454 rows)
CREATE MATERIALIZED VIEW runmap.coverage_stats AS
SELECT
  1 AS id,
  SUM(covered_length_m) AS covered_m,
  SUM(total_length_m) AS total_m,
  ROUND((SUM(covered_length_m) / NULLIF(SUM(total_length_m),0) * 100)::numeric, 2) AS coverage_pct
FROM runmap.street_coverage_32610;

CREATE UNIQUE INDEX coverage_stats_id_uidx ON runmap.coverage_stats(id);

-- Unrun streets (simple view, no expensive operations)
CREATE VIEW runmap.streets_unrun AS
SELECT
  s.ogc_fid,
  s.osm_id,
  s.name,
  s.highway,
  s.total_length_m AS length_m,
  ST_Transform(s.geom_32610, 4326) AS geom
FROM runmap.streets_reference_32610 s
JOIN runmap.street_coverage_32610 sc USING (ogc_fid)
WHERE sc.covered_length_m = 0;

-- Coverage polygons (for visualization - per-run buffers, overlapping is OK)
CREATE VIEW runmap.coverage_buffer AS
SELECT
  run_id AS gid,
  ST_Transform(geom, 4326)::geometry(MultiPolygon, 4326) AS geom
FROM runmap.runs_buffered_32610;

COMMENT ON VIEW runmap.coverage_buffer IS 'Per-run coverage buffers - overlaps are handled by tiler';
COMMENT ON FUNCTION runmap.buffer_one_run IS 'Buffer a single run and store in runs_buffered_32610';
COMMENT ON FUNCTION runmap.apply_run_to_coverage IS 'Incrementally update coverage for streets touched by one run';
