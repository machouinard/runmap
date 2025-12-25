# RunMap Coverage Performance Playbook (PostGIS)
**Date:** 2025-10-20

This is a blunt, practical plan to speed up coverage processing after bulk GPX imports. It’s opinionated on purpose. Use it as the living reference in your library—update it as we test and tune.

---

## TL;DR (what to do first)
1. **Stop reprocessing everything.** Switch to *incremental* per-run updates + periodic consolidation.
2. **Precompute & store per-run buffers in meters** (UTM). Index them. Don’t re-create buffers every join.
3. **Intersect blocks with *subdivided* run buffers** (use `ST_Subdivide`) to avoid pathological intersections.
4. **Always work in projected CRS (meters)** for spatial ops. Sacramento → EPSG:32610 (UTM zone 10N). Transform back only at the edges.
5. **Put the right indexes in place** (GiST on geometry, composite btree on foreign keys). Analyze frequently.
6. **Use UNLOGGED staging tables + COPY** for bulk import. Refresh materialized views *concurrently* and only when needed.
7. **Measure with `EXPLAIN (ANALYZE, BUFFERS)`** and keep results in a tuning log table after each change.

You’ll get the biggest wins from (2), (3), and (5) right away.

---

## Context & Symptoms
- Bulk import of ~600 GPX routes. At ~97 runs → ~10s each; 191 → ~18s; 205 → ~33s. Time per run rises as batch grows, which screams **N×M growth** in intersections and/or poor caching/indices.
- Coverage is computed by buffering GPX lines and intersecting with *blocks* (not raw OSM ways). Correct, but costly if the buffer/union is re-built every time or if blocks are intersecting huge, complex multipolygons.
- Some docs note past geometry accumulation bugs have been fixed—good. Now it’s about **query shape** and **data layout**.

**Likely bottlenecks** (ranked):
1. Recomputing `ST_Buffer(ST_Transform(...))` repeatedly in queries.
2. Intersecting complex, unioned geometries (e.g., `ST_UnaryUnion` of many segments) with large block sets.
3. Doing precise intersections without **subdivision** (PostGIS must traverse huge polygons/linestrings).
4. Running spatial ops in EPSG:4326 (degrees) instead of meters.
5. Missing or misaligned indexes and join keys.
6. Full reprocessing instead of delta updates.

---

## Data Model: recommended tables
These keep processing simple and fast.

```sql
-- Raw imported GPX as lines (one row per run)
CREATE TABLE runmap.runs (
  run_id       bigserial PRIMARY KEY,
  started_at   timestamptz,
  ended_at     timestamptz,
  geom_wgs84   geometry(MultiLineString, 4326) NOT NULL
);

-- Precomputed per-run buffer in meters (projected CRS)
-- Store both the UTM buffer (for fast intersects) and a bbox for cheap pruning.
CREATE TABLE runmap.run_buffers (
  run_id     bigint PRIMARY KEY REFERENCES runmap.runs(run_id) ON DELETE CASCADE,
  geom_utm   geometry(MultiPolygon, 32610) NOT NULL,
  bbox_utm   geometry(Polygon, 32610) GENERATED ALWAYS AS (ST_Envelope(geom_utm)) STORED
);

-- Street blocks as segments (the coverage unit)
CREATE TABLE runmap.blocks (
  block_id     bigserial PRIMARY KEY,
  geom_utm     geometry(LineString, 32610) NOT NULL,
  len_m        double precision GENERATED ALWAYS AS (ST_Length(geom_utm)) STORED
);

-- Incremental per-run coverage results (intersection length by run & block)
CREATE TABLE runmap.block_coverage_runs (
  run_id       bigint NOT NULL REFERENCES runmap.runs(run_id) ON DELETE CASCADE,
  block_id     bigint NOT NULL REFERENCES runmap.blocks(block_id) ON DELETE CASCADE,
  len_hit_m    double precision NOT NULL,
  PRIMARY KEY (run_id, block_id)
);

-- Aggregated coverage per block (fast to query)
CREATE TABLE runmap.block_coverage (
  block_id     bigint PRIMARY KEY REFERENCES runmap.blocks(block_id) ON DELETE CASCADE,
  len_hit_m    double precision NOT NULL DEFAULT 0,
  pct          double precision GENERATED ALWAYS AS (CASE WHEN len_m > 0 THEN 100.0 * len_hit_m / len_m ELSE 0 END) STORED
);
```

**Why this layout?**
- Buffers are **materialized once per run** in UTM → no repeated expensive buffers.
- Intersections are **incremental**: new runs add rows in `block_coverage_runs`; a lightweight aggregation keeps `block_coverage` in sync.
- Blocks are lines with precomputed length so `%` is just division, not another geometry call.

---

