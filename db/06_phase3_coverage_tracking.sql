-- ============================================================================
-- Phase 3: Chunk Coverage Tracking
-- ============================================================================
-- Creates the coverage tracking system that uses chunks as the source of truth.
-- Incremental design: O(chunks touched) memory per run, scales to unlimited runs.
-- No global runs union needed - coverage accumulated per-chunk.
-- ============================================================================

-- ============================================================================
-- TABLE: Chunk Coverage
-- ============================================================================

-- Chunk-level coverage (source of truth)
CREATE TABLE IF NOT EXISTS runmap.chunk_coverage_32610 (
  chunk_id INT PRIMARY KEY REFERENCES runmap.streets_chunks_32610(chunk_id),
  covered_geom geometry(Geometry, 32610),  -- Can be LineString or MultiLineString after ST_Intersection
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

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_chunk_coverage_geom ON runmap.chunk_coverage_32610 USING GIST(covered_geom);
CREATE INDEX IF NOT EXISTS idx_chunk_coverage_status ON runmap.chunk_coverage_32610(status);

-- ============================================================================
-- FUNCTIONS: Coverage Calculation
-- ============================================================================

-- Apply a single run to chunk coverage (incremental)
-- Memory usage: O(chunks touched) - typically 100-300 chunks per run
CREATE OR REPLACE FUNCTION runmap.apply_run_to_chunk_coverage(run_uuid UUID)
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
  WHERE run_id = run_uuid;

  IF run_buffer IS NULL THEN
    RAISE EXCEPTION 'No buffer found for run_id %. Did you call buffer_one_run(%)?', run_uuid, run_uuid;
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

    -- Skip if coverage is negligible (< 1m)
    IF new_coverage_length < 1.0 THEN
      CONTINUE;
    END IF;

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

  RAISE NOTICE 'Run % updated % chunks', run_uuid, chunks_updated;
END;
$$ LANGUAGE plpgsql;

-- Full rebuild (process all runs from scratch)
CREATE OR REPLACE FUNCTION runmap.rebuild_chunk_coverage()
RETURNS void AS $$
DECLARE
  run_rec RECORD;
  total_runs INT;
  run_count INT := 0;
BEGIN
  TRUNCATE runmap.chunk_coverage_32610;

  SELECT COUNT(*) INTO total_runs FROM runmap.runs_raw;
  RAISE NOTICE 'Rebuilding chunk coverage for % runs...', total_runs;

  FOR run_rec IN
    SELECT id FROM runmap.runs_raw ORDER BY uploaded_at
  LOOP
    run_count := run_count + 1;
    RAISE NOTICE 'Processing run % of % (%.0f%%)...',
      run_count, total_runs, (run_count::FLOAT / total_runs * 100);

    PERFORM runmap.apply_run_to_chunk_coverage(run_rec.id);
  END LOOP;

  RAISE NOTICE '====================================';
  RAISE NOTICE 'Phase 3 Complete: Coverage Rebuild';
  RAISE NOTICE 'Total runs processed: %', total_runs;
  RAISE NOTICE 'Chunks with coverage: %', (SELECT COUNT(*) FROM runmap.chunk_coverage_32610);
  RAISE NOTICE '====================================';
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
WITH chunk_totals AS (
  SELECT
    COUNT(*) as total_chunks,
    SUM(chunk_length_m) as total_length_m
  FROM runmap.streets_chunks_32610
),
coverage_totals AS (
  SELECT
    COUNT(*) as covered_chunks,
    COUNT(*) FILTER (WHERE status = 'partial') as partial_chunks,
    COUNT(*) FILTER (WHERE status = 'complete') as complete_chunks,
    SUM(covered_length_m) as covered_length_m
  FROM runmap.chunk_coverage_32610
)
SELECT
  ct.total_chunks,
  ct.total_chunks - COALESCE(cov.covered_chunks, 0) as unrun_chunks,
  COALESCE(cov.partial_chunks, 0) as partial_chunks,
  COALESCE(cov.complete_chunks, 0) as complete_chunks,
  ct.total_length_m,
  COALESCE(cov.covered_length_m, 0) as covered_length_m,
  ROUND((COALESCE(cov.covered_length_m, 0) / NULLIF(ct.total_length_m, 0) * 100)::numeric, 2) as overall_coverage_pct
FROM chunk_totals ct
CROSS JOIN coverage_totals cov;

-- Create unique index on materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_coverage_stats_chunks_unique
  ON runmap.coverage_stats_chunks ((1));

-- ============================================================================
-- DIAGNOSTIC VIEWS
-- ============================================================================

-- Coverage summary by status
CREATE OR REPLACE VIEW runmap.coverage_summary AS
SELECT
  status,
  COUNT(*) as num_chunks,
  ROUND(AVG(coverage_pct)::numeric, 1) as avg_coverage_pct,
  ROUND(SUM(total_length_m)::numeric, 0) as total_length_m,
  ROUND(SUM(covered_length_m)::numeric, 0) as covered_length_m
FROM runmap.chunk_coverage_32610
GROUP BY status
ORDER BY
  CASE status
    WHEN 'complete' THEN 1
    WHEN 'partial' THEN 2
    WHEN 'unrun' THEN 3
  END;

-- Streets with highest coverage
CREATE OR REPLACE VIEW runmap.streets_most_complete AS
SELECT
  name,
  highway,
  total_chunks,
  complete_chunks,
  partial_chunks,
  unrun_chunks,
  avg_coverage_pct,
  ROUND(total_length_m::numeric, 0) as total_length_m,
  ROUND(covered_length_m::numeric, 0) as covered_length_m
FROM runmap.street_coverage_aggregated
WHERE total_chunks > 0
ORDER BY avg_coverage_pct DESC, complete_chunks DESC
LIMIT 50;

-- Streets with least coverage (work to do!)
CREATE OR REPLACE VIEW runmap.streets_least_complete AS
SELECT
  name,
  highway,
  total_chunks,
  complete_chunks,
  partial_chunks,
  unrun_chunks,
  avg_coverage_pct,
  ROUND(total_length_m::numeric, 0) as total_length_m,
  ROUND(covered_length_m::numeric, 0) as covered_length_m
FROM runmap.street_coverage_aggregated
WHERE total_chunks > 0
ORDER BY avg_coverage_pct ASC, unrun_chunks DESC
LIMIT 50;

-- ============================================================================
-- USAGE INSTRUCTIONS
-- ============================================================================

-- Rebuild coverage from all existing runs:
-- SELECT runmap.rebuild_chunk_coverage();
-- REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;

-- Apply a new run (after GPX upload):
-- SELECT runmap.buffer_one_run(run_id);
-- SELECT runmap.apply_run_to_chunk_coverage(run_id);
-- REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;

-- View overall stats:
-- SELECT * FROM runmap.coverage_stats_chunks;

-- View coverage by status:
-- SELECT * FROM runmap.coverage_summary;

-- See which streets are most/least complete:
-- SELECT * FROM runmap.streets_most_complete;
-- SELECT * FROM runmap.streets_least_complete;

-- Count chunks by status:
-- SELECT status, COUNT(*) FROM runmap.chunk_coverage_32610 GROUP BY status;
