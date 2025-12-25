# PostGIS Performance Optimization Notes

This document summarizes the key strategies, rewrites, and optimizations developed to handle performance degradation while processing hundreds of GPX route geometries in PostgreSQL + PostGIS. The goal: scale to 600+ runs while keeping per-run processing times consistent.

---

## 1. Avoid Unioning Large Polygons
Union cost grows superlinearly with geometry size. Instead, **clip first, union second**, using `ST_UnaryUnion(ST_Collect(...))` instead of `ST_Union`.

```sql
WITH touched_blocks AS (
  SELECT DISTINCT b.block_id, b.geom_32610 AS block_geom
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.runs_buffered_32610 rb
    ON rb.run_id = $1
   AND rb.geom && b.geom_32610
   AND ST_Intersects(rb.geom, b.geom_32610)
),
per_block AS (
  SELECT
    tb.block_id,
    ST_Length(
      ST_Intersection(
        tb.block_geom,
        ST_UnaryUnion(
          ST_Collect(
            ST_Intersection(rb.geom, tb.block_geom)
          )
        )
      )
    ) AS covered_len
  FROM touched_blocks tb
  JOIN LATERAL (
    SELECT rb.geom
    FROM runmap.runs_buffered_32610 rb
    WHERE rb.geom && tb.block_geom
  ) rb ON TRUE
  GROUP BY tb.block_id, tb.block_geom
)
INSERT INTO runmap.block_coverage_32610 (block_id, covered_length_m, total_length_m, covered_geom)
SELECT
  b.block_id,
  p.covered_len,
  ST_Length(b.geom_32610) AS total_len,
  NULL::geometry
FROM runmap.streets_blocks_32610 b
JOIN per_block p USING (block_id)
ON CONFLICT (block_id) DO UPDATE
SET covered_length_m = EXCLUDED.covered_length_m,
    total_length_m   = EXCLUDED.total_length_m;
```

This unions small clipped pieces per block instead of the entire buffer, dramatically lowering vertex counts.

---

## 2. Use Cheaper Buffers

Reduce buffer complexity before any union:

```sql
ST_Buffer(line_32610, 15,
  'endcap=flat join=mitre mitre_limit=2.0 quad_segs=4')
```

Optionally snap to grid to simplify geometries:

```sql
ST_SnapToGrid(ST_Buffer(...), 0.5)
```

---

## 3. Spatial Indexes and Query Planning

```sql
CREATE INDEX IF NOT EXISTS runs_buffered_32610_gix
  ON runmap.runs_buffered_32610 USING GIST (geom);
CREATE INDEX IF NOT EXISTS streets_blocks_32610_gix
  ON runmap.streets_blocks_32610 USING GIST (geom_32610);
CREATE INDEX IF NOT EXISTS block_run_coverage_block_id_run_id_idx
  ON runmap.block_run_coverage (block_id, run_id);
CREATE INDEX IF NOT EXISTS block_run_coverage_run_id_block_id_idx
  ON runmap.block_run_coverage (run_id, block_id);
ANALYZE runmap.runs_buffered_32610;
ANALYZE runmap.block_run_coverage;
```

Always use `&&` or `ST_Intersects` first in joins to trigger the GiST index.

---

## 4. Limit the Working Set

Process data in smaller spatial batches:
- Group by **tiles** (e.g., 1×1 km).
- Restrict runs to their **MBR** (minimum bounding rectangle).

---

## 5. Switch to Interval-Based Coverage (Future Refactor)

Convert block coverage to 1-D linear referencing intervals instead of geometric unions:

```sql
WITH clip AS (
  SELECT ST_Intersection(b.geom_32610, rb.geom) AS segs
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.runs_buffered_32610 rb ON ...
  WHERE b.block_id = $block AND rb.run_id = $run
),
parts AS (
  SELECT (ST_Dump(ST_LineMerge(clip.segs))).geom AS seg
  FROM clip
),
ranges AS (
  SELECT
    numrange(
      ST_LineLocatePoint(b.geom_32610, ST_StartPoint(seg)),
      ST_LineLocatePoint(b.geom_32610, ST_EndPoint(seg))
    ) AS r
  FROM parts, runmap.streets_blocks_32610 b
  WHERE b.block_id = $block
)
INSERT INTO runmap.block_run_intervals (block_id, run_id, interval)
SELECT $block, $run, r FROM ranges;
```

Then coverage = sum of merged interval widths × block length.

---

## 6. PostgreSQL Session Settings

```sql
SET LOCAL work_mem = '256MB';
SET LOCAL maintenance_work_mem = '1GB';
SET LOCAL temp_buffers = '256MB';
SET LOCAL jit = off;
SET LOCAL synchronous_commit = off;
```

Use `UNLOGGED` tables for staging geometry data to reduce WAL overhead.

---

## 7. Table Partitioning

- **`runs_buffered_32610`** → partition by import batch or month.
- **`block_run_coverage`** → hash-partition by `block_id`.

---

## 8. Instrumentation and Early Exits

Pre-filter using envelopes:

```sql
WHERE rb.geom && b.geom_32610
  AND ST_Area(ST_Intersection(ST_Envelope(rb.geom), ST_Envelope(b.geom_32610))) > 0
```

Monitor geometry complexity:

```sql
SELECT run_id, ST_NPoints(geom) AS buf_pts
FROM runmap.runs_buffered_32610
ORDER BY buf_pts DESC LIMIT 5;
```

---

## 9. Batch Processing Strategy

1. Order runs spatially (by tile or proximity).
2. For each run, find touched blocks and process only those.
3. `VACUUM` and `ANALYZE` regularly on frequently updated tables.

---

## TL;DR

Immediate wins (no schema change):
1. Clip before unary union (`ST_Intersection → ST_UnaryUnion`).
2. Simplify buffers (`quad_segs`, `SnapToGrid`).
3. Tune per-session settings.

Long-term refactor: replace polygon unions with 1-D interval math.

---

**Author:** ChatGPT (PostGIS Expert Tutor)  
**Date:** 2025-10-20