## Indexes you actually need
```sql
-- Geometry
CREATE INDEX ON runmap.run_buffers USING gist (geom_utm);
CREATE INDEX ON runmap.run_buffers USING gist (bbox_utm);

CREATE INDEX ON runmap.blocks USING gist (geom_utm);

-- Foreign-key helpers
CREATE INDEX ON runmap.block_coverage_runs (block_id);
CREATE INDEX ON runmap.block_coverage_runs (run_id);

-- If you frequently filter by time
CREATE INDEX ON runmap.runs (started_at);
```

Pro tip: after bulk load or big updates, run `ANALYZE runmap.*;` (or `VACUUM ANALYZE`) so the planner stops guessing.

---

## Import & preprocessing
Use UNLOGGED staging and `COPY` for speed; then transform once.

```sql
-- 1) Staging for raw GPX
CREATE UNLOGGED TABLE staging.gpx_runs (..., geom_wgs84 geometry(MultiLineString,4326));

-- 2) Ingest → main
INSERT INTO runmap.runs (started_at, ended_at, geom_wgs84)
SELECT started_at, ended_at, ST_LineMerge(geom_wgs84)  -- cheap clean-up
FROM staging.gpx_runs;

-- 3) Precompute buffers in meters once
INSERT INTO runmap.run_buffers (run_id, geom_utm)
SELECT r.run_id,
       ST_Buffer(
         ST_Transform(r.geom_wgs84, 32610),
         20.0, -- your chosen tolerance in meters; tune later
         'endcap=round join=round'
       )
FROM runmap.runs r
LEFT JOIN runmap.run_buffers b USING (run_id)
WHERE b.run_id IS NULL;
```

**Optional geometry diet before buffering:**
If GPX lines are super noisy, do a tolerant simplify **in UTM** right before buffering. Keep it conservative.

```sql
-- Simplify just enough to kill GPS wiggle, not topology.
UPDATE runmap.runs r SET geom_wgs84 =
  ST_Transform(
    ST_SimplifyPreserveTopology(
      ST_Transform(geom_wgs84, 32610),
      1.0  -- meters; start small, validate visually
    ),
    4326
  )
WHERE r.run_id IN (...recent batch...);
```

---

## The intersection pattern (fast & safe)
Avoid giant polygons/lines going head-to-head. **Subdivide** first and use bbox pruning.

```sql
-- Best practice: pre-subdivide run buffers
CREATE TABLE IF NOT EXISTS runmap.run_buffers_subdiv AS
SELECT run_id, ST_Subdivide(geom_utm, 256) AS geom_utm
FROM runmap.run_buffers
WHERE false;  -- structure only

-- Maintain incrementally
INSERT INTO runmap.run_buffers_subdiv (run_id, geom_utm)
SELECT run_id, ST_Subdivide(geom_utm, 256)
FROM runmap.run_buffers rb
LEFT JOIN runmap.run_buffers_subdiv s USING (run_id)
WHERE s.run_id IS NULL;

CREATE INDEX ON runmap.run_buffers_subdiv USING gist (geom_utm);

-- Compute per-run coverage quickly
WITH cand_blocks AS (
  SELECT b.block_id, b.geom_utm
  FROM runmap.blocks b
  JOIN runmap.run_buffers rb ON rb.run_id = $1
  WHERE b.geom_utm && rb.bbox_utm   -- cheap bbox filter
),
hits AS (
  SELECT c.block_id,
         SUM(ST_Length(ST_Intersection(c.geom_utm, s.geom_utm))) AS len_hit_m
  FROM cand_blocks c
  JOIN runmap.run_buffers_subdiv s ON s.run_id = $1
  WHERE c.geom_utm && s.geom_utm
  GROUP BY c.block_id
)
INSERT INTO runmap.block_coverage_runs (run_id, block_id, len_hit_m)
SELECT $1 AS run_id, block_id, GREATEST(0.0, LEAST(len_hit_m, 1e9))  -- guardrails
FROM hits
ON CONFLICT (run_id, block_id) DO UPDATE
SET len_hit_m = EXCLUDED.len_hit_m;
```

**Why `ST_Subdivide`?** It cuts complex geometries into tiles so each intersection runs on tiny pieces, reducing CPU and memory blow-ups.

---

## Keeping the aggregate fresh (cheap)
Update the aggregate table right after a run is processed. No full recompute.

```sql
-- Upsert into aggregated coverage
INSERT INTO runmap.block_coverage (block_id, len_hit_m)
SELECT block_id, SUM(len_hit_m)
FROM runmap.block_coverage_runs
WHERE run_id = $1
GROUP BY block_id
ON CONFLICT (block_id) DO UPDATE
SET len_hit_m = runmap.block_coverage.len_hit_m + EXCLUDED.len_hit_m;
```

If you ever need to rebuild the aggregate from scratch (rare), it’s still just one grouped scan of `block_coverage_runs`.

---

