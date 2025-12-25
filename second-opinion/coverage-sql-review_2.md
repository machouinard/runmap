# Coverage System SQL Review & Fixes

## Issues Found & Fixed ✅

### 1. Data Type Mismatch - FIXED

**Your schemas:**
- `runs_raw`: `id uuid` ✅
- `runs_buffered_32610`: `run_id uuid` ✅

**Original SQL file had:** `run_id bigint` ❌

**Fix:** Changed all function parameters to `uuid`

---

### 2. Column Name Mismatch - FIXED

**Your `runs_raw` table:**
```sql
id uuid PRIMARY KEY  -- Not 'gid'
```

**Original SQL had:** `WHERE r.gid = p_run_id` ❌

**Fix:** Changed to `WHERE r.id = p_run_id`

### 3. Settings Table - CREATE IT

The `buffer_one_run` function references `runmap.settings` which doesn't exist yet.

**Solution:** Create it with default buffer distance

---

## Fixed SQL Script

```sql
-- ============================================================================
-- Incremental Coverage System - Functions and Views
-- Uses existing tables: runs_raw, streets_reference_32610, etc.
-- ============================================================================

-- 1. Create settings table
CREATE TABLE IF NOT EXISTS runmap.settings (
  key text PRIMARY KEY,
  value text NOT NULL
);

INSERT INTO runmap.settings (key, value) 
VALUES ('buffer_distance_m', '15') 
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 2. Function to buffer one run
-- ============================================================================
CREATE OR REPLACE FUNCTION runmap.buffer_one_run(p_run_id uuid) 
RETURNS void AS $
DECLARE
  buf_m numeric := (SELECT (value::text)::numeric FROM runmap.settings WHERE key = 'buffer_distance_m');
BEGIN
  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  SELECT
    r.id AS run_id,  -- runs_raw.id is UUID
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
  WHERE r.id = p_run_id
  ON CONFLICT (run_id) DO UPDATE
  SET geom = EXCLUDED.geom;
END;
$ LANGUAGE plpgsql;

-- ============================================================================
-- 3. Function to incrementally update coverage for one run
-- ============================================================================
CREATE OR REPLACE FUNCTION runmap.apply_run_to_coverage(p_run_id uuid) 
RETURNS void AS $$
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

-- ============================================================================
-- 4. Drop old views
-- ============================================================================
DROP MATERIALIZED VIEW IF EXISTS runmap.coverage_stats CASCADE;
DROP VIEW IF EXISTS runmap.streets_unrun CASCADE;
DROP VIEW IF EXISTS runmap.coverage_buffer CASCADE;

-- ============================================================================
-- 5. Coverage statistics (materialized for performance)
-- ============================================================================
CREATE MATERIALIZED VIEW runmap.coverage_stats AS
SELECT
  1 AS id,
  SUM(covered_length_m) AS covered_m,
  SUM(total_length_m) AS total_m,
  ROUND((SUM(covered_length_m) / NULLIF(SUM(total_length_m),0) * 100)::numeric, 2) AS coverage_pct
FROM runmap.street_coverage_32610;

CREATE UNIQUE INDEX coverage_stats_id_uidx ON runmap.coverage_stats(id);

COMMENT ON MATERIALIZED VIEW runmap.coverage_stats IS 'Overall coverage statistics - refresh after processing runs';

-- ============================================================================
-- 6. Unrun streets view (for gap analysis)
-- ============================================================================
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

COMMENT ON VIEW runmap.streets_unrun IS 'Streets with zero coverage - for tile export and gap analysis';

-- ============================================================================
-- 7. Coverage buffer view (for visualization)
-- ============================================================================
CREATE VIEW runmap.coverage_buffer AS
SELECT
  run_id::text AS gid,
  ST_Transform(geom, 4326)::geometry(MultiPolygon, 4326) AS geom
FROM runmap.runs_buffered_32610;

COMMENT ON VIEW runmap.coverage_buffer IS 'Per-run coverage buffers in WGS84 - overlaps are handled by tiler';

-- ============================================================================
-- Comments for documentation
-- ============================================================================
COMMENT ON FUNCTION runmap.buffer_one_run IS 'Buffer a single run and store in runs_buffered_32610';
COMMENT ON FUNCTION runmap.apply_run_to_coverage IS 'Incrementally update coverage for streets touched by one run';
```

---

