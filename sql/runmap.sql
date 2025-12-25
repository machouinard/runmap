/*
 Navicat Premium Dump SQL

 Source Server         : Runmap PLEX
 Source Server Type    : PostgreSQL
 Source Server Version : 160010 (160010)
 Source Host           : 192.168.68.25:5432
 Source Catalog        : runmap
 Source Schema         : runmap

 Target Server Type    : PostgreSQL
 Target Server Version : 160010 (160010)
 File Encoding         : 65001

 Date: 05/11/2025 19:58:10
*/


-- ----------------------------
-- Sequence structure for aoi_id_seq
-- ----------------------------
DROP SEQUENCE IF EXISTS "runmap"."aoi_id_seq";
CREATE SEQUENCE "runmap"."aoi_id_seq" 
INCREMENT 1
MINVALUE  1
MAXVALUE 2147483647
START 1
CACHE 1;
ALTER SEQUENCE "runmap"."aoi_id_seq" OWNER TO "runmap_user";

-- ----------------------------
-- Sequence structure for block_segments_segment_id_seq
-- ----------------------------
DROP SEQUENCE IF EXISTS "runmap"."block_segments_segment_id_seq";
CREATE SEQUENCE "runmap"."block_segments_segment_id_seq" 
INCREMENT 1
MINVALUE  1
MAXVALUE 2147483647
START 1
CACHE 1;
ALTER SEQUENCE "runmap"."block_segments_segment_id_seq" OWNER TO "runmap_user";

-- ----------------------------
-- Sequence structure for performance_log_id_seq
-- ----------------------------
DROP SEQUENCE IF EXISTS "runmap"."performance_log_id_seq";
CREATE SEQUENCE "runmap"."performance_log_id_seq" 
INCREMENT 1
MINVALUE  1
MAXVALUE 2147483647
START 1
CACHE 1;
ALTER SEQUENCE "runmap"."performance_log_id_seq" OWNER TO "runmap_user";

-- ----------------------------
-- Sequence structure for processing_errors_id_seq
-- ----------------------------
DROP SEQUENCE IF EXISTS "runmap"."processing_errors_id_seq";
CREATE SEQUENCE "runmap"."processing_errors_id_seq" 
INCREMENT 1
MINVALUE  1
MAXVALUE 2147483647
START 1
CACHE 1;
ALTER SEQUENCE "runmap"."processing_errors_id_seq" OWNER TO "runmap_user";

-- ----------------------------
-- Sequence structure for streets_blocks_32610_block_id_seq
-- ----------------------------
DROP SEQUENCE IF EXISTS "runmap"."streets_blocks_32610_block_id_seq";
CREATE SEQUENCE "runmap"."streets_blocks_32610_block_id_seq" 
INCREMENT 1
MINVALUE  1
MAXVALUE 2147483647
START 1
CACHE 1;
ALTER SEQUENCE "runmap"."streets_blocks_32610_block_id_seq" OWNER TO "runmap_user";

-- ----------------------------
-- Sequence structure for streets_reference_ogc_fid_seq
-- ----------------------------
DROP SEQUENCE IF EXISTS "runmap"."streets_reference_ogc_fid_seq";
CREATE SEQUENCE "runmap"."streets_reference_ogc_fid_seq" 
INCREMENT 1
MINVALUE  1
MAXVALUE 2147483647
START 1
CACHE 1;
ALTER SEQUENCE "runmap"."streets_reference_ogc_fid_seq" OWNER TO "runmap_user";

-- ----------------------------
-- Sequence structure for streets_reference_vertices_pgr_id_seq
-- ----------------------------
DROP SEQUENCE IF EXISTS "runmap"."streets_reference_vertices_pgr_id_seq";
CREATE SEQUENCE "runmap"."streets_reference_vertices_pgr_id_seq" 
INCREMENT 1
MINVALUE  1
MAXVALUE 9223372036854775807
START 1
CACHE 1;
ALTER SEQUENCE "runmap"."streets_reference_vertices_pgr_id_seq" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for aoi
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."aoi";
CREATE TABLE "runmap"."aoi" (
  "id" int4 NOT NULL DEFAULT nextval('"runmap".aoi_id_seq'::regclass),
  "name" varchar COLLATE "pg_catalog"."default",
  "created_at" timestamptz(6),
  "updated_at" timestamptz(6),
  "geom" geometry(MULTIPOLYGON, 4326)
)
;
ALTER TABLE "runmap"."aoi" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for block_coverage_segments
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."block_coverage_segments";
CREATE TABLE "runmap"."block_coverage_segments" (
  "block_id" int4 NOT NULL,
  "visited_length_m" float8 NOT NULL DEFAULT 0,
  "total_length_m" float8 NOT NULL,
  "coverage_pct" float8 GENERATED ALWAYS AS (

CASE
    WHEN (total_length_m > (0)::double precision) THEN round((((visited_length_m / total_length_m) * (100)::double precision))::numeric, 2)
    ELSE (0)::numeric
END
) STORED
)
;
ALTER TABLE "runmap"."block_coverage_segments" OWNER TO "runmap_user";
COMMENT ON TABLE "runmap"."block_coverage_segments" IS 'Aggregate coverage computed from visited segments';

-- ----------------------------
-- Table structure for block_segment_visited
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."block_segment_visited";
CREATE TABLE "runmap"."block_segment_visited" (
  "segment_id" int4 NOT NULL,
  "visited" bool NOT NULL DEFAULT false
)
;
ALTER TABLE "runmap"."block_segment_visited" OWNER TO "runmap_user";
COMMENT ON TABLE "runmap"."block_segment_visited" IS 'Binary visited flags - core of constant-time algorithm';

-- ----------------------------
-- Table structure for block_segments
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."block_segments";
CREATE TABLE "runmap"."block_segments" (
  "segment_id" int4 NOT NULL DEFAULT nextval('"runmap".block_segments_segment_id_seq'::regclass),
  "block_id" int4 NOT NULL,
  "segment_geom" geometry(LINESTRING, 32610) NOT NULL,
  "segment_length_m" float8 NOT NULL
)
;
ALTER TABLE "runmap"."block_segments" OWNER TO "runmap_user";
COMMENT ON TABLE "runmap"."block_segments" IS 'Pre-segmented blocks (~5m pieces) for binary visited tracking';

-- ----------------------------
-- Table structure for cycling_raw
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."cycling_raw";
CREATE TABLE "runmap"."cycling_raw" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "filename" text COLLATE "pg_catalog"."default" NOT NULL,
  "uploaded_at" timestamp(6) DEFAULT CURRENT_TIMESTAMP,
  "geom" geometry(MULTILINESTRING, 4326),
  "avg_speed_mph" float8,
  "total_distance_m" float8,
  "duration_seconds" int4,
  "activity_type" text COLLATE "pg_catalog"."default" DEFAULT 'cycle'::text,
  "start_time" timestamptz(6),
  "distance_km" numeric,
  "location" text COLLATE "pg_catalog"."default",
  "workout_hash" text COLLATE "pg_catalog"."default"
)
;
ALTER TABLE "runmap"."cycling_raw" OWNER TO "runmap_user";
COMMENT ON TABLE "runmap"."cycling_raw" IS 'Cycling activities - tracked separately from running';

-- ----------------------------
-- Table structure for performance_log
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."performance_log";
CREATE TABLE "runmap"."performance_log" (
  "id" int4 NOT NULL DEFAULT nextval('"runmap".performance_log_id_seq'::regclass),
  "logged_at" timestamptz(6) NOT NULL DEFAULT now(),
  "operation" text COLLATE "pg_catalog"."default" NOT NULL,
  "run_count" int4,
  "avg_seconds" numeric(10,3),
  "total_seconds" numeric(10,3),
  "optimization" text COLLATE "pg_catalog"."default",
  "notes" text COLLATE "pg_catalog"."default"
)
;
ALTER TABLE "runmap"."performance_log" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for processing_errors
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."processing_errors";
CREATE TABLE "runmap"."processing_errors" (
  "id" int4 NOT NULL DEFAULT nextval('"runmap".processing_errors_id_seq'::regclass),
  "run_id" uuid NOT NULL,
  "error_type" varchar(50) COLLATE "pg_catalog"."default" NOT NULL,
  "error_message" text COLLATE "pg_catalog"."default" NOT NULL,
  "occurred_at" timestamptz(6) DEFAULT CURRENT_TIMESTAMP,
  "retry_count" int4 DEFAULT 0
)
;
ALTER TABLE "runmap"."processing_errors" OWNER TO "runmap_user";
COMMENT ON TABLE "runmap"."processing_errors" IS 'Logs errors during run processing for debugging and retry';

-- ----------------------------
-- Table structure for runs_buffered_subdiv
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."runs_buffered_subdiv";
CREATE TABLE "runmap"."runs_buffered_subdiv" (
  "run_id" uuid NOT NULL,
  "geom" geometry(POLYGON, 32610) NOT NULL
)
;
ALTER TABLE "runmap"."runs_buffered_subdiv" OWNER TO "runmap_user";
COMMENT ON TABLE "runmap"."runs_buffered_subdiv" IS 'Subdivided run buffers for faster intersection tests';

