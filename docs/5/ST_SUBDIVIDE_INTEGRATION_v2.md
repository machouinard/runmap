# ST_Subdivide Integration — v2 (Fast *and* Correct Coverage)
**Date:** 2025-10-20

This is a surgical rewrite of the original ST_Subdivide plan so it scales **and** your coverage never exceeds 100%. It keeps the speed trick (subdivide the *per‑run buffer*) and fixes the accuracy bug (double‑counting when multiple runs hit the same block).

---

## Executive summary
- Keep **`ST_Subdivide`** — but apply it to the **per‑run buffer tiles** you reuse all the time.
- Prevent >100% coverage by switching aggregation to a **segment‑visited model**:
  - Pre‑segment each block into ~5–10 m pieces **once**.
  - For each run, mark segments as *visited* if they intersect the run’s buffer tiles.
  - Coverage per block = sum(length of visited segments). No double counting, ever.
- Never `ST_Union` in the hot path. Store **one** buffered geometry per run (already dissolved), then subdivide it once and reuse.

---

## What changed from v1
- **Accuracy:** Swapped “sum of per‑run intersection lengths” (can exceed 100%) for a **binary visited** flag per small segment.
- **Subdivision target:** From “maybe subdivide blocks dynamically” → **subdivide run buffers offline** into reusable tiles (`run_buffers_subdiv`).
- **Query shape:** Add **bbox prefilter**, tile‑to‑segment intersections, and **set‑based updates** (no row loops).

---

## Data & CRS assumptions
- Street coverage units are in **EPSG:32610 (UTM Zone 10N)** as `LineString` geometries.
- Runs are stored in **EPSG:4326 (WGS84)**; per‑run buffers are stored in **32610**.
- Buffer radius defaults to **20.0 m**; tune later.

---

## Schema additions (segment model)
Add these alongside your existing `runmap` objects. This is **additive** and safe to back out.

```sql
-- 1) Pre-segmented blocks (one-time build; ~5–10 m segments)
CREATE TABLE IF NOT EXISTS runmap.block_segments AS
SELECT b.block_id,
       (d.path)[1] AS seg_idx,
       (d.geom)::geometry(LineString, 32610) AS geom_utm,
       ST_Length(d.geom) AS len_m
FROM runmap.blocks b
CROSS JOIN LATERAL ST_DumpSegments(
  ST_Segmentize(ST_LineMerge(b.geom_utm), 5.0)  -- segment target length in meters
) AS d;

ALTER TABLE runmap.block_segments ADD PRIMARY KEY (block_id, seg_idx);
CREATE INDEX IF NOT EXISTS block_segments_geom_gix ON runmap.block_segments USING gist (geom_utm);

-- 2) Visited flags (idempotent, grows only by updates)
CREATE TABLE IF NOT EXISTS runmap.block_segment_visited (
  block_id BIGINT,
  seg_idx  INT,
  visited  BOOLEAN DEFAULT FALSE,
  PRIMARY KEY (block_id, seg_idx)
);

-- Seed visited table with all segments (all start as FALSE)
INSERT INTO runmap.block_segment_visited (block_id, seg_idx)
SELECT block_id, seg_idx
FROM runmap.block_segments
ON CONFLICT DO NOTHING;
```

**Why segments?** Adding lengths across runs double‑counts the same centerline; boolean *visited* per tiny piece does not.

---

## Keep the fast stuff you already have
Make sure these exist (from the v1 playbook/migration):

```sql
-- Per-run buffer (dissolved by virtue of ST_Buffer over multilinestring)
CREATE TABLE IF NOT EXISTS runmap.run_buffers (
  run_id   BIGINT PRIMARY KEY REFERENCES runmap.runs(run_id) ON DELETE CASCADE,
  geom_utm geometry(MultiPolygon, 32610) NOT NULL,
  bbox_utm geometry(Polygon, 32610) GENERATED ALWAYS AS (ST_Envelope(geom_utm)) STORED
);
CREATE INDEX IF NOT EXISTS run_buffers_geom_gix ON runmap.run_buffers USING gist (geom_utm);
CREATE INDEX IF NOT EXISTS run_buffers_bbox_gix  ON runmap.run_buffers USING gist (bbox_utm);

-- Subdivided tiles (reusable; one-to-many per run)
CREATE TABLE IF NOT EXISTS runmap.run_buffers_subdiv (
  run_id   BIGINT NOT NULL REFERENCES runmap.runs(run_id) ON DELETE CASCADE,
  geom_utm geometry(Polygon, 32610) NOT NULL
);
CREATE INDEX IF NOT EXISTS run_buffers_subdiv_gix ON runmap.run_buffers_subdiv USING gist (geom_utm);
```

Populate once per run:

