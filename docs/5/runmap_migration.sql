-- runmap_migration.sql
-- Apply to your sandbox database. Safe to re-run.
BEGIN;

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA IF NOT EXISTS runmap;
CREATE SCHEMA IF NOT EXISTS staging;

-- Core tables
CREATE TABLE IF NOT EXISTS runmap.runs (
  run_id       BIGSERIAL PRIMARY KEY,
  started_at   TIMESTAMPTZ,
  ended_at     TIMESTAMPTZ,
  geom_wgs84   geometry(MultiLineString, 4326) NOT NULL
);

CREATE TABLE IF NOT EXISTS runmap.run_buffers (
  run_id     BIGINT PRIMARY KEY REFERENCES runmap.runs(run_id) ON DELETE CASCADE,
  geom_utm   geometry(MultiPolygon, 32610) NOT NULL,
  bbox_utm   geometry(Polygon, 32610) GENERATED ALWAYS AS (ST_Envelope(geom_utm)) STORED
);

-- Subdivided tiles (one-to-many per run)
CREATE TABLE IF NOT EXISTS runmap.run_buffers_subdiv (
  run_id   BIGINT NOT NULL REFERENCES runmap.runs(run_id) ON DELETE CASCADE,
  geom_utm geometry(Polygon, 32610) NOT NULL
);
CREATE INDEX IF NOT EXISTS run_buffers_subdiv_gix ON runmap.run_buffers_subdiv USING gist (geom_utm);

CREATE TABLE IF NOT EXISTS runmap.blocks (
  block_id   BIGSERIAL PRIMARY KEY,
  geom_utm   geometry(LineString, 32610) NOT NULL,
  len_m      DOUBLE PRECISION GENERATED ALWAYS AS (ST_Length(geom_utm)) STORED
);

CREATE TABLE IF NOT EXISTS runmap.block_coverage_runs (
  run_id     BIGINT NOT NULL REFERENCES runmap.runs(run_id) ON DELETE CASCADE,
  block_id   BIGINT NOT NULL REFERENCES runmap.blocks(block_id) ON DELETE CASCADE,
  len_hit_m  DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (run_id, block_id)
);

CREATE TABLE IF NOT EXISTS runmap.block_coverage (
  block_id   BIGINT PRIMARY KEY REFERENCES runmap.blocks(block_id) ON DELETE CASCADE,
  len_hit_m  DOUBLE PRECISION NOT NULL DEFAULT 0,
  pct        DOUBLE PRECISION GENERATED ALWAYS AS (
               CASE WHEN len_m > 0 THEN 100.0 * len_hit_m / len_m ELSE 0 END
             ) STORED
);

-- Indices
CREATE INDEX IF NOT EXISTS run_buffers_geom_gix ON runmap.run_buffers USING gist (geom_utm);
CREATE INDEX IF NOT EXISTS run_buffers_bbox_gix ON runmap.run_buffers USING gist (bbox_utm);
CREATE INDEX IF NOT EXISTS blocks_geom_gix       ON runmap.blocks      USING gist (geom_utm);
CREATE INDEX IF NOT EXISTS bcr_run_idx           ON runmap.block_coverage_runs (run_id);
CREATE INDEX IF NOT EXISTS bcr_block_idx         ON runmap.block_coverage_runs (block_id);
CREATE INDEX IF NOT EXISTS runs_started_idx      ON runmap.runs (started_at);

-- Tuning log
CREATE TABLE IF NOT EXISTS runmap.tuning_log (
  logged_at   TIMESTAMPTZ DEFAULT now(),
  action      TEXT,
  run_count   INT,
  seconds     NUMERIC,
  notes       TEXT
);

-- Optional MV for dashboards
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_matviews WHERE schemaname = 'runmap' AND matviewname = 'coverage_stats_mv'
  ) THEN
    EXECUTE $$
      CREATE MATERIALIZED VIEW runmap.coverage_stats_mv AS
      SELECT
        COUNT(*) AS blocks_total,
        COUNT(*) FILTER (WHERE pct >= 100) AS blocks_complete,
        AVG(pct) AS avg_pct
      FROM runmap.block_coverage
      WITH NO DATA
    $$;
  END IF;
END$$;

-- Functions
CREATE OR REPLACE FUNCTION runmap.ensure_run_buffer(p_run_id BIGINT, p_radius_m DOUBLE PRECISION DEFAULT 20.0)
RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO runmap.run_buffers (run_id, geom_utm)
  SELECT r.run_id,
         ST_Buffer(
           ST_Transform(r.geom_wgs84, 32610),
           p_radius_m,
           'endcap=round join=round'
         )
  FROM runmap.runs r
  LEFT JOIN runmap.run_buffers b USING (run_id)
  WHERE r.run_id = p_run_id AND b.run_id IS NULL;
$$;

CREATE OR REPLACE FUNCTION runmap.ensure_run_buffer_tiles(p_run_id BIGINT)
RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO runmap.run_buffers_subdiv (run_id, geom_utm)
  SELECT rb.run_id, ST_Subdivide(rb.geom_utm, 256)
  FROM runmap.run_buffers rb
  LEFT JOIN (
    SELECT DISTINCT run_id FROM runmap.run_buffers_subdiv
  ) s USING (run_id)
  WHERE rb.run_id = p_run_id AND s.run_id IS NULL;
$$;

CREATE OR REPLACE FUNCTION runmap.process_run(p_run_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
BEGIN
  -- Ensure buffer & tiles exist
  PERFORM runmap.ensure_run_buffer(p_run_id);
  PERFORM runmap.ensure_run_buffer_tiles(p_run_id);

  -- Per-run intersections (with bbox prefilter)
  WITH cand_blocks AS (
    SELECT b.block_id, b.geom_utm
    FROM runmap.blocks b
    JOIN runmap.run_buffers rb ON rb.run_id = p_run_id
    WHERE b.geom_utm && rb.bbox_utm
  ),
  hits AS (
    SELECT c.block_id,
           SUM(ST_Length(ST_Intersection(c.geom_utm, s.geom_utm))) AS len_hit_m
    FROM cand_blocks c
    JOIN runmap.run_buffers_subdiv s ON s.run_id = p_run_id
    WHERE c.geom_utm && s.geom_utm
    GROUP BY c.block_id
  )
  INSERT INTO runmap.block_coverage_runs (run_id, block_id, len_hit_m)
  SELECT p_run_id, block_id, GREATEST(0.0, COALESCE(len_hit_m,0.0))
  FROM hits
  ON CONFLICT (run_id, block_id) DO UPDATE
  SET len_hit_m = EXCLUDED.len_hit_m;

  -- Aggregate upsert
  INSERT INTO runmap.block_coverage (block_id, len_hit_m)
  SELECT block_id, len_hit_m
  FROM runmap.block_coverage_runs
  WHERE run_id = p_run_id
  ON CONFLICT (block_id) DO UPDATE
  SET len_hit_m = runmap.block_coverage.len_hit_m + EXCLUDED.len_hit_m;
END;
$$;

COMMIT;