-- ----------------------------
-- Table structure for runs_raw
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."runs_raw";
CREATE TABLE "runmap"."runs_raw" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "filename" text COLLATE "pg_catalog"."default" NOT NULL,
  "uploaded_at" timestamptz(6) DEFAULT now(),
  "start_time" timestamptz(6),
  "duration_seconds" int4,
  "distance_km" numeric,
  "geom" geometry(MULTILINESTRING, 4326),
  "metadata" jsonb,
  "activity_type" text COLLATE "pg_catalog"."default" DEFAULT 'run'::text,
  "total_distance_m" float8,
  "location" text COLLATE "pg_catalog"."default",
  "workout_hash" text COLLATE "pg_catalog"."default",
  "processing_status" varchar(20) COLLATE "pg_catalog"."default" DEFAULT 'pending'::character varying,
  "processing_started_at" timestamptz(6),
  "processing_completed_at" timestamptz(6)
)
;
ALTER TABLE "runmap"."runs_raw" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for settings
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."settings";
CREATE TABLE "runmap"."settings" (
  "key" text COLLATE "pg_catalog"."default" NOT NULL,
  "value" jsonb,
  "updated_at" timestamptz(6) DEFAULT now()
)
;
ALTER TABLE "runmap"."settings" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for streets_blocks_32610
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."streets_blocks_32610";
CREATE TABLE "runmap"."streets_blocks_32610" (
  "block_id" int4 NOT NULL DEFAULT nextval('"runmap".streets_blocks_32610_block_id_seq'::regclass),
  "parent_ogc_fid" int4,
  "block_index" int4,
  "geom_32610" geometry(LINESTRING, 32610),
  "block_length_m" float8,
  "name" text COLLATE "pg_catalog"."default",
  "highway" text COLLATE "pg_catalog"."default"
)
;
ALTER TABLE "runmap"."streets_blocks_32610" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for streets_reference
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."streets_reference";
CREATE TABLE "runmap"."streets_reference" (
  "ogc_fid" int4 NOT NULL DEFAULT nextval('"runmap".streets_reference_ogc_fid_seq'::regclass),
  "osm_id" varchar COLLATE "pg_catalog"."default",
  "name" varchar COLLATE "pg_catalog"."default",
  "highway" varchar COLLATE "pg_catalog"."default",
  "waterway" varchar COLLATE "pg_catalog"."default",
  "aerialway" varchar COLLATE "pg_catalog"."default",
  "barrier" varchar COLLATE "pg_catalog"."default",
  "man_made" varchar COLLATE "pg_catalog"."default",
  "railway" varchar COLLATE "pg_catalog"."default",
  "z_order" int4,
  "other_tags" varchar COLLATE "pg_catalog"."default",
  "geom" geometry(GEOMETRY, 4326),
  "runnable" bool DEFAULT true,
  "source" int4,
  "target" int4,
  "length_m" float8
)
;
ALTER TABLE "runmap"."streets_reference" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for streets_reference_32610
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."streets_reference_32610";
CREATE TABLE "runmap"."streets_reference_32610" (
  "ogc_fid" int4 NOT NULL,
  "osm_id" varchar COLLATE "pg_catalog"."default",
  "name" varchar COLLATE "pg_catalog"."default",
  "highway" varchar COLLATE "pg_catalog"."default",
  "runnable" bool,
  "geom_32610" geometry(GEOMETRY),
  "total_length_m" float8
)
;
ALTER TABLE "runmap"."streets_reference_32610" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for streets_reference_vertices_pgr
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."streets_reference_vertices_pgr";
CREATE TABLE "runmap"."streets_reference_vertices_pgr" (
  "id" int8 NOT NULL DEFAULT nextval('"runmap".streets_reference_vertices_pgr_id_seq'::regclass),
  "cnt" int4,
  "chk" int4,
  "ein" int4,
  "eout" int4,
  "the_geom" geometry(POINT, 4326)
)
;
ALTER TABLE "runmap"."streets_reference_vertices_pgr" OWNER TO "runmap_user";

-- ----------------------------
-- Table structure for walks_raw
-- ----------------------------
DROP TABLE IF EXISTS "runmap"."walks_raw";
CREATE TABLE "runmap"."walks_raw" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "filename" text COLLATE "pg_catalog"."default" NOT NULL,
  "uploaded_at" timestamp(6) DEFAULT CURRENT_TIMESTAMP,
  "geom" geometry(MULTILINESTRING, 4326),
  "avg_pace_min_per_mile" float8,
  "total_distance_m" float8,
  "duration_seconds" int4,
  "activity_type" text COLLATE "pg_catalog"."default" DEFAULT 'walk'::text,
  "start_time" timestamptz(6),
  "distance_km" numeric,
  "location" text COLLATE "pg_catalog"."default",
  "workout_hash" text COLLATE "pg_catalog"."default"
)
;
ALTER TABLE "runmap"."walks_raw" OWNER TO "runmap_user";
COMMENT ON TABLE "runmap"."walks_raw" IS 'Walking activities - not included in running coverage calculations';

-- ----------------------------
-- Function structure for apply_run_to_block_coverage
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."apply_run_to_block_coverage"("run_uuid" uuid);
CREATE FUNCTION "runmap"."apply_run_to_block_coverage"("run_uuid" uuid)
  RETURNS "pg_catalog"."void" AS $BODY$
BEGIN
  -- Store per-run coverage in junction table (for audit/rebuild capability)
  INSERT INTO runmap.block_run_coverage (block_id, run_id, coverage_length_m)
  SELECT
    b.block_id,
    run_uuid,
    ST_Length(ST_Intersection(b.geom_32610, rb.geom)) as new_coverage_length
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = run_uuid
  WHERE ST_Intersects(b.geom_32610, rb.geom)
  ON CONFLICT (block_id, run_id) DO NOTHING;

  -- Update aggregate coverage by unioning ALL run buffers for affected blocks
  -- Key insight: ST_Union on small set of geometries is fast, storing result is slow
  -- So we compute union, measure length, then throw away the geometry
  INSERT INTO runmap.block_coverage_32610 (block_id, covered_length_m, total_length_m, covered_geom)
  SELECT
    b.block_id,
    ST_Length(
      ST_Intersection(
        b.geom_32610,
        ST_Union(rb.geom)  -- Union all run buffers for this block
      )
    ) as total_covered_length,
    b.block_length_m,
    NULL  -- Don't store the geometry
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.block_run_coverage brc ON brc.block_id = b.block_id
  JOIN runmap.runs_buffered_32610 rb ON rb.run_id = brc.run_id
  WHERE b.block_id IN (
    SELECT DISTINCT block_id FROM runmap.block_run_coverage WHERE run_id = run_uuid
  )
  GROUP BY b.block_id, b.geom_32610, b.block_length_m
  ON CONFLICT (block_id) DO UPDATE SET
    covered_length_m = EXCLUDED.covered_length_m;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."apply_run_to_block_coverage"("run_uuid" uuid) OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for apply_run_to_chunk_coverage
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."apply_run_to_chunk_coverage"("run_gid" int8);
CREATE FUNCTION "runmap"."apply_run_to_chunk_coverage"("run_gid" int8)
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  run_buffer geometry;
  chunk_rec RECORD;
  new_coverage geometry;
  new_coverage_length FLOAT;
  chunks_updated INT := 0;
