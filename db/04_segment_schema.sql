-- Segment-Visited Schema
-- Creates shadow tables alongside existing coverage tables
-- Enables constant-time coverage processing regardless of run count

-- Run buffers subdivided for faster intersection tests
CREATE TABLE IF NOT EXISTS runmap.runs_buffered_subdiv (
  run_id UUID NOT NULL REFERENCES runmap.runs_raw(id) ON DELETE CASCADE,
  geom geometry(Polygon, 32610) NOT NULL
);
-- Note: No primary key on (run_id, geom) because ST_Subdivide creates duplicate-looking geometries
CREATE INDEX idx_runs_buffered_subdiv_run ON runmap.runs_buffered_subdiv(run_id);
CREATE INDEX idx_runs_buffered_subdiv_geom ON runmap.runs_buffered_subdiv USING GIST(geom);

-- Pre-segmented blocks (one-time computation, ~5m pieces)
CREATE TABLE IF NOT EXISTS runmap.block_segments (
  segment_id SERIAL PRIMARY KEY,
  block_id INTEGER NOT NULL REFERENCES runmap.streets_blocks_32610(block_id) ON DELETE CASCADE,
  segment_geom geometry(LineString, 32610) NOT NULL,
  segment_length_m DOUBLE PRECISION NOT NULL
);
CREATE INDEX idx_block_segments_block ON runmap.block_segments(block_id);
CREATE INDEX idx_block_segments_geom ON runmap.block_segments USING GIST(segment_geom);

-- Binary visited flags (the core of the optimization!)
CREATE TABLE IF NOT EXISTS runmap.block_segment_visited (
  segment_id INTEGER PRIMARY KEY REFERENCES runmap.block_segments(segment_id) ON DELETE CASCADE,
  visited BOOLEAN NOT NULL DEFAULT FALSE
);
-- Partial index for fast lookup of visited segments
CREATE INDEX IF NOT EXISTS idx_segment_visited_true ON runmap.block_segment_visited(segment_id) WHERE visited = TRUE;

-- Initialize visited flags for all segments (idempotent)
INSERT INTO runmap.block_segment_visited (segment_id, visited)
SELECT segment_id, FALSE
FROM runmap.block_segments
ON CONFLICT (segment_id) DO NOTHING;

-- Aggregate coverage computed from visited segments
CREATE TABLE IF NOT EXISTS runmap.block_coverage_segments (
  block_id INTEGER PRIMARY KEY REFERENCES runmap.streets_blocks_32610(block_id) ON DELETE CASCADE,
  visited_length_m DOUBLE PRECISION NOT NULL DEFAULT 0,
  total_length_m DOUBLE PRECISION NOT NULL,
  coverage_pct DOUBLE PRECISION GENERATED ALWAYS AS (
    CASE
      WHEN total_length_m > 0 THEN ROUND((visited_length_m / total_length_m * 100)::numeric, 2)
      ELSE 0
    END
  ) STORED
);
CREATE INDEX idx_block_coverage_segments_pct ON runmap.block_coverage_segments(coverage_pct);

-- Performance log for tracking optimization results
CREATE TABLE IF NOT EXISTS runmap.performance_log (
  id SERIAL PRIMARY KEY,
  logged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  operation TEXT NOT NULL,
  run_count INTEGER,
  avg_seconds NUMERIC(10,3),
  total_seconds NUMERIC(10,3),
  optimization TEXT,
  notes TEXT
);
CREATE INDEX idx_performance_log_operation ON runmap.performance_log(operation, logged_at);

-- Function to buffer and subdivide a single run
CREATE OR REPLACE FUNCTION runmap.buffer_one_run_subdiv(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_buffer_distance FLOAT;
BEGIN
  -- Session tuning
  PERFORM set_config('work_mem', '256MB', true);
  PERFORM set_config('jit', 'off', true);

  v_buffer_distance := runmap.get_buffer_distance();

  -- Create buffer and subdivide into smaller polygons
  INSERT INTO runmap.runs_buffered_subdiv (run_id, geom)
  SELECT
    run_uuid,
    (ST_Dump(ST_Subdivide(
      ST_Buffer(
        ST_Transform(geom, 32610),
        v_buffer_distance,
        'endcap=flat join=mitre quad_segs=4'  -- Cheaper buffers
      ),
      256  -- Max vertices per subdivision
    ))).geom
  FROM runmap.runs_raw
  WHERE id = run_uuid;
END;
$function$;

-- Function to mark segments as visited for a run (the core operation!)
CREATE OR REPLACE FUNCTION runmap.apply_run_to_segments(run_uuid uuid)
RETURNS INTEGER
LANGUAGE plpgsql
AS $function$
DECLARE
  v_segments_marked INTEGER;
BEGIN
  -- Session tuning
  PERFORM set_config('work_mem', '512MB', true);
  PERFORM set_config('jit', 'off', true);

  -- Mark segments as visited (fast UPDATE, no unions!)
  WITH newly_visited AS (
    UPDATE runmap.block_segment_visited bsv
    SET visited = TRUE
    FROM runmap.block_segments bs
    JOIN runmap.runs_buffered_subdiv rb ON rb.run_id = run_uuid
    WHERE bsv.segment_id = bs.segment_id
      AND bsv.visited = FALSE  -- Only update unvisited segments
      AND ST_Intersects(bs.segment_geom, rb.geom)
    RETURNING bsv.segment_id, bs.block_id, bs.segment_length_m
  )
  -- Update aggregate coverage for affected blocks
  INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
  SELECT
    nv.block_id,
    SUM(nv.segment_length_m) as new_visited_length,
    (SELECT SUM(segment_length_m) FROM runmap.block_segments WHERE block_id = nv.block_id) as total
  FROM newly_visited nv
  GROUP BY nv.block_id
  ON CONFLICT (block_id) DO UPDATE
  SET visited_length_m = runmap.block_coverage_segments.visited_length_m + EXCLUDED.visited_length_m;

  -- Get count for logging
  GET DIAGNOSTICS v_segments_marked = ROW_COUNT;

  RETURN v_segments_marked;
END;
$function$;

COMMENT ON TABLE runmap.runs_buffered_subdiv IS 'Subdivided run buffers for faster intersection tests';
COMMENT ON TABLE runmap.block_segments IS 'Pre-segmented blocks (~5m pieces) for binary visited tracking';
COMMENT ON TABLE runmap.block_segment_visited IS 'Binary visited flags - core of constant-time algorithm';
COMMENT ON TABLE runmap.block_coverage_segments IS 'Aggregate coverage computed from visited segments';
COMMENT ON FUNCTION runmap.buffer_one_run_subdiv IS 'Buffer and subdivide a single run for segment-visited processing';
COMMENT ON FUNCTION runmap.apply_run_to_segments IS 'Mark segments as visited by a run (constant time, no unions!)';
