# RunMap Coverage – Benchmark Protocol
**Date:** 2025-10-20

This protocol makes performance measurable and repeatable. Paste results into the `runmap.tuning_log` table after every change.

---

## 0) Setup
```sql
SET jit = off;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
ANALYZE runmap.runs;
ANALYZE runmap.blocks;
ANALYZE runmap.run_buffers;
ANALYZE runmap.run_buffers_subdiv;
```

Pick **one run_id** that hits a decent number of blocks (100–1,000). Replace `:run_id` below.

---

## 1) Baseline: intersection with subdivided buffers
```sql
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING)
WITH cand_blocks AS (
  SELECT b.block_id, b.geom_utm
  FROM runmap.blocks b
  JOIN runmap.run_buffers rb ON rb.run_id = :run_id
  WHERE b.geom_utm && rb.bbox_utm
),
hits AS (
  SELECT c.block_id,
         SUM(ST_Length(ST_Intersection(c.geom_utm, s.geom_utm))) AS len_hit_m
  FROM cand_blocks c
  JOIN runmap.run_buffers_subdiv s ON s.run_id = :run_id
  WHERE c.geom_utm && s.geom_utm
  GROUP BY c.block_id
)
SELECT COUNT(*), COALESCE(SUM(len_hit_m),0) FROM hits;
```

Record:
- Total runtime (ms)
- Shared/Hits/Reads in BUFFERS
- Rows in `hits`

---

## 2) Compare: without `ST_Subdivide` (expect slower)
```sql
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING)
WITH cand_blocks AS (
  SELECT b.block_id, b.geom_utm
  FROM runmap.blocks b
  JOIN runmap.run_buffers rb ON rb.run_id = :run_id
  WHERE b.geom_utm && rb.bbox_utm
)
SELECT COUNT(*), COALESCE(SUM(ST_Length(ST_Intersection(c.geom_utm, rb.geom_utm))),0)
FROM cand_blocks c
JOIN runmap.run_buffers rb ON rb.run_id = :run_id
WHERE c.geom_utm && rb.geom_utm;
```

---

## 3) Buffer radius sensitivity
Run section (1) with buffer radii 15 m, 20 m, 25 m to see how costs scale.
If you need different radii, store them in a column and branch per profile.

---

## 4) End‑to‑end per‑run function timing
```sql
EXPLAIN (ANALYZE, BUFFERS, WAL, TIMING)
SELECT runmap.process_run(:run_id);
```

Record elapsed time and WAL written. Expect near‑flat scaling as total runs grow.

---

## 5) Log results
```sql
INSERT INTO runmap.tuning_log (action, run_count, seconds, notes)
VALUES ('baseline_subdivide', (SELECT COUNT(*) FROM runmap.runs), :seconds, :notes);
```
