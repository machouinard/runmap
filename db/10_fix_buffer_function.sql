-- ============================================================================
-- Fix buffer_one_run() to use blocks instead of chunks
-- ============================================================================
-- Run this as postgres user or runmap_user with ownership
-- ============================================================================

-- First, change ownership of the old function (run as postgres if needed)
-- ALTER FUNCTION runmap.buffer_one_run(uuid) OWNER TO runmap_user;

-- Drop and recreate function with correct table reference
DROP FUNCTION IF EXISTS runmap.buffer_one_run(uuid);

CREATE OR REPLACE FUNCTION runmap.buffer_one_run(run_uuid uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  buffer_config jsonb;
  block_rec RECORD;
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

  -- Buffer the run differently based on which blocks it intersects
  -- For each block that intersects this run, apply highway-specific buffer
  all_buffers := ARRAY[]::geometry[];

  FOR block_rec IN
    SELECT DISTINCT b.highway, b.geom_32610
    FROM runmap.streets_blocks_32610 b
    WHERE ST_DWithin(b.geom_32610, run_geom_utm, 50) -- Pre-filter with max possible buffer
  LOOP
    -- Get buffer distance for this highway type
    buffer_dist := COALESCE(
      (buffer_config->>block_rec.highway)::float,
      (buffer_config->>'default')::float,
      15.0
    );

    -- Create buffer for the portion of run near this block
    buffered_geom := ST_Buffer(
      ST_Intersection(run_geom_utm, ST_Buffer(block_rec.geom_32610, buffer_dist + 5)),
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
    -- Fallback: use default buffer if no blocks found
    buffer_dist := COALESCE((buffer_config->>'default')::float, 15.0);
    final_buffer := ST_Buffer(run_geom_utm, buffer_dist);
  END IF;

  -- Store the combined buffer
  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  VALUES (run_uuid, final_buffer)
  ON CONFLICT (run_id) DO UPDATE SET geom = EXCLUDED.geom;

END;
$function$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION runmap.buffer_one_run(uuid) TO runmap_user;
