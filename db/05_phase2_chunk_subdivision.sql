-- ============================================================================
-- Phase 2: Subdivide Blocks into Uniform Chunks
-- ============================================================================
-- Takes blocks from Phase 1 and subdivides any >50m into uniform chunks.
-- This ensures consistent rendering and prevents large blocks from dominating
-- coverage calculations.
-- ============================================================================

-- Create the chunks table
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

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_chunks_geom ON runmap.streets_chunks_32610 USING GIST(geom_32610);
CREATE INDEX IF NOT EXISTS idx_chunks_parent ON runmap.streets_chunks_32610(parent_ogc_fid);
CREATE INDEX IF NOT EXISTS idx_chunks_block ON runmap.streets_chunks_32610(block_id);

-- Subdivide long blocks into uniform chunks
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
  block_count INT := 0;
  total_blocks INT;
BEGIN
  -- Clear existing data
  TRUNCATE runmap.streets_chunks_32610 CASCADE;

  SELECT COUNT(*) INTO total_blocks FROM runmap.streets_blocks_32610;
  RAISE NOTICE 'Subdividing % blocks into chunks (max %.0fm)...', total_blocks, max_chunk_length_m;

  FOR block_rec IN
    SELECT block_id, parent_ogc_fid, geom_32610, block_length_m, name, highway
    FROM runmap.streets_blocks_32610
    ORDER BY block_id
  LOOP
    block_count := block_count + 1;

    -- Progress indicator every 500 blocks
    IF block_count % 500 = 0 THEN
      RAISE NOTICE 'Processing block % of % (%.0f%%)...',
        block_count, total_blocks, (block_count::FLOAT / total_blocks * 100);
    END IF;

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

  RAISE NOTICE '====================================';
  RAISE NOTICE 'Phase 2 Complete: Chunk Subdivision';
  RAISE NOTICE 'Input: % blocks', total_blocks;
  RAISE NOTICE 'Output: % chunks', chunk_count;
  RAISE NOTICE 'Ratio: %.1f chunks per block', chunk_count::FLOAT / total_blocks;
  RAISE NOTICE '====================================';
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- DIAGNOSTIC QUERIES
-- ============================================================================

-- View chunk statistics
CREATE OR REPLACE VIEW runmap.chunks_stats AS
SELECT
  COUNT(*) as total_chunks,
  ROUND(AVG(chunk_length_m)::numeric, 1) as avg_length_m,
  ROUND(MIN(chunk_length_m)::numeric, 1) as min_length_m,
  ROUND(MAX(chunk_length_m)::numeric, 1) as max_length_m,
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY chunk_length_m)::numeric, 1) as median_length_m,
  COUNT(*) FILTER (WHERE chunk_length_m > 50) as chunks_over_50m,
  COUNT(*) FILTER (WHERE chunk_length_m > 40) as chunks_over_40m,
  COUNT(*) FILTER (WHERE chunk_length_m > 30) as chunks_over_30m
FROM runmap.streets_chunks_32610;

-- View chunks grouped by parent block
CREATE OR REPLACE VIEW runmap.chunks_per_block AS
SELECT
  b.block_id,
  b.name,
  b.highway,
  b.block_length_m,
  COUNT(c.chunk_id) as num_chunks,
  ROUND(AVG(c.chunk_length_m)::numeric, 1) as avg_chunk_length_m
FROM runmap.streets_blocks_32610 b
LEFT JOIN runmap.streets_chunks_32610 c USING (block_id)
GROUP BY b.block_id, b.name, b.highway, b.block_length_m
ORDER BY COUNT(c.chunk_id) DESC;

-- View chunks grouped by original street
CREATE OR REPLACE VIEW runmap.chunks_per_street AS
SELECT
  s.ogc_fid,
  s.name,
  s.highway,
  s.total_length_m as original_length_m,
  COUNT(c.chunk_id) as num_chunks,
  ROUND(AVG(c.chunk_length_m)::numeric, 1) as avg_chunk_length_m
FROM runmap.streets_reference_32610 s
LEFT JOIN runmap.streets_chunks_32610 c ON c.parent_ogc_fid = s.ogc_fid
GROUP BY s.ogc_fid, s.name, s.highway, s.total_length_m
ORDER BY COUNT(c.chunk_id) DESC;

-- ============================================================================
-- USAGE
-- ============================================================================

-- Run the subdivision:
-- SELECT runmap.subdivide_blocks_to_chunks(50.0);

-- View statistics:
-- SELECT * FROM runmap.chunks_stats;

-- See which blocks got subdivided the most:
-- SELECT * FROM runmap.chunks_per_block WHERE num_chunks > 1 LIMIT 20;

-- See chunk counts by original street:
-- SELECT * FROM runmap.chunks_per_street LIMIT 20;

-- Check P Street:
-- SELECT * FROM runmap.chunks_per_street WHERE name = 'P Street';
