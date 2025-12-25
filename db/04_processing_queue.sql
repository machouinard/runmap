-- Processing Queue System
-- Tracks run processing status and errors for debugging

-- Add processing_status to runs_raw
ALTER TABLE runmap.runs_raw
ADD COLUMN IF NOT EXISTS processing_status VARCHAR(20) DEFAULT 'pending'
CHECK (processing_status IN ('pending', 'processing', 'processed', 'failed'));

-- Add processing timestamps
ALTER TABLE runmap.runs_raw
ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS processing_completed_at TIMESTAMP WITH TIME ZONE;

-- Create index for querying by status
CREATE INDEX IF NOT EXISTS idx_runs_processing_status
ON runmap.runs_raw(processing_status);

-- Create processing errors log table
CREATE TABLE IF NOT EXISTS runmap.processing_errors (
  id SERIAL PRIMARY KEY,
  run_id UUID NOT NULL REFERENCES runmap.runs_raw(id) ON DELETE CASCADE,
  error_type VARCHAR(50) NOT NULL, -- 'buffer_creation', 'coverage_update', 'tile_export'
  error_message TEXT NOT NULL,
  occurred_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  retry_count INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_processing_errors_run_id
ON runmap.processing_errors(run_id);

CREATE INDEX IF NOT EXISTS idx_processing_errors_occurred_at
ON runmap.processing_errors(occurred_at DESC);

-- Update existing runs to 'processed' if they have buffers
UPDATE runmap.runs_raw
SET processing_status = 'processed',
    processing_completed_at = uploaded_at
WHERE id IN (
  SELECT DISTINCT run_id FROM runmap.runs_buffered_subdiv
);

-- Mark runs without buffers as 'failed'
UPDATE runmap.runs_raw
SET processing_status = 'failed'
WHERE processing_status = 'pending'
  AND id NOT IN (SELECT DISTINCT run_id FROM runmap.runs_buffered_subdiv);

-- View for failed runs needing attention
CREATE OR REPLACE VIEW runmap.failed_runs AS
SELECT
  r.id,
  r.filename,
  r.start_time,
  r.total_distance_m,
  r.location,
  r.uploaded_at,
  r.processing_started_at,
  r.processing_status,
  pe.error_message,
  pe.error_type,
  pe.retry_count,
  pe.occurred_at as last_error_at
FROM runmap.runs_raw r
LEFT JOIN LATERAL (
  SELECT error_type, error_message, retry_count, occurred_at
  FROM runmap.processing_errors
  WHERE run_id = r.id
  ORDER BY occurred_at DESC
  LIMIT 1
) pe ON true
WHERE r.processing_status IN ('failed', 'pending')
ORDER BY r.uploaded_at DESC;

-- Function to retry processing a failed run
CREATE OR REPLACE FUNCTION runmap.retry_run_processing(p_run_id UUID)
RETURNS TABLE(success BOOLEAN, message TEXT) AS $$
DECLARE
  v_buffer_count INTEGER;
  v_segments_updated INTEGER := 0;
BEGIN
  -- Mark as processing
  UPDATE runmap.runs_raw
  SET processing_status = 'processing',
      processing_started_at = CURRENT_TIMESTAMP
  WHERE id = p_run_id;

  -- Try to create buffer
  BEGIN
    PERFORM runmap.buffer_one_run_subdiv(p_run_id);

    -- Check if buffer was created
    SELECT COUNT(*) INTO v_buffer_count
    FROM runmap.runs_buffered_subdiv
    WHERE run_id = p_run_id;

    IF v_buffer_count = 0 THEN
      -- Log error
      INSERT INTO runmap.processing_errors (run_id, error_type, error_message)
      VALUES (p_run_id, 'buffer_creation', 'Buffer created but no subdivisions found');

      UPDATE runmap.runs_raw
      SET processing_status = 'failed'
      WHERE id = p_run_id;

      RETURN QUERY SELECT false, 'Buffer creation failed - no subdivisions created'::TEXT;
      RETURN;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Log error
    INSERT INTO runmap.processing_errors (run_id, error_type, error_message)
    VALUES (p_run_id, 'buffer_creation', SQLERRM);

    UPDATE runmap.runs_raw
    SET processing_status = 'failed'
    WHERE id = p_run_id;

    RETURN QUERY SELECT false, 'Buffer creation error: ' || SQLERRM;
    RETURN;
  END;

  -- Try to apply to coverage
  BEGIN
    SELECT runmap.apply_run_to_segments(p_run_id) INTO v_segments_updated;

    -- Mark as processed
    UPDATE runmap.runs_raw
    SET processing_status = 'processed',
        processing_completed_at = CURRENT_TIMESTAMP
    WHERE id = p_run_id;

    -- Refresh stats
    REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

    RETURN QUERY SELECT true, ('Run processed successfully - ' || v_segments_updated || ' segments updated')::TEXT;
  EXCEPTION WHEN OTHERS THEN
    -- Log error
    INSERT INTO runmap.processing_errors (run_id, error_type, error_message)
    VALUES (p_run_id, 'coverage_update', SQLERRM);

    UPDATE runmap.runs_raw
    SET processing_status = 'failed'
    WHERE id = p_run_id;

    RETURN QUERY SELECT false, 'Coverage update error: ' || SQLERRM;
  END;
END;
$$ LANGUAGE plpgsql;

-- Update the auto-process trigger to use new status tracking
CREATE OR REPLACE FUNCTION runmap.auto_process_new_run()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_buffer_count INTEGER;
BEGIN
  -- Mark as processing
  NEW.processing_status = 'processing';
  NEW.processing_started_at = CURRENT_TIMESTAMP;

  -- Try to create buffer
  BEGIN
    PERFORM runmap.buffer_one_run_subdiv(NEW.id);

    -- Check if buffer was created
    SELECT COUNT(*) INTO v_buffer_count
    FROM runmap.runs_buffered_subdiv
    WHERE run_id = NEW.id;

    IF v_buffer_count = 0 THEN
      -- Log error
      INSERT INTO runmap.processing_errors (run_id, error_type, error_message)
      VALUES (NEW.id, 'buffer_creation', 'Buffer created but no subdivisions found');

      NEW.processing_status = 'failed';
      RAISE NOTICE 'Buffer creation failed for run: % (file: %)', NEW.id, NEW.filename;
      RETURN NEW;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Log error
    INSERT INTO runmap.processing_errors (run_id, error_type, error_message)
    VALUES (NEW.id, 'buffer_creation', SQLERRM);

    NEW.processing_status = 'failed';
    RAISE NOTICE 'Buffer creation error for run: % - %', NEW.id, SQLERRM;
    RETURN NEW;
  END;

  -- Try to apply to coverage
  BEGIN
    v_segments_updated := runmap.apply_run_to_segments(NEW.id);

    -- Refresh coverage stats
    REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

    -- Mark as processed
    NEW.processing_status = 'processed';
    NEW.processing_completed_at = CURRENT_TIMESTAMP;

    RAISE NOTICE 'Auto-processed run: % (file: %) - % segments updated', NEW.id, NEW.filename, v_segments_updated;
  EXCEPTION WHEN OTHERS THEN
    -- Log error
    INSERT INTO runmap.processing_errors (run_id, error_type, error_message)
    VALUES (NEW.id, 'coverage_update', SQLERRM);

    NEW.processing_status = 'failed';
    RAISE NOTICE 'Coverage update error for run: % - %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$function$;

COMMENT ON TABLE runmap.processing_errors IS 'Logs errors during run processing for debugging and retry';
COMMENT ON FUNCTION runmap.retry_run_processing IS 'Retries processing for a failed run, returns success status and message';
COMMENT ON VIEW runmap.failed_runs IS 'Lists all runs that failed processing with their most recent error';
