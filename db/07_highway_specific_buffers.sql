-- ============================================================================
-- Highway-Specific Buffer Distances
-- ============================================================================
-- Allows different buffer distances based on highway type to account for:
-- - Sidewalk distance from road centerline
-- - GPS drift
-- - Street width variations
-- ============================================================================

-- Insert highway-specific buffer configuration
INSERT INTO runmap.settings (key, value) VALUES
  ('buffer_config', '{
    "primary": 20,
    "secondary": 18,
    "tertiary": 15,
    "residential": 12,
    "unclassified": 12,
    "living_street": 10,
    "default": 15
  }'::jsonb)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- Drop and recreate the buffer_one_run function to use highway-specific buffers
DROP FUNCTION IF EXISTS runmap.buffer_one_run(uuid);

CREATE FUNCTION runmap.buffer_one_run(run_uuid UUID)
RETURNS void AS $$
DECLARE
  buffer_config jsonb;
  chunk_rec RECORD;
  buffer_dist FLOAT;
  run_geom_utm geometry;
  buffered_geom geometry;
  all_buffers geometry[];
  final_buffer geometry;
BEGIN
  -- Get buffer configuration
  SELECT value INTO buffer_config
  FROM runmap.settings WHERE key = 'buffer_config';

  IF buffer_config IS NULL THEN
    -- Fallback to old single buffer distance
    SELECT (value::jsonb)::float INTO buffer_dist
    FROM runmap.settings WHERE key = 'buffer_distance_m';

    IF buffer_dist IS NULL THEN
      buffer_dist := 10.0;
    END IF;

    -- Use old method (single buffer for entire run)
    INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
    SELECT
      run_uuid,
      ST_Buffer(ST_Transform(geom, 32610), buffer_dist)
    FROM runmap.runs_raw
    WHERE id = run_uuid
    ON CONFLICT (run_id) DO UPDATE SET geom = EXCLUDED.geom;

    RETURN;
  END IF;

  -- Get run geometry in UTM
  SELECT ST_Transform(geom, 32610) INTO run_geom_utm
  FROM runmap.runs_raw
  WHERE id = run_uuid;

  IF run_geom_utm IS NULL THEN
    RAISE EXCEPTION 'Run % not found in runs_raw', run_uuid;
  END IF;

  -- Buffer the run differently based on which chunks it intersects
  -- For each chunk that intersects this run, apply highway-specific buffer
  all_buffers := ARRAY[]::geometry[];

  FOR chunk_rec IN
    SELECT DISTINCT c.highway, c.geom_32610
    FROM runmap.streets_chunks_32610 c
    WHERE ST_DWithin(c.geom_32610, run_geom_utm, 50) -- Pre-filter with max possible buffer
  LOOP
    -- Get buffer distance for this highway type
    buffer_dist := COALESCE(
      (buffer_config->>chunk_rec.highway)::float,
      (buffer_config->>'default')::float,
      15.0
    );

    -- Create buffer for the portion of run near this chunk
    buffered_geom := ST_Buffer(
      ST_Intersection(run_geom_utm, ST_Buffer(chunk_rec.geom_32610, buffer_dist + 5)),
      buffer_dist
    );

    -- Add to array if valid geometry
    IF buffered_geom IS NOT NULL AND NOT ST_IsEmpty(buffered_geom) THEN
      all_buffers := array_append(all_buffers, buffered_geom);
    END IF;
  END LOOP;

  -- Union all the highway-specific buffers
  IF array_length(all_buffers, 1) > 0 THEN
    final_buffer := ST_Union(all_buffers);
  ELSE
    -- Fallback: use default buffer if no chunks found
    buffer_dist := COALESCE((buffer_config->>'default')::float, 15.0);
    final_buffer := ST_Buffer(run_geom_utm, buffer_dist);
  END IF;

  -- Store the combined buffer
  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  VALUES (run_uuid, final_buffer)
  ON CONFLICT (run_id) DO UPDATE SET geom = EXCLUDED.geom;

END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Helper function to view current buffer config
-- ============================================================================
CREATE OR REPLACE FUNCTION runmap.get_buffer_config()
RETURNS TABLE(highway_type text, buffer_meters float) AS $$
DECLARE
  config jsonb;
  hwy_key text;
BEGIN
  SELECT value INTO config FROM runmap.settings WHERE settings.key = 'buffer_config';

  IF config IS NULL THEN
    -- Return old single buffer setting
    RETURN QUERY
    SELECT 'all (legacy)'::text, (value::jsonb)::float
    FROM runmap.settings WHERE settings.key = 'buffer_distance_m';
    RETURN;
  END IF;

  -- Return each highway type and its buffer
  FOR hwy_key IN SELECT jsonb_object_keys(config) LOOP
    RETURN QUERY SELECT hwy_key, (config->>hwy_key)::float;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Helper function to update buffer for a specific highway type
-- ============================================================================
CREATE OR REPLACE FUNCTION runmap.set_buffer_distance(highway_type text, distance_m float)
RETURNS void AS $$
DECLARE
  config jsonb;
BEGIN
  SELECT value INTO config FROM runmap.settings WHERE key = 'buffer_config';

  IF config IS NULL THEN
    config := '{}'::jsonb;
  END IF;

  -- Update the specific highway type
  config := jsonb_set(config, ARRAY[highway_type], to_jsonb(distance_m));

  -- Save back to settings
  UPDATE runmap.settings SET value = config WHERE key = 'buffer_config';

  RAISE NOTICE 'Updated buffer for % to %m', highway_type, distance_m;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- USAGE EXAMPLES
-- ============================================================================

-- View current buffer configuration:
-- SELECT * FROM runmap.get_buffer_config();

-- Update buffer for a specific highway type:
-- SELECT runmap.set_buffer_distance('primary', 25.0);
-- SELECT runmap.set_buffer_distance('residential', 10.0);

-- After changing buffers, rebuild all run buffers and coverage:
-- TRUNCATE runmap.runs_buffered_32610;
-- TRUNCATE runmap.chunk_coverage_32610;
-- DO $$
-- DECLARE run_rec RECORD;
-- BEGIN
--   FOR run_rec IN SELECT id FROM runmap.runs_raw ORDER BY uploaded_at LOOP
--     PERFORM runmap.buffer_one_run(run_rec.id);
--     PERFORM runmap.apply_run_to_chunk_coverage(run_rec.id);
--   END LOOP;
-- END $$;
-- REFRESH MATERIALIZED VIEW runmap.coverage_stats_chunks;