```sql
-- Ensure buffer exists
INSERT INTO runmap.run_buffers (run_id, geom_utm)
SELECT r.run_id,
       ST_Buffer(ST_Transform(r.geom_wgs84, 32610), 20.0, 'endcap=round join=round')
FROM runmap.runs r
LEFT JOIN runmap.run_buffers b USING (run_id)
WHERE b.run_id IS NULL;

-- Ensure tiles exist
INSERT INTO runmap.run_buffers_subdiv (run_id, geom_utm)
SELECT rb.run_id, ST_Subdivide(rb.geom_utm, 256)
FROM runmap.run_buffers rb
LEFT JOIN (SELECT DISTINCT run_id FROM runmap.run_buffers_subdiv) s USING (run_id)
WHERE s.run_id IS NULL;
```

---

## Per‑run processing (segments + tiles)
Replace your per‑run coverage step with this set‑based update. It marks touched segments and then updates the aggregate per block.

```sql
-- 1) Mark segments visited by this run (bbox prefilter + tiles)
WITH rb AS (
  SELECT run_id, bbox_utm FROM runmap.run_buffers WHERE run_id = $1
),
cand AS (
  SELECT s.block_id, s.seg_idx
  FROM runmap.block_segments s
  JOIN rb ON s.geom_utm && rb.bbox_utm
  JOIN runmap.run_buffers_subdiv t ON t.run_id = rb.run_id
  WHERE s.geom_utm && t.geom_utm
    AND ST_Intersects(s.geom_utm, t.geom_utm)
)
UPDATE runmap.block_segment_visited v
SET visited = TRUE
FROM cand c
WHERE v.block_id = c.block_id
  AND v.seg_idx  = c.seg_idx;

-- 2) Rebuild/refresh aggregated per-block coverage
-- Option A: on-the-fly view (no table to maintain)
--   CREATE OR REPLACE VIEW runmap.block_coverage_v AS
--   SELECT s.block_id, SUM(s.len_m) AS len_hit_m
--   FROM runmap.block_segments s
--   JOIN runmap.block_segment_visited v USING (block_id, seg_idx)
--   WHERE v.visited
--   GROUP BY s.block_id;

-- Option B: materialized (or table) for fast dashboards
INSERT INTO runmap.block_coverage (block_id, len_hit_m)
SELECT s.block_id, SUM(s.len_m)
FROM runmap.block_segments s
JOIN runmap.block_segment_visited v USING (block_id, seg_idx)
WHERE v.visited
GROUP BY s.block_id
ON CONFLICT (block_id) DO UPDATE
SET len_hit_m = EXCLUDED.len_hit_m;
```

> If you already have a `runmap.process_run()` function, clone it to `process_run_segments()` and swap the per‑run step. Keep the old path around for A/B testing.

---

## Query rewrites & anti‑patterns
- **Don’t:** `ST_Intersection(block, ST_Union(tiles))` in the hot path.  
  **Do:** intersect **segments** against **individual tiles** with bbox filters, all set‑based.
- **Don’t:** lateral‑subdivide blocks without pruning.  
  **Do:** `WHERE block && run_bbox` first, then join to tiles (already subdivided).
- **Don’t:** `ST_Buffer` in EPSG:4326.  
  **Do:** transform to **32610** → buffer once → store → subdivide once → reuse.

---

## Parameters to tune
- **Segment length:** start **5.0 m**; try 10 m for fewer rows if you’re I/O bound.
- **Tile size:** start **256**; try 128/512 and keep the fastest per your benchmark.
- **Buffer radius:** start **20.0 m**; validate visually on tricky areas (bridges, ramps).

Use your existing **Benchmark Protocol** to compare:
- segments vs. legacy per‑run intersections
- tile sizes 128/256/512
- `jit=off` vs `jit=on`

---

## Minimal unit test (correctness guardrail)
A synthetic example you can run in a scratch schema to prove “two partial runs = 100%”.

