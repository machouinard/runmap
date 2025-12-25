# RunMap Coverage – Implementation Checklist
**Date:** 2025-10-20

This is the no‑BS checklist to ship the incremental coverage pipeline and stop the slow creep in processing times.

---

## Pre‑flight
- Confirm SRIDs:
  - GPX inputs in **EPSG:4326** (WGS84)
  - Working/intersection CRS: **EPSG:32610** (UTM Zone 10N)
- Confirm your **blocks/centerlines** are in 32610. If not, transform once and store.
- Disk: SSD/NVMe preferred. PostgreSQL 16+ with PostGIS 3.x.
- Extensions installed:
  - `CREATE EXTENSION IF NOT EXISTS postgis;`

---

## 1) Schemas
- Create schemas (idempotent): `staging` and `runmap`

---

## 2) Core Tables
- `runmap.runs` – raw GPX lines (MultiLineString 4326)
- `runmap.run_buffers` – per‑run buffer stored in **meters** (32610) + envelope
- `runmap.run_buffers_subdiv` – subdivided tiles of each run buffer
- `runmap.blocks` – your coverage units (LineString 32610) with stored `len_m`
- `runmap.block_coverage_runs` – per‑run×block intersection length
- `runmap.block_coverage` – aggregated per block with `pct` as generated column
- `runmap.tuning_log` – timing notes so we track wins
- Optional read‑side: `runmap.coverage_stats_mv` (materialized view)

> All objects are created by `runmap_migration.sql` below.

---

## 3) Indexes
- GiST on `run_buffers.geom_utm`, `run_buffers.bbox_utm`, `run_buffers_subdiv.geom_utm`, `blocks.geom_utm`
- B‑Tree on `block_coverage_runs (run_id)`, `(block_id)` and `runs (started_at)`
- Run `ANALYZE` after backfills.

---

## 4) Backfill (one‑time)
- Insert existing runs into `runmap.runs` (line‑merge if needed).
- Populate `runmap.run_buffers` (buffer in 32610, e.g., **20.0 m**).
- Build `runmap.run_buffers_subdiv` with `ST_Subdivide(…, 256)`.
- **Measure** one run end‑to‑end before proceeding.

---

## 5) Per‑Run Processing (new imports)
- After each new run:
  1. Insert into `runmap.runs`
  2. Upsert `runmap.run_buffers` and `runmap.run_buffers_subdiv`
  3. Call `runmap.process_run(p_run_id)` to populate:
     - `runmap.block_coverage_runs`
     - `runmap.block_coverage` (aggregate upsert)
  4. Optionally `REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_stats_mv`

---

## 6) Settings for heavy sessions (per‑session)
```sql
SET jit = off;
SET work_mem = '512MB';
SET maintenance_work_mem = '1GB';
SET max_parallel_workers_per_gather = 4;
```

---

## 7) Sanity Tests (smoke tests)
- A: Processing time for 10 randomly picked runs stays within ±20% as dataset grows.
- B: Intersections only touch blocks whose bbox intersects the run buffer envelope.
- C: `%` coverage equals `len_hit_m / len_m * 100` (no negative or > len_m values).

---

## 8) Rollout Steps
1. Apply `runmap_migration.sql` to your `sandbox` DB.
2. Backfill a **small** batch (e.g., 25 runs). Record timings in `tuning_log`.
3. Switch your import pipeline to call `runmap.process_run` per run.
4. Flip dashboards to read from `block_coverage` (and the MV if used).
5. Watch metrics for 100 runs. Then prune old redundant tables.

---

## Need from you (to tailor scripts precisely)
- Actual table names for your existing “runs” and “blocks” sources.
- Desired buffer radius in meters (start with **20.0 m**).
- Typical city/area extent so we can check UTM zone is correct for everything.
- Any business rules for coverage (cul‑de‑sacs, private roads, trails).

Ship this checklist alongside the SQL and protocol docs in the repo.