## Materialized views (only where they help)
Use materialized views for **read-heavy** dashboards; refresh **concurrently** and on a schedule.

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS runmap.coverage_stats_mv AS
SELECT
  COUNT(*) AS blocks_total,
  COUNT(*) FILTER (WHERE pct >= 100) AS blocks_complete,
  AVG(pct) AS avg_pct
FROM runmap.block_coverage
WITH NO DATA;

CREATE INDEX IF NOT EXISTS coverage_stats_mv_pct_idx ON runmap.block_coverage(pct);

-- Later, refresh without blocking readers:
REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_stats_mv;
```

---

## Server/session settings that matter
For the heavy jobs session (don’t blanket-change cluster defaults until measured):

```sql
-- Per-session before the batch job:
SET work_mem = '512MB';            -- gives room for spatial joins/sorts (tune)
SET maintenance_work_mem = '1GB';  -- for index builds / refreshes
SET max_parallel_workers_per_gather = 4;
SET jit = off;                     -- JIT often hurts complex spatial queries
```

System-level basics (check `postgresql.conf`):
- `shared_buffers` ≈ 25% RAM (on a dedicated box)
- `effective_cache_size` ≈ 50–75% RAM
- `max_wal_size` reasonably high if you do big batches
- Use SSDs (NVMe ideal). Spatial ops love fast I/O.

---

## Test harness & tuning loop
Never guess twice—measure once and write it down.

```sql
-- Minimal timing log
CREATE TABLE IF NOT EXISTS runmap.tuning_log (
  logged_at   timestamptz DEFAULT now(),
  action      text,
  run_count   int,
  seconds     numeric,
  notes       text
);
```

Workflow:
1. `EXPLAIN (ANALYZE, BUFFERS)` the intersection CTE above for **one run** with ~N blocks in the bbox.
2. Record timings before/after: (a) storing buffers, (b) adding `ST_Subdivide`, (c) indexes on subdivided buffers, (d) turning JIT off.
3. Keep the best plan; revert the rest.

Sanity checks:
- Are we always transforming to EPSG:32610 before buffer/intersection/length?
- Is time per run roughly **flat** as dataset grows? If it climbs, you’re re-touching old runs or blowing caches.

---

## Guardrails & footguns (learned the hard way)
- Don’t `ST_Buffer` in 4326. Degrees aren’t meters.
- Don’t `ST_UnaryUnion` thousands of lines unless you absolutely need to. If you *must* merge, `ST_Collect` → `ST_LineMerge` is cheaper for lines.
- Don’t intersect massive multipolygons with long lines without `ST_Subdivide`.
- Don’t rebuild buffers each time you query coverage.
- Don’t forget `ANALYZE` after large batch loads.
- Do batch inserts/updates; avoid row-by-row loops in PL/pgSQL when a single SQL statement will do.

---

## Optional: Map-matching lite (if your GPS is noisy)
If you see a lot of near-misses, snap GPX to centerlines when within a tolerance before buffering:

```sql
-- Example: snap runs to blocks within 15 m to reduce “miss” gaps
UPDATE runmap.runs r SET geom_wgs84 =
  ST_Transform(
    ST_Snap(
      ST_Transform(r.geom_wgs84, 32610),
      ST_Collect(b.geom_utm),  -- small bbox subset!
      15.0
    ), 4326)
WHERE r.run_id = $1;
```

**Caution:** Snap only within a small bbox around the run; never collect the whole city at once.

---

## Rollout plan (incremental & safe)
1. Create the new tables and indexes alongside current ones.
2. Backfill `run_buffers` and `run_buffers_subdiv` for a **small batch** (e.g., 25 runs). Measure.
3. Switch the coverage job to the **per-run** intersection/insert described above.
4. Build the aggregate `block_coverage` off `block_coverage_runs`, validate against today’s numbers.
5. Flip dashboards to read from the new aggregate/materialized view; monitor timings for the next 100 runs.
6. Delete any now-redundant unioned/intermediate geometry tables after a week of clean runs.

---

## What to tune next (once the basics land)
- Buffer distance (start at 20 m, verify visually on a few tricky blocks).
- `ST_Subdivide` tile size (128–512 are typical sweet spots).
- Simplification tolerance (0.5–2.0 m depending on GPS jitter).
- Parallelism and `work_mem` ceilings on your box.

---

## Open questions for our future-selves
- Do we want **time-weighted coverage** (e.g., more credit for slower segments)?
- Should we consider **blocks vs. centerlines** for “what counts as covered” in cul-de-sacs/alleys?
- Would a **roaring bitmap** of run IDs per block (via extension) make certain stats instant, or is the current aggregate enough?

---

## Done right, you should see
- Flat(ish) per-run processing time as the library grows.
- No more multi-minute re-builds for routine imports.
- Simple, inspectable SQL without magical side-effects.

Ship this, then we can get fancy.
