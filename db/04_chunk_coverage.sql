-- ============================================================================
-- Chunk-Based Coverage System
-- ============================================================================
-- This schema implements topology-aware street subdivision for precise
-- coverage tracking at block level (30-50m granularity).
--
-- Two-phase subdivision:
-- 1. Split streets at real intersections (topology-based blocks)
-- 2. Further subdivide blocks >50m into uniform chunks
--
-- Memory usage: Constant O(chunks touched) per run, scales to unlimited runs
-- Server requirements: 2-3 GB peak during migration, <1 GB per upload
-- ============================================================================

-- ============================================================================
-- TABLES
-- ============================================================================

-- 1. Intersection-split streets (block-level segments)
CREATE TABLE IF NOT EXISTS runmap.streets_blocks_32610 (
  block_id SERIAL PRIMARY KEY,
  parent_ogc_fid INT REFERENCES runmap.streets_reference_32610(ogc_fid),
  block_index INT,
  geom_32610 geometry(LineString, 32610),
  block_length_m FLOAT,
  -- Metadata from parent
  name TEXT,
  highway TEXT
);
CREATE INDEX IF NOT EXISTS idx_blocks_geom ON runmap.streets_blocks_32610 USING GIST(geom_32610);
CREATE INDEX IF NOT EXISTS idx_blocks_parent ON runmap.streets_blocks_32610(parent_ogc_fid);

-- 2. Uniform chunks (blocks further subdivided if >50m)
CREATE TABLE IF NOT EXISTS runmap.streets_chunks_32610 (
  chunk_id SERIAL PRIMARY KEY,
  block_id INT REFERENCES runmap.streets_blocks_32610(block_id),
  parent_ogc_fid INT,
  chunk_index INT,
  geom_32610 geometry(LineString, 32610),
  chunk_length_m FLOAT,
  -- Metadata
  name TEXT,
  highway TEXT
);
CREATE INDEX IF NOT EXISTS idx_chunks_geom ON runmap.streets_chunks_32610 USING GIST(geom_32610);
CREATE INDEX IF NOT EXISTS idx_chunks_parent ON runmap.streets_chunks_32610(parent_ogc_fid);
CREATE INDEX IF NOT EXISTS idx_chunks_block ON runmap.streets_chunks_32610(block_id);

-- 3. Chunk-level coverage (source of truth)
-- NOTE: No global runs union needed - coverage tracked incrementally per chunk
CREATE TABLE IF NOT EXISTS runmap.chunk_coverage_32610 (
  chunk_id INT PRIMARY KEY REFERENCES runmap.streets_chunks_32610(chunk_id),
  covered_geom geometry(LineString, 32610),
  covered_length_m FLOAT,
  total_length_m FLOAT,
  coverage_pct FLOAT GENERATED ALWAYS AS (
    CASE
      WHEN total_length_m > 0 THEN ROUND((covered_length_m / total_length_m * 100)::numeric, 2)
      ELSE 0
    END
  ) STORED,
  status TEXT GENERATED ALWAYS AS (
    CASE
      WHEN covered_length_m < total_length_m * 0.05 THEN 'unrun'
      WHEN covered_length_m < total_length_m * 0.90 THEN 'partial'
      ELSE 'complete'
    END
  ) STORED
);
CREATE INDEX IF NOT EXISTS idx_chunk_coverage_geom ON runmap.chunk_coverage_32610 USING GIST(covered_geom);
CREATE INDEX IF NOT EXISTS idx_chunk_coverage_status ON runmap.chunk_coverage_32610(status);

-- ============================================================================
-- FUNCTIONS: Street Subdivision
-- ============================================================================

-- Split streets at intersection points (Phase 1: Topology)
CREATE OR REPLACE FUNCTION runmap.split_streets_at_intersections()
RETURNS void AS $$
DECLARE
  street_rec RECORD;
  intersection_pts geometry;
  split_geom geometry;
  segment geometry;
  segment_idx INT;
  segment_count INT := 0;