BEGIN
  -- Get this run's buffer
  SELECT geom INTO run_buffer
  FROM runmap.runs_buffered_32610
  WHERE run_id = run_gid;

  IF run_buffer IS NULL THEN
    RAISE EXCEPTION 'No buffer found for run_id %. Did you call buffer_one_run(%)?', run_gid, run_gid;
  END IF;

  -- Update only chunks that intersect this run's buffer
  FOR chunk_rec IN
    SELECT chunk_id, geom_32610, chunk_length_m
    FROM runmap.streets_chunks_32610
    WHERE ST_Intersects(geom_32610, run_buffer)
  LOOP
    -- Calculate new coverage geometry (intersection of chunk with buffer)
    new_coverage := ST_Intersection(chunk_rec.geom_32610, run_buffer);

    -- Skip if intersection is not a line/multiline (point touches don't count)
    IF ST_GeometryType(new_coverage) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
      CONTINUE;
    END IF;

    new_coverage_length := ST_Length(new_coverage);

    -- Skip if coverage is negligible (< 1m)
    IF new_coverage_length < 1.0 THEN
      CONTINUE;
    END IF;

    -- Insert or update coverage (union with existing coverage)
    INSERT INTO runmap.chunk_coverage_32610 (chunk_id, covered_geom, covered_length_m, total_length_m)
    VALUES (chunk_rec.chunk_id, new_coverage, new_coverage_length, chunk_rec.chunk_length_m)
    ON CONFLICT (chunk_id) DO UPDATE SET
      -- Union the new coverage with existing coverage
      covered_geom = ST_Union(runmap.chunk_coverage_32610.covered_geom, EXCLUDED.covered_geom),
      covered_length_m = ST_Length(ST_Union(runmap.chunk_coverage_32610.covered_geom, EXCLUDED.covered_geom)),
      total_length_m = EXCLUDED.total_length_m;

    chunks_updated := chunks_updated + 1;
  END LOOP;

  RAISE NOTICE 'Run % updated % chunks', run_gid, chunks_updated;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."apply_run_to_chunk_coverage"("run_gid" int8) OWNER TO "postgres";

-- ----------------------------
-- Function structure for apply_run_to_chunk_coverage
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."apply_run_to_chunk_coverage"("run_uuid" uuid);
CREATE FUNCTION "runmap"."apply_run_to_chunk_coverage"("run_uuid" uuid)
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  run_buffer geometry;
  chunk_rec RECORD;
  new_coverage geometry;
  new_coverage_length FLOAT;
  chunks_updated INT := 0;
BEGIN
  -- Get this run's buffer
  SELECT geom INTO run_buffer
  FROM runmap.runs_buffered_32610
  WHERE run_id = run_uuid;

  IF run_buffer IS NULL THEN
    RAISE EXCEPTION 'No buffer found for run_id %. Did you call buffer_one_run(%)?', run_uuid, run_uuid;
  END IF;

  -- Update only chunks that intersect this run's buffer
  FOR chunk_rec IN
    SELECT chunk_id, geom_32610, chunk_length_m
    FROM runmap.streets_chunks_32610
    WHERE ST_Intersects(geom_32610, run_buffer)
  LOOP
    -- Calculate new coverage geometry (intersection of chunk with buffer)
    new_coverage := ST_Intersection(chunk_rec.geom_32610, run_buffer);

    -- Skip if intersection is not a line/multiline (point touches don't count)
    IF ST_GeometryType(new_coverage) NOT IN ('ST_LineString', 'ST_MultiLineString') THEN
      CONTINUE;
    END IF;

    new_coverage_length := ST_Length(new_coverage);

    -- Skip if coverage is negligible (< 1m)
    IF new_coverage_length < 1.0 THEN
      CONTINUE;
    END IF;

    -- Insert or update coverage (union with existing coverage)
    INSERT INTO runmap.chunk_coverage_32610 (chunk_id, covered_geom, covered_length_m, total_length_m)
    VALUES (chunk_rec.chunk_id, new_coverage, new_coverage_length, chunk_rec.chunk_length_m)
    ON CONFLICT (chunk_id) DO UPDATE SET
      -- Union the new coverage with existing coverage
      covered_geom = ST_Union(runmap.chunk_coverage_32610.covered_geom, EXCLUDED.covered_geom),
      covered_length_m = ST_Length(ST_Union(runmap.chunk_coverage_32610.covered_geom, EXCLUDED.covered_geom)),
      total_length_m = EXCLUDED.total_length_m;

    chunks_updated := chunks_updated + 1;
  END LOOP;

  RAISE NOTICE 'Run % updated % chunks', run_uuid, chunks_updated;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."apply_run_to_chunk_coverage"("run_uuid" uuid) OWNER TO "postgres";

-- ----------------------------
-- Function structure for apply_run_to_coverage
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."apply_run_to_coverage"("p_run_id" uuid);
CREATE FUNCTION "runmap"."apply_run_to_coverage"("p_run_id" uuid)
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  bgeom geometry(MultiPolygon,32610);
BEGIN
  SELECT ST_UnaryUnion(geom) INTO bgeom
  FROM runmap.runs_buffered_32610
  WHERE run_id = p_run_id;

  IF bgeom IS NULL THEN
    RAISE EXCEPTION 'No buffered geom for run_id %', p_run_id;
  END IF;

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
        WHEN c.covered_geom IS NULL OR ST_IsEmpty(c.covered_geom)
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
      WHEN sc.covered_geom IS NULL OR ST_IsEmpty(sc.covered_geom) 
        THEN ST_LineMerge(c.new_seg)
      ELSE ST_UnaryUnion(ST_Collect(sc.covered_geom, c.new_seg))
    END,
    covered_length_m = ST_Length(
      CASE
        WHEN sc.covered_geom IS NULL OR ST_IsEmpty(sc.covered_geom)
          THEN ST_LineMerge(c.new_seg)
        ELSE ST_UnaryUnion(ST_Collect(sc.covered_geom, c.new_seg))
      END
    )
  FROM cleaned c
  WHERE sc.ogc_fid = c.ogc_fid
    AND NOT ST_IsEmpty(c.new_seg);
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."apply_run_to_coverage"("p_run_id" uuid) OWNER TO "runmap_user";
COMMENT ON FUNCTION "runmap"."apply_run_to_coverage"("p_run_id" uuid) IS 'Incrementally update coverage for streets touched by one run';

-- ----------------------------
-- Function structure for apply_run_to_segments
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."apply_run_to_segments"("run_uuid" uuid);
CREATE FUNCTION "runmap"."apply_run_to_segments"("run_uuid" uuid)
  RETURNS "pg_catalog"."int4" AS $BODY$
DECLARE
  v_segments_marked INTEGER;
BEGIN
  -- Session tuning
  PERFORM set_config('work_mem', '512MB', true);
  PERFORM set_config('jit', 'off', true);

  -- Mark segments as visited (fast UPDATE, no unions!)
  WITH newly_visited AS (
    UPDATE runmap.block_segment_visited bsv
    SET visited = TRUE
    FROM runmap.block_segments bs
    JOIN runmap.runs_buffered_subdiv rb ON rb.run_id = run_uuid
    WHERE bsv.segment_id = bs.segment_id
      AND bsv.visited = FALSE  -- Only update unvisited segments
      AND ST_Intersects(bs.segment_geom, rb.geom)
    RETURNING bsv.segment_id, bs.block_id, bs.segment_length_m
  )
  -- Update aggregate coverage for affected blocks
  INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
  SELECT
    nv.block_id,
    SUM(nv.segment_length_m) as new_visited_length,
    (SELECT SUM(segment_length_m) FROM runmap.block_segments WHERE block_id = nv.block_id) as total
  FROM newly_visited nv
  GROUP BY nv.block_id
  ON CONFLICT (block_id) DO UPDATE
  SET visited_length_m = runmap.block_coverage_segments.visited_length_m + EXCLUDED.visited_length_m;

  -- Get count for logging
  GET DIAGNOSTICS v_segments_marked = ROW_COUNT;

  RETURN v_segments_marked;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."apply_run_to_segments"("run_uuid" uuid) OWNER TO "runmap_user";
COMMENT ON FUNCTION "runmap"."apply_run_to_segments"("run_uuid" uuid) IS 'Mark segments as visited by a run (constant time, no unions!)';

-- ----------------------------
-- Function structure for auto_process_new_run
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."auto_process_new_run"();
CREATE FUNCTION "runmap"."auto_process_new_run"()
  RETURNS "pg_catalog"."trigger" AS $BODY$
BEGIN
  -- Create buffer for this run
  PERFORM runmap.buffer_one_run(NEW.id);

  -- Apply run to block coverage
  PERFORM runmap.apply_run_to_block_coverage(NEW.id);

  -- Refresh coverage stats
  REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

  -- Log the processing
  RAISE NOTICE 'Auto-processed run: % (file: %)', NEW.id, NEW.filename;

  RETURN NEW;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."auto_process_new_run"() OWNER TO "postgres";

-- ----------------------------
-- Function structure for auto_process_new_run_segments
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."auto_process_new_run_segments"();
CREATE FUNCTION "runmap"."auto_process_new_run_segments"()
  RETURNS "pg_catalog"."trigger" AS $BODY$
BEGIN
  -- Buffer and subdivide run
  PERFORM runmap.buffer_one_run_subdiv(NEW.id);

  -- Mark segments as visited
  PERFORM runmap.apply_run_to_segments(NEW.id);

  -- Update block coverage aggregates
  WITH affected_blocks AS (
    SELECT DISTINCT bs.block_id
    FROM runmap.runs_buffered_subdiv rbs
    JOIN runmap.block_segments bs ON ST_Intersects(rbs.geom, bs.segment_geom)
    WHERE rbs.run_id = NEW.id
  )
  INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
  SELECT
    bs.block_id,
    COALESCE(SUM(bs.segment_length_m) FILTER (WHERE bsv.visited), 0) as visited_length_m,
    SUM(bs.segment_length_m) as total_length_m
  FROM runmap.block_segments bs
  LEFT JOIN runmap.block_segment_visited bsv ON bs.segment_id = bsv.segment_id
  WHERE bs.block_id IN (SELECT block_id FROM affected_blocks)
  GROUP BY bs.block_id
  ON CONFLICT (block_id) DO UPDATE
  SET visited_length_m = EXCLUDED.visited_length_m,
      total_length_m = EXCLUDED.total_length_m;

  -- Refresh stats
  REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

  -- Update processing status
  UPDATE runmap.runs_raw
  SET processing_status = 'processed',
      processing_completed_at = NOW()
  WHERE id = NEW.id;

  RAISE NOTICE 'Auto-processed run (segments): % (file: %)', NEW.id, NEW.filename;

  RETURN NEW;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."auto_process_new_run_segments"() OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for buffer_one_run
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."buffer_one_run"("run_uuid" uuid);
CREATE FUNCTION "runmap"."buffer_one_run"("run_uuid" uuid)
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  buffer_config jsonb;
  block_rec RECORD;
  buffer_dist FLOAT;
  run_geom_utm geometry;
  buffered_geom geometry;
  all_buffers geometry[];
  final_buffer geometry;
BEGIN
  -- Get buffer configuration
  SELECT value INTO buffer_config
  FROM runmap.settings WHERE key = 'buffer_config';

  IF buffer_config IS NULL THEN
    -- Fallback to old single buffer distance
    SELECT (value::jsonb)::float INTO buffer_dist
    FROM runmap.settings WHERE key = 'buffer_distance_m';

    IF buffer_dist IS NULL THEN
      buffer_dist := 10.0;
    END IF;

    -- Use old method (single buffer for entire run)
    INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
    SELECT
      run_uuid,
      ST_Buffer(ST_Transform(geom, 32610), buffer_dist)
    FROM runmap.runs_raw
    WHERE id = run_uuid
    ON CONFLICT (run_id) DO UPDATE SET geom = EXCLUDED.geom;

    RETURN;
  END IF;

  -- Get run geometry in UTM
  SELECT ST_Transform(geom, 32610) INTO run_geom_utm
  FROM runmap.runs_raw
  WHERE id = run_uuid;

  IF run_geom_utm IS NULL THEN
    RAISE EXCEPTION 'Run % not found in runs_raw', run_uuid;
  END IF;

  -- Buffer the run differently based on which blocks it intersects
  -- For each block that intersects this run, apply highway-specific buffer
  all_buffers := ARRAY[]::geometry[];

  FOR block_rec IN
    SELECT DISTINCT b.highway, b.geom_32610
    FROM runmap.streets_blocks_32610 b
    WHERE ST_DWithin(b.geom_32610, run_geom_utm, 50) -- Pre-filter with max possible buffer
  LOOP
    -- Get buffer distance for this highway type
    buffer_dist := COALESCE(
      (buffer_config->>block_rec.highway)::float,
      (buffer_config->>'default')::float,
      15.0
    );

    -- Create buffer for the portion of run near this block
    buffered_geom := ST_Buffer(
      ST_Intersection(run_geom_utm, ST_Buffer(block_rec.geom_32610, buffer_dist + 5)),
      buffer_dist
    );

    -- Add to array if valid geometry
    IF buffered_geom IS NOT NULL AND NOT ST_IsEmpty(buffered_geom) THEN
      all_buffers := array_append(all_buffers, buffered_geom);
    END IF;
  END LOOP;

  -- Union all the highway-specific buffers
  IF array_length(all_buffers, 1) > 0 THEN
    final_buffer := ST_Union(all_buffers);
  ELSE
    -- Fallback: use default buffer if no blocks found
    buffer_dist := COALESCE((buffer_config->>'default')::float, 15.0);
    final_buffer := ST_Buffer(run_geom_utm, buffer_dist);
  END IF;

  -- Store the combined buffer
  INSERT INTO runmap.runs_buffered_32610 (run_id, geom)
  VALUES (run_uuid, final_buffer)
  ON CONFLICT (run_id) DO UPDATE SET geom = EXCLUDED.geom;

END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."buffer_one_run"("run_uuid" uuid) OWNER TO "postgres";

-- ----------------------------
-- Function structure for buffer_one_run_subdiv
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."buffer_one_run_subdiv"("run_uuid" uuid);
CREATE FUNCTION "runmap"."buffer_one_run_subdiv"("run_uuid" uuid)
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  v_buffer_distance FLOAT;
BEGIN
  -- Session tuning
  PERFORM set_config('work_mem', '256MB', true);
  PERFORM set_config('jit', 'off', true);

  v_buffer_distance := runmap.get_buffer_distance();

  -- Create buffer and subdivide into smaller polygons
  INSERT INTO runmap.runs_buffered_subdiv (run_id, geom)
  SELECT
    run_uuid,
    (ST_Dump(ST_Subdivide(
      ST_Buffer(
        ST_Transform(geom, 32610),
        v_buffer_distance,
        'endcap=flat join=mitre quad_segs=4'  -- Cheaper buffers
      ),
      256  -- Max vertices per subdivision
    ))).geom
  FROM runmap.runs_raw
  WHERE id = run_uuid;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."buffer_one_run_subdiv"("run_uuid" uuid) OWNER TO "runmap_user";
COMMENT ON FUNCTION "runmap"."buffer_one_run_subdiv"("run_uuid" uuid) IS 'Buffer and subdivide a single run for segment-visited processing';

-- ----------------------------
-- Function structure for calculate_route_efficiency
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."calculate_route_efficiency"("p_route_geom" "public"."geometry", "p_location" text, "p_buffer_m" numeric);
CREATE FUNCTION "runmap"."calculate_route_efficiency"("p_route_geom" "public"."geometry", "p_location" text, "p_buffer_m" numeric=10.0)
  RETURNS "pg_catalog"."json" AS $BODY$
DECLARE
    v_route_utm GEOMETRY;
    v_route_buffer GEOMETRY;
    v_new_coverage_m NUMERIC;
    v_redundant_coverage_m NUMERIC;
    v_total_route_m NUMERIC;
    v_efficiency_pct NUMERIC;
BEGIN
    -- Transform route to UTM 32610 for accurate buffering
    v_route_utm := ST_Transform(p_route_geom, 32610);

    -- Buffer the route
    v_route_buffer := ST_Buffer(v_route_utm, p_buffer_m);

    -- Calculate total route length
    v_total_route_m := ST_Length(v_route_utm);

    -- Calculate new coverage (intersection with unrun blocks)
    SELECT COALESCE(SUM(ST_Length(ST_Intersection(sb.geom_32610, v_route_buffer))), 0)
    INTO v_new_coverage_m
    FROM runmap.block_coverage_segments bcs
    JOIN runmap.streets_blocks_32610 sb ON bcs.block_id = sb.block_id
    WHERE bcs.coverage_pct < 5.0
      AND ST_Intersects(sb.geom_32610, v_route_buffer);

    -- Calculate redundant coverage (intersection with complete blocks)
    SELECT COALESCE(SUM(ST_Length(ST_Intersection(sb.geom_32610, v_route_buffer))), 0)
    INTO v_redundant_coverage_m
    FROM runmap.block_coverage_segments bcs
    JOIN runmap.streets_blocks_32610 sb ON bcs.block_id = sb.block_id
    WHERE bcs.coverage_pct >= runmap.get_completion_threshold()
      AND ST_Intersects(sb.geom_32610, v_route_buffer);

    -- Calculate efficiency percentage
    IF (v_new_coverage_m + v_redundant_coverage_m) > 0 THEN
        v_efficiency_pct := (v_new_coverage_m / (v_new_coverage_m + v_redundant_coverage_m)) * 100.0;
    ELSE
        v_efficiency_pct := 0.0;
    END IF;

    RETURN json_build_object(
        'total_route_m', ROUND(v_total_route_m::numeric, 2),
        'total_route_miles', ROUND((v_total_route_m / 1609.34)::numeric, 2),
        'new_coverage_m', ROUND(v_new_coverage_m::numeric, 2),
        'new_coverage_miles', ROUND((v_new_coverage_m / 1609.34)::numeric, 2),
        'redundant_coverage_m', ROUND(v_redundant_coverage_m::numeric, 2),
        'redundant_coverage_miles', ROUND((v_redundant_coverage_m / 1609.34)::numeric, 2),
        'efficiency_pct', ROUND(v_efficiency_pct::numeric, 1)
    );
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."calculate_route_efficiency"("p_route_geom" "public"."geometry", "p_location" text, "p_buffer_m" numeric) OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for cleanup_coverage_on_delete
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."cleanup_coverage_on_delete"();
CREATE FUNCTION "runmap"."cleanup_coverage_on_delete"()
  RETURNS "pg_catalog"."trigger" AS $BODY$
DECLARE
  affected_segment_ids INTEGER[];
BEGIN
  -- Get list of segment IDs affected by this run's buffer
  -- Must do this BEFORE the buffer is cascade-deleted
  SELECT ARRAY_AGG(DISTINCT bs.segment_id)
  INTO affected_segment_ids
  FROM runmap.runs_buffered_subdiv rbs
  JOIN runmap.block_segments bs ON ST_Intersects(rbs.geom, bs.segment_geom)
  WHERE rbs.run_id = OLD.id;

  -- The buffer will be automatically deleted by CASCADE after this trigger

  IF affected_segment_ids IS NOT NULL AND array_length(affected_segment_ids, 1) > 0 THEN
    -- For each affected segment, check if it's still visited by any OTHER run
    -- This is more efficient than recalculating everything
    UPDATE runmap.block_segment_visited bsv
    SET visited = EXISTS (
      SELECT 1
      FROM runmap.runs_buffered_subdiv rbs
      JOIN runmap.block_segments bs ON bs.segment_id = bsv.segment_id
      WHERE ST_Intersects(rbs.geom, bs.segment_geom)
        AND rbs.run_id != OLD.id  -- Exclude the run being deleted
    )
    WHERE bsv.segment_id = ANY(affected_segment_ids);

    -- Recompute block coverage from segments
    -- Get affected blocks
    WITH affected_blocks AS (
      SELECT DISTINCT block_id
      FROM runmap.block_segments
      WHERE segment_id = ANY(affected_segment_ids)
    )
    INSERT INTO runmap.block_coverage_segments (block_id, visited_length_m, total_length_m)
    SELECT
      bs.block_id,
      COALESCE(SUM(bs.segment_length_m) FILTER (WHERE bsv.visited), 0) as visited_length_m,
      SUM(bs.segment_length_m) as total_length_m
    FROM runmap.block_segments bs
    LEFT JOIN runmap.block_segment_visited bsv ON bs.segment_id = bsv.segment_id
    WHERE bs.block_id IN (SELECT block_id FROM affected_blocks)
    GROUP BY bs.block_id
    ON CONFLICT (block_id) DO UPDATE
    SET visited_length_m = EXCLUDED.visited_length_m,
        total_length_m = EXCLUDED.total_length_m;

    -- Refresh stats
    REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

    RAISE NOTICE 'Cleaned up coverage for deleted run: % (affected % segments)', OLD.id, array_length(affected_segment_ids, 1);
  END IF;

  RETURN OLD;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."cleanup_coverage_on_delete"() OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for detect_location
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."detect_location"("geom" "public"."geometry");
CREATE FUNCTION "runmap"."detect_location"("geom" "public"."geometry")
  RETURNS "pg_catalog"."text" AS $BODY$
DECLARE
  centroid_point geometry;
  lon FLOAT;
  lat FLOAT;
BEGIN
  -- Handle NULL geometry
  IF geom IS NULL THEN
    RETURN NULL;
  END IF;

  -- Get centroid of the activity
  centroid_point := ST_Centroid(geom);
  lon := ST_X(centroid_point);
  lat := ST_Y(centroid_point);

  -- Check Sacramento boundaries (expanded to metro area)
  -- Latitude: 38.4° to 38.7°
  -- Longitude: -121.6° to -121.3°
  IF lat BETWEEN 38.4 AND 38.7
     AND lon BETWEEN -121.6 AND -121.3 THEN
    RETURN 'sacramento';
  END IF;

  -- Check Portland boundaries (expanded to metro area)
  -- Latitude: 45.4° to 45.7°
  -- Longitude: -122.8° to -122.5°
  IF lat BETWEEN 45.4 AND 45.7
     AND lon BETWEEN -122.8 AND -122.5 THEN
    RETURN 'portland';
  END IF;

  -- Everything else
  RETURN 'other';
END;
$BODY$
  LANGUAGE plpgsql IMMUTABLE
  COST 100;
ALTER FUNCTION "runmap"."detect_location"("geom" "public"."geometry") OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for get_all_coverage_areas
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."get_all_coverage_areas"("p_location" text);
CREATE FUNCTION "runmap"."get_all_coverage_areas"("p_location" text)
  RETURNS "pg_catalog"."json" AS $BODY$
DECLARE
    v_features JSON;
BEGIN
    SELECT json_build_object(
        'type', 'FeatureCollection',
        'features', json_agg(feature)
    )
    INTO v_features
    FROM (
        SELECT runmap.get_coverage_areas(p_location, 'complete') AS feature
        UNION ALL
        SELECT runmap.get_coverage_areas(p_location, 'partial')
        UNION ALL
        SELECT runmap.get_coverage_areas(p_location, 'unrun')
    ) AS all_features;

    RETURN v_features;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."get_all_coverage_areas"("p_location" text) OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for get_buffer_config
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."get_buffer_config"();
CREATE FUNCTION "runmap"."get_buffer_config"()
  RETURNS TABLE("highway_type" text, "buffer_meters" float8) AS $BODY$
DECLARE
  config jsonb;
  key text;
BEGIN
  SELECT value INTO config FROM runmap.settings WHERE key = 'buffer_config';

  IF config IS NULL THEN
    -- Return old single buffer setting
    RETURN QUERY
    SELECT 'all (legacy)'::text, (value::jsonb)::float
    FROM runmap.settings WHERE key = 'buffer_distance_m';
    RETURN;
  END IF;

  -- Return each highway type and its buffer
  FOR key IN SELECT jsonb_object_keys(config) LOOP
    RETURN QUERY SELECT key, (config->>key)::float;
  END LOOP;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;
ALTER FUNCTION "runmap"."get_buffer_config"() OWNER TO "postgres";

-- ----------------------------
-- Function structure for get_buffer_distance
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."get_buffer_distance"();
CREATE FUNCTION "runmap"."get_buffer_distance"()
  RETURNS "pg_catalog"."float8" AS $BODY$
DECLARE
  v_distance FLOAT;
BEGIN
  SELECT (value::text)::float
  INTO v_distance
  FROM runmap.settings
  WHERE key = 'buffer_distance_m';

  RETURN COALESCE(v_distance, 10.0);  -- Default 10m
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."get_buffer_distance"() OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for get_completion_threshold
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."get_completion_threshold"();
CREATE FUNCTION "runmap"."get_completion_threshold"()
  RETURNS "pg_catalog"."float8" AS $BODY$
  SELECT COALESCE((value::float), 90.0)
  FROM runmap.settings
  WHERE key = 'completion_threshold_pct';
$BODY$
  LANGUAGE sql STABLE
  COST 100;
ALTER FUNCTION "runmap"."get_completion_threshold"() OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for get_coverage_areas
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."get_coverage_areas"("p_location" text, "p_coverage_type" text);
CREATE FUNCTION "runmap"."get_coverage_areas"("p_location" text, "p_coverage_type" text)
  RETURNS "pg_catalog"."json" AS $BODY$
DECLARE
    v_coverage_threshold NUMERIC;
    v_min_pct NUMERIC;
    v_max_pct NUMERIC;
    v_geojson JSON;
BEGIN
    -- Get the completion threshold (typically 90%)
    v_coverage_threshold := runmap.get_completion_threshold();

    -- Determine percentage range based on coverage type
    IF p_coverage_type = 'complete' THEN
        v_min_pct := v_coverage_threshold;
        v_max_pct := 100.0;
    ELSIF p_coverage_type = 'partial' THEN
        v_min_pct := 5.0;
        v_max_pct := v_coverage_threshold;
    ELSIF p_coverage_type = 'unrun' THEN
        v_min_pct := 0.0;
        v_max_pct := 5.0;
    ELSE
        RAISE EXCEPTION 'Invalid coverage_type: %. Must be complete, partial, or unrun', p_coverage_type;
    END IF;

    -- Query blocks matching criteria, buffer to create polygons, union them, simplify, and convert to GeoJSON
    -- Transform to 4326 (WGS84) for GraphHopper API
    -- Note: We can't filter by location since we don't track which runs touched which blocks,
    -- so we return all blocks matching the coverage criteria
    -- Buffer the lines by 20m to create polygon areas for GraphHopper
    SELECT json_build_object(
        'type', 'Feature',
        'id', p_coverage_type || '_coverage',  -- e.g., 'unrun_coverage' for GraphHopper area matching
        'geometry', ST_AsGeoJSON(
            ST_SimplifyPreserveTopology(
                ST_Transform(
                    ST_Buffer(
                        ST_Union(sb.geom_32610),
                        20.0  -- 20m buffer to create area polygons from street lines
                    ),
                    4326
                ),
                0.00001  -- Simplify to ~1m tolerance
            )
        )::json,
        'properties', json_build_object(
            'coverage_type', p_coverage_type,
            'location', p_location,
            'block_count', COUNT(*)
        )
    )
    INTO v_geojson
    FROM runmap.block_coverage_segments bcs
    JOIN runmap.streets_blocks_32610 sb ON bcs.block_id = sb.block_id
    WHERE bcs.coverage_pct >= v_min_pct
      AND bcs.coverage_pct < v_max_pct
    GROUP BY p_coverage_type, p_location;

    -- Return empty feature if no blocks found
    IF v_geojson IS NULL THEN
        v_geojson := json_build_object(
            'type', 'Feature',
            'id', p_coverage_type,
            'geometry', NULL,
            'properties', json_build_object(
                'coverage_type', p_coverage_type,
                'location', p_location,
                'block_count', 0
            )
        );
    END IF;

    RETURN v_geojson;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."get_coverage_areas"("p_location" text, "p_coverage_type" text) OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for rebuild_block_coverage
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."rebuild_block_coverage"();
CREATE FUNCTION "runmap"."rebuild_block_coverage"()
  RETURNS "pg_catalog"."void" AS $BODY$
BEGIN
  TRUNCATE runmap.block_coverage_32610;

  -- Process all runs in order
  PERFORM runmap.apply_run_to_block_coverage(id)
  FROM runmap.runs_raw
  ORDER BY uploaded_at;

  RAISE NOTICE 'Rebuilt coverage for % blocks',
    (SELECT COUNT(*) FROM runmap.block_coverage_32610 WHERE covered_length_m > 0);
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."rebuild_block_coverage"() OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for rebuild_chunk_coverage
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."rebuild_chunk_coverage"();
CREATE FUNCTION "runmap"."rebuild_chunk_coverage"()
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  run_rec RECORD;
  total_runs INT;
  run_count INT := 0;
BEGIN
  TRUNCATE runmap.chunk_coverage_32610;

  SELECT COUNT(*) INTO total_runs FROM runmap.runs_raw;
  RAISE NOTICE 'Rebuilding chunk coverage for % runs...', total_runs;

  FOR run_rec IN
    SELECT id FROM runmap.runs_raw ORDER BY uploaded_at
  LOOP
    run_count := run_count + 1;
    RAISE NOTICE 'Processing run % of % (%.0f%%)...',
      run_count, total_runs, (run_count::FLOAT / total_runs * 100);

    PERFORM runmap.apply_run_to_chunk_coverage(run_rec.id);
  END LOOP;

  RAISE NOTICE '====================================';
  RAISE NOTICE 'Phase 3 Complete: Coverage Rebuild';
  RAISE NOTICE 'Total runs processed: %', total_runs;
  RAISE NOTICE 'Chunks with coverage: %', (SELECT COUNT(*) FROM runmap.chunk_coverage_32610);
  RAISE NOTICE '====================================';
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."rebuild_chunk_coverage"() OWNER TO "postgres";

-- ----------------------------
-- Function structure for reset_coverage_processing
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."reset_coverage_processing"();
CREATE FUNCTION "runmap"."reset_coverage_processing"()
  RETURNS "pg_catalog"."void" AS $BODY$
BEGIN
  -- Clear all processing results but keep imported runs/walks/cycling
  TRUNCATE TABLE runmap.runs_buffered_32610 CASCADE;
  TRUNCATE TABLE runmap.block_coverage_32610 CASCADE;
  TRUNCATE TABLE runmap.block_run_coverage CASCADE;
  
  RAISE NOTICE 'Coverage processing reset complete. Run data preserved.';
  RAISE NOTICE 'Runs: % | Walks: % | Cycling: %',
    (SELECT COUNT(*) FROM runmap.runs_raw),
    (SELECT COUNT(*) FROM runmap.walks_raw),
    (SELECT COUNT(*) FROM runmap.cycling_raw);
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."reset_coverage_processing"() OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for retry_run_processing
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."retry_run_processing"("p_run_id" uuid);
CREATE FUNCTION "runmap"."retry_run_processing"("p_run_id" uuid)
  RETURNS TABLE("success" bool, "message" text) AS $BODY$
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
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100
  ROWS 1000;
ALTER FUNCTION "runmap"."retry_run_processing"("p_run_id" uuid) OWNER TO "runmap_user";
COMMENT ON FUNCTION "runmap"."retry_run_processing"("p_run_id" uuid) IS 'Retries processing for a failed run, returns success status and message';

-- ----------------------------
-- Function structure for set_buffer_distance
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."set_buffer_distance"("highway_type" text, "distance_m" float8);
CREATE FUNCTION "runmap"."set_buffer_distance"("highway_type" text, "distance_m" float8)
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  config jsonb;
BEGIN
  SELECT value INTO config FROM runmap.settings WHERE key = 'buffer_config';

  IF config IS NULL THEN
    config := '{}'::jsonb;
  END IF;

  -- Update the specific highway type
  config := jsonb_set(config, ARRAY[highway_type], to_jsonb(distance_m));

  -- Save back to settings
  UPDATE runmap.settings SET value = config WHERE key = 'buffer_config';

  RAISE NOTICE 'Updated buffer for % to %m', highway_type, distance_m;
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."set_buffer_distance"("highway_type" text, "distance_m" float8) OWNER TO "postgres";

-- ----------------------------
-- Function structure for set_location_on_insert
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."set_location_on_insert"();
CREATE FUNCTION "runmap"."set_location_on_insert"()
  RETURNS "pg_catalog"."trigger" AS $BODY$
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
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."set_location_on_insert"() OWNER TO "runmap_user";

-- ----------------------------
-- Function structure for split_streets_at_intersections
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."split_streets_at_intersections"();
CREATE FUNCTION "runmap"."split_streets_at_intersections"()
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  street_rec RECORD;
  intersection_pts geometry;
  split_geom geometry;
  segment geometry;
  segment_idx INT;
  segment_count INT := 0;
  street_count INT := 0;
  total_streets INT;
BEGIN
  -- Clear existing data
  TRUNCATE runmap.streets_blocks_32610 CASCADE;

  SELECT COUNT(*) INTO total_streets FROM runmap.streets_reference_32610;
  RAISE NOTICE 'Splitting % streets at intersections...', total_streets;

  FOR street_rec IN
    SELECT ogc_fid, name, highway, geom_32610, total_length_m
    FROM runmap.streets_reference_32610
    ORDER BY ogc_fid
  LOOP
    street_count := street_count + 1;

    -- Progress indicator every 100 streets
    IF street_count % 100 = 0 THEN
      RAISE NOTICE 'Processing street % of % (%.0f%%)...',
        street_count, total_streets, (street_count::FLOAT / total_streets * 100);
    END IF;

    -- Find all intersection points for this street
    -- (points where other streets cross this street's geometry)
    SELECT ST_Union(pts) INTO intersection_pts
    FROM (
      SELECT ST_Intersection(street_rec.geom_32610, other.geom_32610) AS pts
      FROM runmap.streets_reference_32610 other
      WHERE other.ogc_fid != street_rec.ogc_fid
        AND ST_Intersects(street_rec.geom_32610, other.geom_32610)
        AND ST_GeometryType(ST_Intersection(street_rec.geom_32610, other.geom_32610)) = 'ST_Point'
    ) t
    WHERE pts IS NOT NULL;

    -- If no intersections found, keep original segment as single block
    IF intersection_pts IS NULL THEN
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES
        (street_rec.ogc_fid, 0, street_rec.geom_32610, street_rec.total_length_m,
         street_rec.name, street_rec.highway);
      segment_count := segment_count + 1;
      CONTINUE;
    END IF;

    -- Split street at intersection points
    BEGIN
      split_geom := ST_Split(street_rec.geom_32610, intersection_pts);
    EXCEPTION WHEN OTHERS THEN
      -- If split fails (can happen with topology issues), keep original
      RAISE WARNING 'Failed to split street ogc_fid=% (%): %. Keeping as single block.',
        street_rec.ogc_fid, COALESCE(street_rec.name, 'unnamed'), SQLERRM;
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES
        (street_rec.ogc_fid, 0, street_rec.geom_32610, street_rec.total_length_m,
         street_rec.name, street_rec.highway);
      segment_count := segment_count + 1;
      CONTINUE;
    END;

    -- Insert each resulting segment as a block
    segment_idx := 0;
    FOR segment IN
      SELECT (ST_Dump(split_geom)).geom
    LOOP
      INSERT INTO runmap.streets_blocks_32610
        (parent_ogc_fid, block_index, geom_32610, block_length_m, name, highway)
      VALUES (
        street_rec.ogc_fid,
        segment_idx,
        segment,
        ST_Length(segment),
        street_rec.name,
        street_rec.highway
      );
      segment_idx := segment_idx + 1;
      segment_count := segment_count + 1;
    END LOOP;
  END LOOP;

  RAISE NOTICE '====================================';
  RAISE NOTICE 'Phase 1 Complete: Intersection Split';
  RAISE NOTICE 'Input: % streets', total_streets;
  RAISE NOTICE 'Output: % blocks', segment_count;
  RAISE NOTICE 'Ratio: %.1f blocks per street', segment_count::FLOAT / total_streets;
  RAISE NOTICE '====================================';
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."split_streets_at_intersections"() OWNER TO "postgres";

-- ----------------------------
-- Function structure for subdivide_blocks_to_chunks
-- ----------------------------
DROP FUNCTION IF EXISTS "runmap"."subdivide_blocks_to_chunks"("max_chunk_length_m" float8);
CREATE FUNCTION "runmap"."subdivide_blocks_to_chunks"("max_chunk_length_m" float8=50.0)
  RETURNS "pg_catalog"."void" AS $BODY$
DECLARE
  block_rec RECORD;
  num_chunks INT;
  chunk_idx INT;
  chunk_start FLOAT;
  chunk_end FLOAT;
  chunk_geom geometry;
  chunk_count INT := 0;
  block_count INT := 0;
  total_blocks INT;
BEGIN
  -- Clear existing data
  TRUNCATE runmap.streets_chunks_32610 CASCADE;

  SELECT COUNT(*) INTO total_blocks FROM runmap.streets_blocks_32610;
  RAISE NOTICE 'Subdividing % blocks into chunks (max %.0fm)...', total_blocks, max_chunk_length_m;

  FOR block_rec IN
    SELECT block_id, parent_ogc_fid, geom_32610, block_length_m, name, highway
    FROM runmap.streets_blocks_32610
    ORDER BY block_id
  LOOP
    block_count := block_count + 1;

    -- Progress indicator every 500 blocks
    IF block_count % 500 = 0 THEN
      RAISE NOTICE 'Processing block % of % (%.0f%%)...',
        block_count, total_blocks, (block_count::FLOAT / total_blocks * 100);
    END IF;

    -- If block is already short enough, keep as single chunk
    IF block_rec.block_length_m <= max_chunk_length_m THEN
      INSERT INTO runmap.streets_chunks_32610
        (block_id, parent_ogc_fid, chunk_index, geom_32610, chunk_length_m, name, highway)
      VALUES (
        block_rec.block_id,
        block_rec.parent_ogc_fid,
        0,
        block_rec.geom_32610,
        block_rec.block_length_m,
        block_rec.name,
        block_rec.highway
      );
      chunk_count := chunk_count + 1;
      CONTINUE;
    END IF;

    -- Calculate number of chunks needed
    num_chunks := CEIL(block_rec.block_length_m / max_chunk_length_m)::INT;

    -- Create uniform chunks using ST_LineSubstring
    FOR chunk_idx IN 0..(num_chunks - 1) LOOP
      chunk_start := (chunk_idx::FLOAT / num_chunks);
      chunk_end := ((chunk_idx + 1)::FLOAT / num_chunks);

      chunk_geom := ST_LineSubstring(block_rec.geom_32610, chunk_start, chunk_end);

      INSERT INTO runmap.streets_chunks_32610
        (block_id, parent_ogc_fid, chunk_index, geom_32610, chunk_length_m, name, highway)
      VALUES (
        block_rec.block_id,
        block_rec.parent_ogc_fid,
        chunk_idx,
        chunk_geom,
        ST_Length(chunk_geom),
        block_rec.name,
        block_rec.highway
      );
      chunk_count := chunk_count + 1;
    END LOOP;
  END LOOP;

  RAISE NOTICE '====================================';
  RAISE NOTICE 'Phase 2 Complete: Chunk Subdivision';
  RAISE NOTICE 'Input: % blocks', total_blocks;
  RAISE NOTICE 'Output: % chunks', chunk_count;
  RAISE NOTICE 'Ratio: %.1f chunks per block', chunk_count::FLOAT / total_blocks;
  RAISE NOTICE '====================================';
END;
$BODY$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION "runmap"."subdivide_blocks_to_chunks"("max_chunk_length_m" float8) OWNER TO "postgres";

-- ----------------------------
-- View structure for all_activities
-- ----------------------------
DROP VIEW IF EXISTS "runmap"."all_activities";
CREATE VIEW "runmap"."all_activities" AS  SELECT runs_raw.id,
    runs_raw.filename,
    runs_raw.uploaded_at,
    runs_raw.geom,
    runs_raw.workout_hash,
    'run'::text AS activity_type,
    NULL::double precision AS avg_pace_min_per_mile,
    NULL::double precision AS avg_speed_mph,
    NULL::double precision AS total_distance_m,
    NULL::integer AS duration_seconds
   FROM runmap.runs_raw
UNION ALL
 SELECT walks_raw.id,
    walks_raw.filename,
    walks_raw.uploaded_at,
    walks_raw.geom,
    walks_raw.workout_hash,
    'walk'::text AS activity_type,
    walks_raw.avg_pace_min_per_mile,
    NULL::double precision AS avg_speed_mph,
    walks_raw.total_distance_m,
    walks_raw.duration_seconds
   FROM runmap.walks_raw
UNION ALL
 SELECT cycling_raw.id,
    cycling_raw.filename,
    cycling_raw.uploaded_at,
    cycling_raw.geom,
    cycling_raw.workout_hash,
    'cycle'::text AS activity_type,
    NULL::double precision AS avg_pace_min_per_mile,
    cycling_raw.avg_speed_mph,
    cycling_raw.total_distance_m,
    cycling_raw.duration_seconds
   FROM runmap.cycling_raw;
ALTER TABLE "runmap"."all_activities" OWNER TO "runmap_user";

-- ----------------------------
-- View structure for activity_stats
-- ----------------------------
DROP VIEW IF EXISTS "runmap"."activity_stats";
CREATE VIEW "runmap"."activity_stats" AS  SELECT activity_type,
    count(*) AS total_count,
    sum(total_distance_m) / 1609.34::double precision AS total_miles,
    sum(duration_seconds)::numeric / 3600.0 AS total_hours
   FROM ( SELECT 'run'::text AS activity_type,
            NULL::double precision AS total_distance_m,
            NULL::integer AS duration_seconds
           FROM runmap.runs_raw
        UNION ALL
         SELECT 'walk'::text,
            walks_raw.total_distance_m,
            walks_raw.duration_seconds
           FROM runmap.walks_raw
        UNION ALL
         SELECT 'cycle'::text,
            cycling_raw.total_distance_m,
            cycling_raw.duration_seconds
           FROM runmap.cycling_raw) combined
  GROUP BY activity_type
  ORDER BY activity_type;
ALTER TABLE "runmap"."activity_stats" OWNER TO "runmap_user";
COMMENT ON VIEW "runmap"."activity_stats" IS 'Summary statistics across all activity types';

-- ----------------------------
-- View structure for streets_unrun
-- ----------------------------
DROP VIEW IF EXISTS "runmap"."streets_unrun";
CREATE VIEW "runmap"."streets_unrun" AS  SELECT b.block_id,
    b.name,
    b.highway,
    b.geom_32610,
    b.block_length_m,
    COALESCE(bcs.coverage_pct, 0::double precision) AS coverage_pct
   FROM runmap.streets_blocks_32610 b
     LEFT JOIN runmap.block_coverage_segments bcs USING (block_id)
  WHERE COALESCE(bcs.coverage_pct, 0::double precision) < 5::double precision;
ALTER TABLE "runmap"."streets_unrun" OWNER TO "runmap_user";

-- ----------------------------
-- View structure for streets_partial
-- ----------------------------
DROP VIEW IF EXISTS "runmap"."streets_partial";
CREATE VIEW "runmap"."streets_partial" AS  SELECT b.block_id,
    b.name,
    b.highway,
    b.geom_32610,
    b.block_length_m,
    bcs.coverage_pct
   FROM runmap.streets_blocks_32610 b
     JOIN runmap.block_coverage_segments bcs USING (block_id)
  WHERE bcs.coverage_pct >= 5::double precision AND bcs.coverage_pct < 75::double precision;
ALTER TABLE "runmap"."streets_partial" OWNER TO "runmap_user";

-- ----------------------------
-- View structure for streets_complete
-- ----------------------------
DROP VIEW IF EXISTS "runmap"."streets_complete";
CREATE VIEW "runmap"."streets_complete" AS  SELECT b.block_id,
    b.name,
    b.highway,
    b.geom_32610,
    b.block_length_m,
    bcs.coverage_pct
   FROM runmap.streets_blocks_32610 b
     JOIN runmap.block_coverage_segments bcs USING (block_id)
  WHERE bcs.coverage_pct >= 75::double precision;
ALTER TABLE "runmap"."streets_complete" OWNER TO "runmap_user";

-- ----------------------------
-- View structure for blocks_stats
-- ----------------------------
DROP VIEW IF EXISTS "runmap"."blocks_stats";
CREATE VIEW "runmap"."blocks_stats" AS  SELECT count(*) AS total_blocks,
    round(avg(block_length_m)::numeric, 1) AS avg_length_m,
    round(min(block_length_m)::numeric, 1) AS min_length_m,
    round(max(block_length_m)::numeric, 1) AS max_length_m,
    round(percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY block_length_m)::numeric, 1) AS median_length_m,
    count(*) FILTER (WHERE block_length_m > 200::double precision) AS blocks_over_200m,
    count(*) FILTER (WHERE block_length_m > 100::double precision) AS blocks_over_100m,
    count(*) FILTER (WHERE block_length_m > 50::double precision) AS blocks_over_50m
   FROM runmap.streets_blocks_32610;
ALTER TABLE "runmap"."blocks_stats" OWNER TO "runmap_user";

-- ----------------------------
-- View structure for blocks_per_street
-- ----------------------------
DROP VIEW IF EXISTS "runmap"."blocks_per_street";
CREATE VIEW "runmap"."blocks_per_street" AS  SELECT s.ogc_fid,
    s.name,
    s.highway,
    s.total_length_m AS original_length_m,
    count(b.block_id) AS num_blocks,
    round(avg(b.block_length_m)::numeric, 1) AS avg_block_length_m
   FROM runmap.streets_reference_32610 s
     LEFT JOIN runmap.streets_blocks_32610 b ON b.parent_ogc_fid = s.ogc_fid
  GROUP BY s.ogc_fid, s.name, s.highway, s.total_length_m
  ORDER BY (count(b.block_id)) DESC;
ALTER TABLE "runmap"."blocks_per_street" OWNER TO "runmap_user";

-- ----------------------------
-- View structure for failed_runs
-- ----------------------------
DROP VIEW IF EXISTS "runmap"."failed_runs";
CREATE VIEW "runmap"."failed_runs" AS  SELECT r.id,
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
    pe.occurred_at AS last_error_at
   FROM runmap.runs_raw r
     LEFT JOIN LATERAL ( SELECT processing_errors.error_type,
            processing_errors.error_message,
            processing_errors.retry_count,
            processing_errors.occurred_at
           FROM runmap.processing_errors
          WHERE processing_errors.run_id = r.id
          ORDER BY processing_errors.occurred_at DESC
         LIMIT 1) pe ON true
  WHERE r.processing_status::text = ANY (ARRAY['failed'::character varying, 'pending'::character varying]::text[])
  ORDER BY r.uploaded_at DESC;
ALTER TABLE "runmap"."failed_runs" OWNER TO "runmap_user";
COMMENT ON VIEW "runmap"."failed_runs" IS 'Lists all runs that failed processing with their most recent error';

-- ----------------------------
-- Alter sequences owned by
-- ----------------------------
ALTER SEQUENCE "runmap"."aoi_id_seq"
OWNED BY "runmap"."aoi"."id";
SELECT setval('"runmap"."aoi_id_seq"', 1, true);

-- ----------------------------
-- Alter sequences owned by
-- ----------------------------
ALTER SEQUENCE "runmap"."block_segments_segment_id_seq"
OWNED BY "runmap"."block_segments"."segment_id";
SELECT setval('"runmap"."block_segments_segment_id_seq"', 54892, true);

-- ----------------------------
-- Alter sequences owned by
-- ----------------------------
ALTER SEQUENCE "runmap"."performance_log_id_seq"
OWNED BY "runmap"."performance_log"."id";
SELECT setval('"runmap"."performance_log_id_seq"', 1, true);

-- ----------------------------
-- Alter sequences owned by
-- ----------------------------
ALTER SEQUENCE "runmap"."processing_errors_id_seq"
OWNED BY "runmap"."processing_errors"."id";
SELECT setval('"runmap"."processing_errors_id_seq"', 4, true);

-- ----------------------------
-- Alter sequences owned by
-- ----------------------------
ALTER SEQUENCE "runmap"."streets_blocks_32610_block_id_seq"
OWNED BY "runmap"."streets_blocks_32610"."block_id";
SELECT setval('"runmap"."streets_blocks_32610_block_id_seq"', 2597, true);

-- ----------------------------
-- Alter sequences owned by
-- ----------------------------
ALTER SEQUENCE "runmap"."streets_reference_ogc_fid_seq"
OWNED BY "runmap"."streets_reference"."ogc_fid";
SELECT setval('"runmap"."streets_reference_ogc_fid_seq"', 121060, true);

-- ----------------------------
-- Alter sequences owned by
-- ----------------------------
ALTER SEQUENCE "runmap"."streets_reference_vertices_pgr_id_seq"
OWNED BY "runmap"."streets_reference_vertices_pgr"."id";
SELECT setval('"runmap"."streets_reference_vertices_pgr_id_seq"', 1438, true);

-- ----------------------------
-- Indexes structure for table aoi
-- ----------------------------
CREATE INDEX "aoi_geom_geom_idx" ON "runmap"."aoi" USING gist (
  "geom" "public"."gist_geometry_ops_2d"
);

-- ----------------------------
-- Primary Key structure for table aoi
-- ----------------------------
ALTER TABLE "runmap"."aoi" ADD CONSTRAINT "aoi_pkey" PRIMARY KEY ("id");

-- ----------------------------
-- Indexes structure for table block_coverage_segments
-- ----------------------------
CREATE INDEX "idx_block_coverage_segments_pct" ON "runmap"."block_coverage_segments" USING btree (
  "coverage_pct" "pg_catalog"."float8_ops" ASC NULLS LAST
);

-- ----------------------------
-- Primary Key structure for table block_coverage_segments
-- ----------------------------
ALTER TABLE "runmap"."block_coverage_segments" ADD CONSTRAINT "block_coverage_segments_pkey" PRIMARY KEY ("block_id");

-- ----------------------------
-- Indexes structure for table block_segment_visited
-- ----------------------------
CREATE INDEX "idx_segment_visited_true" ON "runmap"."block_segment_visited" USING btree (
  "segment_id" "pg_catalog"."int4_ops" ASC NULLS LAST
) WHERE visited = true;

-- ----------------------------
-- Primary Key structure for table block_segment_visited
-- ----------------------------
ALTER TABLE "runmap"."block_segment_visited" ADD CONSTRAINT "block_segment_visited_pkey" PRIMARY KEY ("segment_id");

-- ----------------------------
-- Indexes structure for table block_segments
-- ----------------------------
CREATE INDEX "idx_block_segments_block" ON "runmap"."block_segments" USING btree (
  "block_id" "pg_catalog"."int4_ops" ASC NULLS LAST
);
CREATE INDEX "idx_block_segments_geom" ON "runmap"."block_segments" USING gist (
  "segment_geom" "public"."gist_geometry_ops_2d"
);

-- ----------------------------
-- Primary Key structure for table block_segments
-- ----------------------------
ALTER TABLE "runmap"."block_segments" ADD CONSTRAINT "block_segments_pkey" PRIMARY KEY ("segment_id");

-- ----------------------------
-- Indexes structure for table cycling_raw
-- ----------------------------
CREATE INDEX "idx_cycling_activity_type" ON "runmap"."cycling_raw" USING btree (
  "activity_type" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_cycling_geom" ON "runmap"."cycling_raw" USING gist (
  "geom" "public"."gist_geometry_ops_2d"
);
CREATE INDEX "idx_cycling_location" ON "runmap"."cycling_raw" USING btree (
  "location" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_cycling_raw_workout_hash" ON "runmap"."cycling_raw" USING btree (
  "workout_hash" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_cycling_uploaded_at" ON "runmap"."cycling_raw" USING btree (
  "uploaded_at" "pg_catalog"."timestamp_ops" ASC NULLS LAST
);

-- ----------------------------
-- Triggers structure for table cycling_raw
-- ----------------------------
CREATE TRIGGER "trigger_set_location_before_insert" BEFORE INSERT ON "runmap"."cycling_raw"
FOR EACH ROW
EXECUTE PROCEDURE "runmap"."set_location_on_insert"();

-- ----------------------------
-- Uniques structure for table cycling_raw
-- ----------------------------
ALTER TABLE "runmap"."cycling_raw" ADD CONSTRAINT "cycling_raw_workout_hash_key" UNIQUE ("workout_hash");

-- ----------------------------
-- Primary Key structure for table cycling_raw
-- ----------------------------
ALTER TABLE "runmap"."cycling_raw" ADD CONSTRAINT "cycling_raw_pkey" PRIMARY KEY ("id");

-- ----------------------------
-- Indexes structure for table performance_log
-- ----------------------------
CREATE INDEX "idx_performance_log_operation" ON "runmap"."performance_log" USING btree (
  "operation" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST,
  "logged_at" "pg_catalog"."timestamptz_ops" ASC NULLS LAST
);

-- ----------------------------
-- Primary Key structure for table performance_log
-- ----------------------------
ALTER TABLE "runmap"."performance_log" ADD CONSTRAINT "performance_log_pkey" PRIMARY KEY ("id");

-- ----------------------------
-- Indexes structure for table processing_errors
-- ----------------------------
CREATE INDEX "idx_processing_errors_occurred_at" ON "runmap"."processing_errors" USING btree (
  "occurred_at" "pg_catalog"."timestamptz_ops" DESC NULLS FIRST
);
CREATE INDEX "idx_processing_errors_run_id" ON "runmap"."processing_errors" USING btree (
  "run_id" "pg_catalog"."uuid_ops" ASC NULLS LAST
);

-- ----------------------------
-- Primary Key structure for table processing_errors
-- ----------------------------
ALTER TABLE "runmap"."processing_errors" ADD CONSTRAINT "processing_errors_pkey" PRIMARY KEY ("id");

-- ----------------------------
-- Indexes structure for table runs_buffered_subdiv
-- ----------------------------
CREATE INDEX "idx_runs_buffered_subdiv_geom" ON "runmap"."runs_buffered_subdiv" USING gist (
  "geom" "public"."gist_geometry_ops_2d"
);
CREATE INDEX "idx_runs_buffered_subdiv_run" ON "runmap"."runs_buffered_subdiv" USING btree (
  "run_id" "pg_catalog"."uuid_ops" ASC NULLS LAST
);

-- ----------------------------
-- Indexes structure for table runs_raw
-- ----------------------------
CREATE INDEX "idx_runs_activity_type" ON "runmap"."runs_raw" USING btree (
  "activity_type" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_runs_location" ON "runmap"."runs_raw" USING btree (
  "location" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_runs_processing_status" ON "runmap"."runs_raw" USING btree (
  "processing_status" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_runs_raw_workout_hash" ON "runmap"."runs_raw" USING btree (
  "workout_hash" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "runs_raw_geom_idx" ON "runmap"."runs_raw" USING gist (
  "geom" "public"."gist_geometry_ops_2d"
);
CREATE INDEX "runs_raw_uploaded_idx" ON "runmap"."runs_raw" USING btree (
  "uploaded_at" "pg_catalog"."timestamptz_ops" DESC NULLS FIRST
);

-- ----------------------------
-- Triggers structure for table runs_raw
-- ----------------------------
CREATE TRIGGER "trigger_auto_process_run_segments" AFTER INSERT ON "runmap"."runs_raw"
FOR EACH ROW
EXECUTE PROCEDURE "runmap"."auto_process_new_run_segments"();
CREATE TRIGGER "trigger_cleanup_coverage_on_delete" BEFORE DELETE ON "runmap"."runs_raw"
FOR EACH ROW
EXECUTE PROCEDURE "runmap"."cleanup_coverage_on_delete"();
CREATE TRIGGER "trigger_set_location_before_insert" BEFORE INSERT ON "runmap"."runs_raw"
FOR EACH ROW
EXECUTE PROCEDURE "runmap"."set_location_on_insert"();

-- ----------------------------
-- Uniques structure for table runs_raw
-- ----------------------------
ALTER TABLE "runmap"."runs_raw" ADD CONSTRAINT "runs_raw_workout_hash_key" UNIQUE ("workout_hash");

-- ----------------------------
-- Checks structure for table runs_raw
-- ----------------------------
ALTER TABLE "runmap"."runs_raw" ADD CONSTRAINT "runs_raw_processing_status_check" CHECK (processing_status::text = ANY (ARRAY['pending'::character varying, 'processing'::character varying, 'processed'::character varying, 'failed'::character varying]::text[]));

-- ----------------------------
-- Primary Key structure for table runs_raw
-- ----------------------------
ALTER TABLE "runmap"."runs_raw" ADD CONSTRAINT "runs_raw_pkey" PRIMARY KEY ("id");

-- ----------------------------
-- Primary Key structure for table settings
-- ----------------------------
ALTER TABLE "runmap"."settings" ADD CONSTRAINT "settings_pkey" PRIMARY KEY ("key");

-- ----------------------------
-- Indexes structure for table streets_blocks_32610
-- ----------------------------
CREATE INDEX "idx_blocks_geom" ON "runmap"."streets_blocks_32610" USING gist (
  "geom_32610" "public"."gist_geometry_ops_2d"
);
CREATE INDEX "idx_blocks_parent" ON "runmap"."streets_blocks_32610" USING btree (
  "parent_ogc_fid" "pg_catalog"."int4_ops" ASC NULLS LAST
);

-- ----------------------------
-- Primary Key structure for table streets_blocks_32610
-- ----------------------------
ALTER TABLE "runmap"."streets_blocks_32610" ADD CONSTRAINT "streets_blocks_32610_pkey" PRIMARY KEY ("block_id");

-- ----------------------------
-- Indexes structure for table streets_reference
-- ----------------------------
CREATE INDEX "streets_reference_geom_geom_idx" ON "runmap"."streets_reference" USING gist (
  "geom" "public"."gist_geometry_ops_2d"
);
CREATE INDEX "streets_reference_source_idx" ON "runmap"."streets_reference" USING btree (
  "source" "pg_catalog"."int4_ops" ASC NULLS LAST
);
CREATE INDEX "streets_reference_target_idx" ON "runmap"."streets_reference" USING btree (
  "target" "pg_catalog"."int4_ops" ASC NULLS LAST
);

-- ----------------------------
-- Primary Key structure for table streets_reference
-- ----------------------------
ALTER TABLE "runmap"."streets_reference" ADD CONSTRAINT "streets_reference_pkey" PRIMARY KEY ("ogc_fid");

-- ----------------------------
-- Indexes structure for table streets_reference_32610
-- ----------------------------
CREATE INDEX "streets_ref_32610_gix" ON "runmap"."streets_reference_32610" USING gist (
  "geom_32610" "public"."gist_geometry_ops_2d"
);

-- ----------------------------
-- Primary Key structure for table streets_reference_32610
-- ----------------------------
ALTER TABLE "runmap"."streets_reference_32610" ADD CONSTRAINT "streets_reference_32610_pkey" PRIMARY KEY ("ogc_fid");

-- ----------------------------
-- Indexes structure for table streets_reference_vertices_pgr
-- ----------------------------
CREATE INDEX "streets_reference_vertices_pgr_the_geom_idx" ON "runmap"."streets_reference_vertices_pgr" USING gist (
  "the_geom" "public"."gist_geometry_ops_2d"
);

-- ----------------------------
-- Primary Key structure for table streets_reference_vertices_pgr
-- ----------------------------
ALTER TABLE "runmap"."streets_reference_vertices_pgr" ADD CONSTRAINT "streets_reference_vertices_pgr_pkey" PRIMARY KEY ("id");

-- ----------------------------
-- Indexes structure for table walks_raw
-- ----------------------------
CREATE INDEX "idx_walks_activity_type" ON "runmap"."walks_raw" USING btree (
  "activity_type" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_walks_geom" ON "runmap"."walks_raw" USING gist (
  "geom" "public"."gist_geometry_ops_2d"
);
CREATE INDEX "idx_walks_location" ON "runmap"."walks_raw" USING btree (
  "location" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_walks_raw_workout_hash" ON "runmap"."walks_raw" USING btree (
  "workout_hash" COLLATE "pg_catalog"."default" "pg_catalog"."text_ops" ASC NULLS LAST
);
CREATE INDEX "idx_walks_uploaded_at" ON "runmap"."walks_raw" USING btree (
  "uploaded_at" "pg_catalog"."timestamp_ops" ASC NULLS LAST
);

-- ----------------------------
-- Triggers structure for table walks_raw
-- ----------------------------
CREATE TRIGGER "trigger_set_location_before_insert" BEFORE INSERT ON "runmap"."walks_raw"
FOR EACH ROW
EXECUTE PROCEDURE "runmap"."set_location_on_insert"();

-- ----------------------------
-- Uniques structure for table walks_raw
-- ----------------------------
ALTER TABLE "runmap"."walks_raw" ADD CONSTRAINT "walks_raw_workout_hash_key" UNIQUE ("workout_hash");

-- ----------------------------
-- Primary Key structure for table walks_raw
-- ----------------------------
ALTER TABLE "runmap"."walks_raw" ADD CONSTRAINT "walks_raw_pkey" PRIMARY KEY ("id");

-- ----------------------------
-- Foreign Keys structure for table block_coverage_segments
-- ----------------------------
ALTER TABLE "runmap"."block_coverage_segments" ADD CONSTRAINT "block_coverage_segments_block_id_fkey" FOREIGN KEY ("block_id") REFERENCES "runmap"."streets_blocks_32610" ("block_id") ON DELETE CASCADE ON UPDATE NO ACTION;

-- ----------------------------
-- Foreign Keys structure for table block_segment_visited
-- ----------------------------
ALTER TABLE "runmap"."block_segment_visited" ADD CONSTRAINT "block_segment_visited_segment_id_fkey" FOREIGN KEY ("segment_id") REFERENCES "runmap"."block_segments" ("segment_id") ON DELETE CASCADE ON UPDATE NO ACTION;

-- ----------------------------
-- Foreign Keys structure for table block_segments
-- ----------------------------
ALTER TABLE "runmap"."block_segments" ADD CONSTRAINT "block_segments_block_id_fkey" FOREIGN KEY ("block_id") REFERENCES "runmap"."streets_blocks_32610" ("block_id") ON DELETE CASCADE ON UPDATE NO ACTION;

-- ----------------------------
-- Foreign Keys structure for table processing_errors
-- ----------------------------
ALTER TABLE "runmap"."processing_errors" ADD CONSTRAINT "processing_errors_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "runmap"."runs_raw" ("id") ON DELETE CASCADE ON UPDATE NO ACTION;

-- ----------------------------
-- Foreign Keys structure for table runs_buffered_subdiv
-- ----------------------------
ALTER TABLE "runmap"."runs_buffered_subdiv" ADD CONSTRAINT "runs_buffered_subdiv_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "runmap"."runs_raw" ("id") ON DELETE CASCADE ON UPDATE NO ACTION;

-- ----------------------------
-- Foreign Keys structure for table streets_blocks_32610
-- ----------------------------
ALTER TABLE "runmap"."streets_blocks_32610" ADD CONSTRAINT "streets_blocks_32610_parent_ogc_fid_fkey" FOREIGN KEY ("parent_ogc_fid") REFERENCES "runmap"."streets_reference_32610" ("ogc_fid") ON DELETE NO ACTION ON UPDATE NO ACTION;