```sql
-- Scratch setup
CREATE SCHEMA IF NOT EXISTS scratch;
SET search_path = scratch, public;

CREATE TABLE blocks (block_id bigserial PRIMARY KEY, geom_utm geometry(LineString,32610));
CREATE TABLE runs (run_id bigserial PRIMARY KEY, geom_wgs84 geometry(MultiLineString,4326));
CREATE TABLE run_buffers (run_id bigint PRIMARY KEY, geom_utm geometry(MultiPolygon,32610), bbox_utm geometry(Polygon,32610));
CREATE TABLE run_tiles (run_id bigint, geom_utm geometry(Polygon,32610));
CREATE TABLE segs (block_id bigint, seg_idx int, geom_utm geometry(LineString,32610), len_m double precision, PRIMARY KEY(block_id,seg_idx));
CREATE TABLE visited (block_id bigint, seg_idx int, visited boolean default false, PRIMARY KEY(block_id,seg_idx));

-- One 100 m block (0..100 on x-axis for convenience)
INSERT INTO blocks(geom_utm)
SELECT ST_MakeLine(ST_MakePoint(0,0,32610), ST_MakePoint(100,0,32610));

-- Segmentize to 5 m pieces
INSERT INTO segs
SELECT 1, (d.path)[1], (d.geom)::geometry(LineString,32610), ST_Length(d.geom)
FROM ST_DumpSegments(ST_Segmentize((SELECT ST_LineMerge(geom_utm) FROM blocks), 5.0)) d;
INSERT INTO visited(block_id, seg_idx) SELECT block_id, seg_idx FROM segs;

-- Two runs: one covers 0..60, the other 40..100 (overlap 40..60)
-- Build runs in 4326 by inverse-transform for brevity (fake, but fine for test)
INSERT INTO runs(geom_wgs84) VALUES (
  ST_Transform(ST_MakeLine(ST_Point(0,-5,32610), ST_Point(60,-5,32610)), 4326)  -- below the line
), (
  ST_Transform(ST_MakeLine(ST_Point(40,5,32610), ST_Point(100,5,32610)), 4326)  -- above the line
);

-- Buffers + tiles
INSERT INTO run_buffers
SELECT run_id,
       ST_Buffer(ST_Transform(geom_wgs84,32610), 6.0, 'endcap=round join=round'),
       ST_Envelope(ST_Buffer(ST_Transform(geom_wgs84,32610), 6.0, 'endcap=round join=round'))
FROM runs;
INSERT INTO run_tiles
SELECT run_id, ST_Subdivide(geom_utm, 64) FROM run_buffers;

-- Process both runs: mark visited segments
WITH rb AS (SELECT 1 AS run_id, bbox_utm FROM run_buffers WHERE run_id=1),
cand AS (
  SELECT s.block_id, s.seg_idx
  FROM segs s
  JOIN rb ON s.geom_utm && rb.bbox_utm
  JOIN run_tiles t ON t.run_id = rb.run_id
  WHERE s.geom_utm && t.geom_utm AND ST_Intersects(s.geom_utm, t.geom_utm)
)
UPDATE visited v SET visited = true FROM cand c WHERE v.block_id=c.block_id AND v.seg_idx=c.seg_idx;

WITH rb AS (SELECT 2 AS run_id, bbox_utm FROM run_buffers WHERE run_id=2),
cand AS (
  SELECT s.block_id, s.seg_idx
  FROM segs s
  JOIN rb ON s.geom_utm && rb.bbox_utm
  JOIN run_tiles t ON t.run_id = rb.run_id
  WHERE s.geom_utm && t.geom_utm AND ST_Intersects(s.geom_utm, t.geom_utm)
)
UPDATE visited v SET visited = true FROM cand c WHERE v.block_id=c.block_id AND v.seg_idx=c.seg_idx;

-- Assert: 100% coverage (no double counting)
SELECT
  SUM(CASE WHEN visited THEN len_m ELSE 0 END) / SUM(len_m) * 100 AS pct
FROM segs JOIN visited USING (block_id,seg_idx);
```

Expected result: **100%**. If this ever returns >100% or <100% in this toy case, something regressed.

---

## Rollout plan
1. Build `block_segments` + `block_segment_visited` and index them.
2. Ensure `run_buffers` and `run_buffers_subdiv` are populated for all existing runs.
3. Switch the per‑run pipeline to **mark segments visited** (snippet above).
4. Update your dashboard to read from either `block_coverage_v` (view) or refresh a materialized/table aggregate.
5. Benchmark with your existing protocol; tune segment length and tile size.
6. Once stable, retire the additive per‑run length aggregator.

---

## Appendix: functionized per‑run path
If you prefer functions, mirror your existing style:

```sql
CREATE OR REPLACE FUNCTION runmap.process_run_segments(p_run_id BIGINT)
RETURNS VOID
LANGUAGE sql AS $$
  WITH rb AS (
    SELECT run_id, bbox_utm FROM runmap.run_buffers WHERE run_id = p_run_id
  ),
  cand AS (
    SELECT s.block_id, s.seg_idx
    FROM runmap.block_segments s
    JOIN rb ON s.geom_utm && rb.bbox_utm
    JOIN runmap.run_buffers_subdiv t ON t.run_id = rb.run_id
    WHERE s.geom_utm && t.geom_utm AND ST_Intersects(s.geom_utm, t.geom_utm)
  )
  UPDATE runmap.block_segment_visited v
  SET visited = TRUE
  FROM cand c
  WHERE v.block_id = c.block_id AND v.seg_idx = c.seg_idx;
$$;
```

Call `runmap.process_run_segments(run_id)` after you ensure the buffer + tiles exist for that run.

---

### Final note
You can keep your old per‑run length tables for auditing, but the source of truth for “what % of a block is covered” should be **segment‑visited**. It scales, it’s simple, and it can’t overcount.
