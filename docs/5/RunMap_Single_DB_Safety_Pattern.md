# RunMap: Single‑DB Safety Pattern (Prod‑as‑Staging)
**Date:** 2025-10-20

You’re running with one Postgres database for both experiments and “prod.” That’s fine—just add guardrails. This guide shows how to isolate risky work, keep rollbacks trivial, and avoid nuking real tables while you iterate.

---

## TL;DR
- Create a **scratch schema** (`work`) in the same DB.
- Keep **real objects** in `runmap`; build **shadow objects** in `work` or with `_new` suffixes.
- Do heavy transforms in **UNLOGGED** scratch tables.
- Wrap changes in **transactions**, measure with `EXPLAIN`, and **atomic‑swap** names only when validated.
- **Back up** the `runmap` schema before structural changes.

---

## 1) Schemas and Search Path
```sql
-- One time:
CREATE SCHEMA IF NOT EXISTS runmap;
CREATE SCHEMA IF NOT EXISTS work;

-- Per-session (psql):
SET search_path = work, runmap, public;
SHOW search_path;
```
**Why:** Your DDL/experiments land in `work` by default; production reads stay in `runmap`.

---

## 2) Fast, Targeted Backup Before You Change Things
```bash
# Dump only the runmap schema as compressed archive
pg_dump -Fc -n runmap -d $DB_URL -f runmap_$(date +%F).dump

# Sanity check the archive
pg_restore --list runmap_YYYY-MM-DD.dump | head
```
**Tip:** Keep the last few day’s dumps. Restores are quick and surgical.

---

## 3) Shadow, Validate, Swap (Zero‑Drama Deploys)
Build new versions beside the old ones; swap names in one quick step.

```sql
BEGIN;

-- Example: rebuilding an aggregate table
CREATE TABLE runmap.block_coverage_new (LIKE runmap.block_coverage INCLUDING ALL);

-- Recompute into the _new table
INSERT INTO runmap.block_coverage_new (block_id, len_hit_m)
SELECT block_id, SUM(len_hit_m)
FROM runmap.block_coverage_runs
GROUP BY block_id;

-- Validate: row counts, sample checks, timings
-- (optional asserts)
DO $$ BEGIN
  IF (SELECT COUNT(*) FROM runmap.block_coverage_new) = 0 THEN
    RAISE EXCEPTION 'New table unexpectedly empty';
  END IF;
END $$;

-- Atomic name swap
ALTER TABLE runmap.block_coverage RENAME TO block_coverage_old;
ALTER TABLE runmap.block_coverage_new RENAME TO block_coverage;

COMMIT;

-- Cleanup when happy (later):
DROP TABLE IF EXISTS runmap.block_coverage_old;
```

---

## 4) Use UNLOGGED for Heavy Scratch Work
```sql
-- Lives in RAM/disk, not WAL; faster, not crash-safe
CREATE UNLOGGED TABLE work.tmp_hits AS
SELECT ...;  -- intersections for a single run

-- Add indexes if you re-use it a lot
CREATE INDEX ON work.tmp_hits (block_id);
DROP TABLE work.tmp_hits;  -- toss when done
```
**Rule:** Never store anything you can’t easily recompute in an UNLOGGED table.

---

## 5) Wrap Experiments in Transactions
```sql
BEGIN;

-- DDL and test queries here
EXPLAIN (ANALYZE, BUFFERS, TIMING, WAL) 
SELECT runmap.process_run(:run_id);

-- Spooked? Abort.
ROLLBACK;

-- Confident? Re‑run and COMMIT.
BEGIN;
-- … final, validated steps …
COMMIT;
```

---

## 6) Per‑Session Settings for Heavy Jobs
```sql
SET jit = off;                           -- spatial queries often do better without JIT
SET work_mem = '512MB';                  -- tune to your RAM; reclaim at txn end
SET maintenance_work_mem = '1GB';        -- for index builds / refreshes
SET max_parallel_workers_per_gather = 4; -- let Postgres fan out moderately
ANALYZE runmap.*;                        -- refresh stats after big changes
```

---

## 7) Safe Import and Processing Flow (Single DB)
1. **Insert raw run** into `runmap.runs` (WGS84).
2. **Upsert buffer** into `runmap.run_buffers` (UTM 32610).
3. **Ensure tiles** via `runmap.run_buffers_subdiv` (`ST_Subdivide(..., 256)`).
4. **Process run** → `runmap.process_run(run_id)` which:
   - writes per‑run hits to `runmap.block_coverage_runs`
   - upserts aggregate into `runmap.block_coverage`
5. Optionally **refresh** a materialized view for dashboarding:
   ```sql
   REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_stats_mv;
   ```

All of the above are additive and safe to run in “prod‑as‑staging.”

---

## 8) Guardrails That Save Your Bacon
- Never `ST_Buffer` in EPSG:4326; **transform to 32610** first.
- Always **subdivide** big polygons before intersecting (`ST_Subdivide`). 
- Don’t `DROP` live objects during work hours; **rename** and retire later.
- Keep a **tuning log** (table + markdown notes) with timings and EXPLAINs.
- Avoid procedural row‑by‑row loops—**prefer set‑based SQL**.

---

## 9) Rollback Playbook (when things go sideways)
- If a swap just happened and results look wrong:
  ```sql
  BEGIN;
  ALTER TABLE runmap.block_coverage RENAME TO block_coverage_bad;
  ALTER TABLE runmap.block_coverage_old RENAME TO block_coverage;
  COMMIT;
  ```
- If structural damage: **restore from the dump** (schema‑only or table‑only).

---

## 10) Quick Checklist (print this)
- [ ] `work` schema exists; search_path set to `work, runmap, public`
- [ ] Latest `pg_dump` of `runmap` taken and verified
- [ ] Changes wrapped in `BEGIN … COMMIT`; validated before swap
- [ ] UNLOGGED scratch tables dropped after use
- [ ] `ANALYZE` run after bulk load or index build
- [ ] Benchmark captured with `EXPLAIN (ANALYZE, BUFFERS)` and logged

---

### Notes
- This guide complements your existing **Implementation Checklist**, **Benchmark Protocol**, and `runmap_migration.sql`—follow those for schema and function definitions.
- Rename `work` to whatever you like (`scratch`, `ingest`). The pattern stays the same.