BEGIN
  TRUNCATE runmap.streets_blocks_32610 CASCADE;

  RAISE NOTICE 'Splitting % streets at intersections...', (SELECT COUNT(*) FROM runmap.streets_reference_32610);

  FOR street_rec IN
    SELECT ogc_fid, name, highway, geom_32610, total_length_m
    FROM runmap.streets_reference_32610
    ORDER BY ogc_fid
  LOOP
    -- Find all intersection points for this street
    -- (points where other streets cross this street's geometry)
    SELECT ST_Union(pts) INTO intersection_pts
    FROM (
      SELECT ST_Intersection(street_rec.geom_32610, other.geom_32610) AS pts
      FROM runmap.streets_reference_32610 other
      WHERE other.ogc_fid != street_rec.ogc_fid
        AND ST_Intersects(street_rec.geom_32610, other.geom_32610)
        AND ST_GeometryType(ST_Intersection(street_rec.geom_32610, other.geom_32610)) = 'ST_Point'
    ) t
    WHERE pts IS NOT NULL;

    -- If no intersections found, keep original segment as single block
    IF intersection_pts IS NULL THEN
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES
        (street_rec.ogc_fid, 0, street_rec.geom_32610, street_rec.total_length_m, street_rec.name, street_rec.highway);
      segment_count := segment_count + 1;
      CONTINUE;
    END IF;

    -- Split street at intersection points
    BEGIN
      split_geom := ST_Split(street_rec.geom_32610, intersection_pts);
    EXCEPTION WHEN OTHERS THEN
      -- If split fails (can happen with topology issues), keep original
      RAISE WARNING 'Failed to split street ogc_fid=% (%): %. Keeping as single block.',
        street_rec.ogc_fid, COALESCE(street_rec.name, 'unnamed'), SQLERRM;
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES
        (street_rec.ogc_fid, 0, street_rec.geom_32610, street_rec.total_length_m, street_rec.name, street_rec.highway);
      segment_count := segment_count + 1;
      CONTINUE;
    END;

    -- Insert each resulting segment as a block
    segment_idx := 0;
    FOR segment IN
      SELECT (ST_Dump(split_geom)).geom
    LOOP
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES (
        street_rec.ogc_fid,
        segment_idx,
        segment,
        ST_Length(segment),
        street_rec.name,
        street_rec.highway
      );
      segment_idx := segment_idx + 1;
      segment_count := segment_count + 1;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'Created % blocks from % streets', segment_count, (SELECT COUNT(*) FROM runmap.streets_reference_32610);
END;
$$ LANGUAGE plpgsql;

-- Subdivide long blocks into uniform chunks (Phase 2: Max Length)
CREATE OR REPLACE FUNCTION runmap.subdivide_blocks_to_chunks(max_chunk_length_m FLOAT DEFAULT 50.0)
RETURNS void AS $$
DECLARE
  block_rec RECORD;
  num_chunks INT;
  chunk_idx INT;
  chunk_start FLOAT;
  chunk_end FLOAT;
  chunk_geom geometry;
  chunk_count INT := 0;
BEGIN
  TRUNCATE runmap.streets_chunks_32610 CASCADE;

  RAISE NOTICE 'Subdividing % blocks into chunks (max %.0fm)...',
    (SELECT COUNT(*) FROM runmap.streets_blocks_32610), max_chunk_length_m;

  FOR block_rec IN
    SELECT block_id, parent_ogc_fid, geom_32610, block_length_m, name, highway
    FROM runmap.streets_blocks_32610
    ORDER BY block_id
  LOOP
    -- If block is already short enough, keep as single chunk
    IF block_rec.block_length_m <= max_chunk_length_m THEN
      INSERT INTO runmap.streets_chunks_32610
        (block_id, parent_ogc_fid, chunk_index, geom_32610, chunk_length_m, name, highway)
      VALUES (
        block_rec.block_id,
        block_rec.parent_ogc_fid,
        0,
        block_rec.geom_32610,
        block_rec.block_length_m,
        block_rec.name,
        block_rec.highway
      );
      chunk_count := chunk_count + 1;
      CONTINUE;
    END IF;

    -- Calculate number of chunks needed
    num_chunks := CEIL(block_rec.block_length_m / max_chunk_length_m)::INT;

    -- Create uniform chunks using ST_LineSubstring
    FOR chunk_idx IN 0..(num_chunks - 1) LOOP
      chunk_start := (chunk_idx::FLOAT / num_chunks);
      chunk_end := ((chunk_idx + 1)::FLOAT / num_chunks);

      chunk_geom := ST_LineSubstring(block_rec.geom_32610, chunk_start, chunk_end);

      INSERT INTO runmap.streets_chunks_32610
        (block_id, parent_ogc_fid, chunk_index, geom_32610, chunk_length_m, name, highway)
      VALUES (
        block_rec.block_id,
        block_rec.parent_ogc_fid,
        chunk_idx,
        chunk_geom,
        ST_Length(chunk_geom),
        block_rec.name,
        block_rec.highway
      );
      chunk_count := chunk_count + 1;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'Created % chunks from % blocks (avg %.1f chunks/block)',
    chunk_count,
    (SELECT COUNT(*) FROM runmap.streets_blocks_32610),
    chunk_count::FLOAT / GREATEST((SELECT COUNT(*) FROM runmap.streets_blocks_32610), 1);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FUNCTIONS: Coverage Calculation
-- ============================================================================

-- Apply a single run to chunk coverage (incremental)
-- Memory usage: O(chunks touched) - typically 50-200 chunks per run
CREATE OR REPLACE FUNCTION runmap.apply_run_to_chunk_coverage(run_gid BIGINT)
RETURNS void AS $$
DECLARE
  run_buffer geometry;
  chunk_rec RECORD;
  new_coverage geometry;
  new_coverage_length FLOAT;
  chunks_updated INT := 0;
BEGIN
  -- Get this run's buffer
  SELECT geom INTO run_buffer
  FROM runmap.runs_buffered_32610
  WHERE run_id = run_gid;

  IF run_buffer IS NULL THEN
    RAISE EXCEPTION 'No buffer found for run_id %. Did you call buffer_one_run(%)?', run_gid, run_gid;
  END IF;

  -- Update only chunks that intersect this run's buffer
  FOR chunk_rec IN
    SELECT chunk_id, geom_32610, chunk_length_m
    FROM runmap.streets_chunks_32610
    WHERE ST_Intersects(geom_32610, run_buffer)
  LOOP
    -- Calculate new coverage geometry (intersection of chunk with buffer)
    new_coverage := ST_Intersection(chunk_rec.geom_32610, run_buffer);

    -- Skip if intersection is not a line/multiline (point touches don't count)
    IF ST_GeometryType(new_coverage) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
      CONTINUE;
    END IF;

    new_coverage_length := ST_Length(new_coverage);

    -- Insert or update coverage (union with existing coverage)
    INSERT INTO runmap.chunk_coverage_32610 (chunk_id, covered_geom, covered_length_m, total_length_m)
    VALUES (chunk_rec.chunk_id, new_coverage, new_coverage_length, chunk_rec.chunk_length_m)
    ON CONFLICT (chunk_id) DO UPDATE SET
      -- Union the new coverage with existing coverage
      covered_geom = ST_Union(runmap.chunk_coverage_32610.covered_geom, EXCLUDED.covered_geom),
      covered_length_m = ST_Length(ST_Union(runmap.chunk_coverage_32610.covered_geom, EXCLUDED.covered_geom)),
      total_length_m = EXCLUDED.total_length_m;

    chunks_updated := chunks_updated + 1;
  END LOOP;

  RAISE NOTICE 'Run % updated % chunks', run_gid, chunks_updated;
END;
$$ LANGUAGE plpgsql;

-- Full rebuild (process all runs from scratch)
CREATE OR REPLACE FUNCTION runmap.rebuild_chunk_coverage()
RETURNS void AS $$
DECLARE
  run_rec RECORD;
  total_runs INT;
BEGIN
  TRUNCATE runmap.chunk_coverage_32610;

  SELECT COUNT(*) INTO total_runs FROM runmap.runs_raw;
  RAISE NOTICE 'Rebuilding chunk coverage for % runs...', total_runs;

  FOR run_rec IN
    SELECT gid FROM runmap.runs_raw ORDER BY gid
  LOOP
    PERFORM runmap.apply_run_to_chunk_coverage(run_rec.gid);
  END LOOP;

  RAISE NOTICE 'Rebuilt coverage: % chunks with coverage', (SELECT COUNT(*) FROM runmap.chunk_coverage_32610);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- VIEWS: Chunks by Status
-- ============================================================================

-- Unrun chunks (<5% coverage or no coverage)
CREATE OR REPLACE VIEW runmap.chunks_unrun AS
SELECT
  c.chunk_id,
  c.geom_32610,
  c.name,
  c.highway,
  c.chunk_length_m,
  COALESCE(cc.coverage_pct, 0) as coverage_pct
FROM runmap.streets_chunks_32610 c
LEFT JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
WHERE COALESCE(cc.status, 'unrun') = 'unrun';

-- Partial chunks (5-90% coverage)
CREATE OR REPLACE VIEW runmap.chunks_partial AS
SELECT
  c.chunk_id,
  c.geom_32610,
  c.name,
  c.highway,
  c.chunk_length_m,
  cc.coverage_pct
FROM runmap.streets_chunks_32610 c
JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
WHERE cc.status = 'partial';

-- Complete chunks (≥90% coverage)
CREATE OR REPLACE VIEW runmap.chunks_complete AS
SELECT
  c.chunk_id,
  c.geom_32610,
  c.name,
  c.highway,
  c.chunk_length_m,
  cc.coverage_pct
FROM runmap.streets_chunks_32610 c
JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
WHERE cc.status = 'complete';

-- ============================================================================
-- VIEWS: Aggregated Street-Level Stats
-- ============================================================================

-- Aggregate chunk coverage back to original street segments
CREATE OR REPLACE VIEW runmap.street_coverage_aggregated AS
SELECT
  s.ogc_fid,
  s.name,
  s.highway,
  COUNT(c.chunk_id) as total_chunks,
  COUNT(cc.chunk_id) FILTER (WHERE cc.status = 'complete') as complete_chunks,
  COUNT(cc.chunk_id) FILTER (WHERE cc.status = 'partial') as partial_chunks,
  COUNT(c.chunk_id) - COALESCE(COUNT(cc.chunk_id), 0) as unrun_chunks,
  ROUND(AVG(COALESCE(cc.coverage_pct, 0))::numeric, 1) as avg_coverage_pct,
  SUM(c.chunk_length_m) as total_length_m,
  SUM(COALESCE(cc.covered_length_m, 0)) as covered_length_m
FROM runmap.streets_reference_32610 s
JOIN runmap.streets_chunks_32610 c ON c.parent_ogc_fid = s.ogc_fid
LEFT JOIN runmap.chunk_coverage_32610 cc USING (chunk_id)
GROUP BY s.ogc_fid, s.name, s.highway;

-- ============================================================================
-- MATERIALIZED VIEW: Overall Coverage Stats
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS runmap.coverage_stats_chunks AS
SELECT
  (SELECT COUNT(*) FROM runmap.streets_chunks_32610) as total_chunks,
  (SELECT COUNT(*) FROM runmap.chunk_coverage_32610 WHERE status = 'unrun') +
    (SELECT COUNT(*) FROM runmap.streets_chunks_32610) -
    (SELECT COUNT(*) FROM runmap.chunk_coverage_32610) as unrun_chunks,
  (SELECT COUNT(*) FROM runmap.chunk_coverage_32610 WHERE status = 'partial') as partial_chunks,
  (SELECT COUNT(*) FROM runmap.chunk_coverage_32610 WHERE status = 'complete') as complete_chunks,
  (SELECT SUM(chunk_length_m) FROM runmap.streets_chunks_32610) as total_length_m,
  (SELECT COALESCE(SUM(covered_length_m), 0) FROM runmap.chunk_coverage_32610) as covered_length_m,
  (SELECT ROUND((COALESCE(SUM(covered_length_m), 0) / NULLIF(SUM(total_length_m), 0) * 100)::numeric, 2)
   FROM runmap.chunk_coverage_32610) as overall_coverage_pct;

-- Create index on materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_coverage_stats_chunks_unique
  ON runmap.coverage_stats_chunks ((1));

-- ============================================================================
-- INITIALIZATION FUNCTION
-- ============================================================================

-- One-command initialization: split streets, create chunks
CREATE OR REPLACE FUNCTION runmap.initialize_chunk_system(max_chunk_length_m FLOAT DEFAULT 50.0)
RETURNS void AS $$
BEGIN
  RAISE NOTICE '====================================';
  RAISE NOTICE 'Initializing chunk-based coverage system';
  RAISE NOTICE 'Max chunk length: %.0fm', max_chunk_length_m;
  RAISE NOTICE '====================================';

  RAISE NOTICE 'Phase 1: Splitting streets at intersections...';
  PERFORM runmap.split_streets_at_intersections();

  RAISE NOTICE 'Phase 2: Subdividing blocks into chunks...';
  PERFORM runmap.subdivide_blocks_to_chunks(max_chunk_length_m);

  RAISE NOTICE 'Phase 3: Rebuilding coverage from existing runs...';
  PERFORM runmap.rebuild_chunk_coverage();

  RAISE NOTICE 'Phase 4: Refreshing stats...';
  REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;

  RAISE NOTICE '====================================';
  RAISE NOTICE 'Initialization complete!';
  RAISE NOTICE 'Blocks: %', (SELECT COUNT(*) FROM runmap.streets_blocks_32610);
  RAISE NOTICE 'Chunks: %', (SELECT COUNT(*) FROM runmap.streets_chunks_32610);
  RAISE NOTICE 'Chunks with coverage: %', (SELECT COUNT(*) FROM runmap.chunk_coverage_32610);
  RAISE NOTICE '====================================';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- USAGE INSTRUCTIONS
-- ============================================================================

-- Initialize the system (one-time setup):
-- SELECT runmap.initialize_chunk_system(50.0);

-- After each GPX upload (in API):
-- 1. SELECT runmap.buffer_one_run(run_id);
-- 2. SELECT runmap.apply_run_to_chunk_coverage(run_id);
-- 3. REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;

-- View stats:
-- SELECT * FROM runmap.coverage_stats_chunks;

-- View chunks by status:
-- SELECT COUNT(*), status FROM runmap.chunk_coverage_32610 GROUP BY status;

-- Export tiles:
-- Use views: chunks_unrun, chunks_partial, chunks_complete
