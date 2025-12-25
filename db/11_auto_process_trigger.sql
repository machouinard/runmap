-- ============================================================================
-- Auto-Process Trigger for New Runs
-- ============================================================================
-- ⚠️  WARNING: THIS FILE IS OUTDATED AND DOES NOT MATCH PRODUCTION ⚠️
--
-- The trigger documented here does NOT exist in production. Production uses:
--   - Trigger name: trigger_auto_process_run_segments
--   - Function: auto_process_new_run_segments()
--   - System: Segment-visited coverage (not block-percentage)
--
-- This file documents an older block-percentage approach that was never deployed.
-- The actual production trigger is defined in 04_segment_schema.sql.
--
-- DO NOT RUN THIS FILE ON PRODUCTION DATABASE.
--
-- See: docs/SEGMENT_VISITED_MIGRATION.md for current system details
-- ============================================================================

-- Function to set location and distance BEFORE insert (allows modifying NEW record)
CREATE OR REPLACE FUNCTION runmap.set_location_on_insert()
RETURNS TRIGGER AS $$
BEGIN
  -- Set location if not already set and geometry exists
  IF NEW.geom IS NOT NULL AND NEW.location IS NULL THEN
    NEW.location := runmap.detect_location(NEW.geom);
  END IF;

  -- Calculate distance if not already set and geometry exists
  IF NEW.geom IS NOT NULL AND NEW.total_distance_m IS NULL THEN
    NEW.total_distance_m := ST_Length(ST_Transform(NEW.geom, 32610));
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Function to auto-process a newly inserted run AFTER insert
CREATE OR REPLACE FUNCTION runmap.auto_process_new_run()
RETURNS TRIGGER AS $$
BEGIN
  -- Create buffer for this run
  PERFORM runmap.buffer_one_run(NEW.id);

  -- Apply run to block coverage
  PERFORM runmap.apply_run_to_block_coverage(NEW.id);

  -- Refresh coverage stats
  REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

  -- Log the processing
  RAISE NOTICE 'Auto-processed run: % (file: %, location: %)', NEW.id, NEW.filename, NEW.location;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop old trigger (was AFTER, now needs to be BEFORE to set location)
DROP TRIGGER IF EXISTS trigger_auto_process_run ON runmap.runs_raw;

-- Create trigger that fires BEFORE INSERT to set location
-- Then processes AFTER the row is inserted
CREATE TRIGGER trigger_set_location_before_insert
  BEFORE INSERT ON runmap.runs_raw
  FOR EACH ROW
  EXECUTE FUNCTION runmap.set_location_on_insert();

CREATE TRIGGER trigger_auto_process_run
  AFTER INSERT ON runmap.runs_raw
  FOR EACH ROW
  EXECUTE FUNCTION runmap.auto_process_new_run();

-- Grant permissions
GRANT EXECUTE ON FUNCTION runmap.set_location_on_insert() TO runmap_user;
GRANT EXECUTE ON FUNCTION runmap.auto_process_new_run() TO runmap_user;

-- ============================================================================
-- VERIFICATION
-- ============================================================================

-- Check trigger was created
-- SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid = 'runmap.runs_raw'::regclass;

-- Test by inserting a run (it will auto-process)
-- Then check coverage stats to see it updated