## Ready to Run ✅

All table/column references are now correct for your schema:
- `runs_raw.id` (UUID) ✅
- `runs_raw.geom` (MultiLineString, 4326) ✅
- `runs_buffered_32610.run_id` (UUID) ✅

### Execute the SQL

```bash
psql -U runmap_user -d runmap -h localhost < 03_incremental_coverage_fixed.sql
```

### Verify Setup

```sql
-- Check all tables exist
SELECT tablename FROM pg_tables 
WHERE schemaname = 'runmap' 
AND tablename IN (
  'runs_raw',
  'streets_reference_32610', 
  'runs_buffered_32610', 
  'street_coverage_32610',
  'settings'
);

-- Check views created
SELECT viewname FROM pg_views 
WHERE schemaname = 'runmap'
AND viewname IN ('streets_unrun', 'coverage_buffer');

-- Check materialized view
SELECT matviewname FROM pg_matviews
WHERE schemaname = 'runmap'
AND matviewname = 'coverage_stats';

-- Check initial state (should be 0% coverage)
SELECT * FROM runmap.coverage_stats;
```

---

## Typical Workflow After Setup

### Manual Test (Single Run)

```sql
-- 1. Check if any runs imported
SELECT id, filename, start_time, distance_km 
FROM runmap.runs_raw 
ORDER BY uploaded_at DESC 
LIMIT 5;

-- 2. Buffer a specific run
SELECT runmap.buffer_one_run('paste-uuid-here');

-- 3. Apply coverage for that run
SELECT runmap.apply_run_to_coverage('paste-uuid-here');

-- 4. Refresh stats
REFRESH MATERIALIZED VIEW runmap.coverage_stats;

-- 5. Check progress
SELECT 
  ROUND((covered_m / 1000)::numeric, 2) as covered_km,
  ROUND((total_m / 1000)::numeric, 2) as total_km,
  coverage_pct
FROM runmap.coverage_stats;

-- 6. See unrun streets count
SELECT COUNT(*) FROM runmap.streets_unrun;
```

### Integration with GPX Parser

Your Python GPX parser (from document 1) inserts into a different schema. You'll need to either:

**Option A: Modify parser to insert into `runs_raw`**
```python
# In GPXParser.insert_run() method
insert_sql = """
    INSERT INTO runmap.runs_raw (
        filename, start_time, duration_seconds, 
        distance_km, geom, content_hash, metadata
    ) VALUES (
        %s, %s, %s, %s, ST_GeomFromText(%s, 4326), %s, %s
    ) RETURNING id
"""
```

**Option B: Call coverage functions after GPX import**
```python
# After successful import
def process_run_coverage(self, run_id):
    """Buffer and apply coverage for newly imported run"""
    try:
        with psycopg2.connect(**self.db_config) as conn:
            with conn.cursor() as cursor:
                # Buffer the run
                cursor.execute("SELECT runmap.buffer_one_run(%s)", (run_id,))
                
                # Apply to coverage
                cursor.execute("SELECT runmap.apply_run_to_coverage(%s)", (run_id,))
                
                # Refresh stats
                cursor.execute("REFRESH MATERIALIZED VIEW runmap.coverage_stats")
                
                conn.commit()
                print(f"  ✅ Coverage updated for run {run_id}")
    except Exception as e:
        print(f"  ❌ Coverage update failed: {e}")
```

---

## Export Tiles

After importing runs and updating coverage:

```bash
# Your existing script should now work
./scripts/export_tiles_incremental.sh

# Tiles generated:
# - runs.pmtiles (from runs_raw)
# - coverage.pmtiles (from coverage_buffer view)
# - unrun.pmtiles (from streets_unrun view)
```

---

## Next Steps

1. **Run the fixed SQL script** to create functions and views
2. **Test with existing runs** (if you have any in `runs_raw`)
3. **Integrate with GPX parser** to auto-call coverage functions
4. **Verify tile export** works with the views

### Quick Test Commands

```bash
# 1. Create functions/views
psql -U runmap_user -d runmap -h localhost < 03_incremental_coverage_fixed.sql

# 2. Check if you have runs to test with
psql -U runmap_user -d runmap -h localhost -c "SELECT COUNT(*) FROM runmap.runs_raw;"

# 3. Export tiles (should work even with 0 runs)
./scripts/export_tiles_incremental.sh
```

The system is ready! 🎉