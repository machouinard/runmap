# Coverage System SQL Review & Fixes

## Critical Issues to Fix ⚠️

### 1. Data Type Mismatch 🚨

**Your actual schema** (`runs_buffered_32610.sql`):
```sql
run_id uuid NOT NULL
```

**This SQL file** (`03_incremental_coverage.sql`):
```sql
run_id bigint PRIMARY KEY
```

**This will break everything.** You need consistent data types.

#### Option A: Use UUID everywhere (Recommended)
```sql
-- Change all bigint to uuid
CREATE TABLE IF NOT EXISTS runmap.runs_buffered_32610 (
  run_id uuid PRIMARY KEY,  -- Not bigint
  geom geometry(MultiPolygon, 32610) NOT NULL
);

CREATE OR REPLACE FUNCTION runmap.buffer_one_run(p_run_id uuid) -- Not bigint

CREATE OR REPLACE FUNCTION runmap.apply_run_to_coverage(p_run_id uuid) -- Not bigint
```

#### Option B: Use bigint everywhere
Drop and recreate `runs_buffered_32610` with bigint. But UUID is better for distributed systems.

---

### 2. Missing Tables Referenced

#### `runmap.runs_raw` - Does this exist?
```sql
-- Line 58 in buffer_one_run
FROM runmap.runs_raw r
WHERE r.gid = p_run_id
```

**Should probably be:**
```sql
FROM runmap.runs r
WHERE r.id = p_run_id  -- Assuming runs table has 'id' column
```

#### `runmap.settings` - Does this exist?
```sql
-- Line 52
SELECT (value::text)::numeric FROM runmap.settings WHERE key = 'buffer_distance_m'
```

**Fix Options:**

**Option 1: Create settings table**
```sql
CREATE TABLE IF NOT EXISTS runmap.settings (
  key text PRIMARY KEY,
  value text NOT NULL
);
INSERT INTO runmap.settings (key, value) 
VALUES ('buffer_distance_m', '15') 
ON CONFLICT DO NOTHING;
```

**Option 2: Hardcode**
```sql
DECLARE
  buf_m numeric := 15.0;  -- Hardcoded buffer distance
```

---

### 3. Table Creation Conflicts

Your file has `CREATE TABLE IF NOT EXISTS` but tables already exist with different schemas.

**Option A: Skip table creation** (recommended)
```sql
-- Comment out CREATE TABLE statements since tables exist
-- CREATE TABLE IF NOT EXISTS runmap.streets_reference_32610 AS ...
-- CREATE TABLE IF NOT EXISTS runmap.runs_buffered_32610 ...
-- CREATE TABLE IF NOT EXISTS runmap.street_coverage_32610 ...
```

**Option B: Use DROP/CREATE** (only if starting fresh)
```sql
DROP TABLE IF EXISTS runmap.runs_buffered_32610 CASCADE;
CREATE TABLE runmap.runs_buffered_32610 (
  run_id uuid PRIMARY KEY,  -- Fix data type
  geom geometry(MultiPolygon, 32610) NOT NULL
);
```

---

## Fixed SQL Script

```sql
-- ============================================================================
-- Incremental Coverage System - Functions and Views Only
-- Tables already exist, this creates the processing logic
-- ============================================================================

-- 1. Create settings table if needed
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
RETURNS void AS $$
DECLARE
  buf_m numeric;
BEGIN
  -- Get buffer distance from settings (or use default)
  SELECT COALESCE((value::text)::numeric, 15.0) 
  INTO buf_m
  FROM runmap.settings 
  WHERE key = 'buffer_distance_m';
  
  -- If settings table doesn't have the value, use default
  IF buf_m IS NULL THEN
    buf_m := 15.0;
  END IF;

  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  SELECT
    r.id AS run_id,  -- VERIFY: Adjust column name to match your runs table
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
  FROM runmap.runs r  -- VERIFY: Changed from runs_raw
  WHERE r.id = p_run_id  -- VERIFY: Changed from gid
  ON CONFLICT (run_id) DO UPDATE
  SET geom = EXCLUDED.geom;
END;
$$ LANGUAGE plpgsql;

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

## Action Items Before Running

### 1. Check your `runs` table schema
```sql
\d runmap.runs
```

**Questions:**
- What's the primary key column name? (`id`, `gid`, `run_id`?)
- Is it UUID or bigint?
- Does the table exist or is it called `runs_raw`?

### 2. Update the `buffer_one_run` function

Based on your `runs` table, adjust these lines:
```sql
FROM runmap.runs r  -- Correct table name
WHERE r.id = p_run_id  -- Correct column name
```

### 3. Test the workflow

```sql
-- Verify all tables exist
SELECT tablename FROM pg_tables 
WHERE schemaname = 'runmap' 
AND tablename IN (
  'runs', 
  'streets_reference_32610', 
  'runs_buffered_32610', 
  'street_coverage_32610'
);

-- Verify views created
SELECT viewname FROM pg_views 
WHERE schemaname = 'runmap';

-- Check initial state (should be 0% coverage)
SELECT * FROM runmap.coverage_stats;
```

---

## Typical Workflow After Setup

```sql
-- 1. Import a GPX run (creates row in runmap.runs with UUID)
-- Your Python GPX parser does this

-- 2. Buffer the run
SELECT runmap.buffer_one_run('uuid-of-run-here');

-- 3. Apply coverage
SELECT runmap.apply_run_to_coverage('uuid-of-run-here');

-- 4. Refresh stats
REFRESH MATERIALIZED VIEW runmap.coverage_stats;

-- 5. Check progress
SELECT 
  covered_m / 1000 as covered_km,
  total_m / 1000 as total_km,
  coverage_pct
FROM runmap.coverage_stats;
```

---

## Next Steps

1. **Share your `runs` table schema** so I can verify the column references
2. **Run the fixed SQL** after adjusting table/column names
3. **Test with one run** to verify the coverage update logic works
4. **Integrate with your GPX parser** to auto-call functions on upload