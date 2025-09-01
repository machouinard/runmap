#!/usr/bin/env python3
import os
import sys
import time
from typing import Iterable, List

import psycopg
from shapely import wkb
from shapely.geometry import MultiPolygon, Polygon
from shapely.ops import unary_union, snap
from shapely.ops import transform as shp_transform
from pyproj import Transformer

PGHOST = os.environ.get("PGHOST")
PGPORT = int(os.environ.get("PGPORT", "5432"))
PGDATABASE = os.environ.get("PGDATABASE")
PGUSER = os.environ.get("PGUSER")
PGPASSWORD = os.environ.get("PGPASSWORD")

SIMPLIFY_TOLERANCE_M = float(os.environ.get("SIMPLIFY_TOLERANCE_M", "10.0"))
SNAP_GRID_M = float(os.environ.get("SNAP_GRID_M", "1.0"))
PIPELINE = os.environ.get("PIPELINE", "buffer_then_union")  # or "union_then_buffer"
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "200"))
PRETRANSFORM_DB = os.environ.get("PRETRANSFORM_DB", "0") == "1"

if not all([PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD]):
    print("Missing one or more PG* env vars (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD)", file=sys.stderr)
    sys.exit(1)

DSN = f"host={PGHOST} port={PGPORT} dbname={PGDATABASE} user={PGUSER} password={PGPASSWORD} sslmode=require application_name=external_buffer_builder"


def fetch_runs_raw(conn) -> Iterable[bytes]:
    with conn.cursor() as cur:
        if PRETRANSFORM_DB:
            cur.execute(
                """
                SELECT ST_AsBinary(
                  ST_SnapToGrid(
                    ST_SimplifyPreserveTopology(
                      ST_Transform(geom, 32610), %s
                    ), %s
                  )
                )
                FROM runmap.runs_raw
                WHERE geom IS NOT NULL
                """,
                (SIMPLIFY_TOLERANCE_M, SNAP_GRID_M),
            )
        else:
            cur.execute("SELECT ST_AsBinary(geom) FROM runmap.runs_raw WHERE geom IS NOT NULL")
        for (wkb_bytes,) in cur:
            yield bytes(wkb_bytes)


def get_buffer_m(conn) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT buffer_m FROM runmap.settings LIMIT 1")
        (buffer_m,) = cur.fetchone()
        return int(buffer_m)


def to_multipolygon(geom) -> MultiPolygon:
    if geom.is_empty:
        return MultiPolygon([])
    if isinstance(geom, Polygon):
        return MultiPolygon([geom])
    if isinstance(geom, MultiPolygon):
        return geom
    return MultiPolygon([geom])


def _chunked_unary_union(geoms: List, size: int):
    # Union in batches to reduce peak complexity
    if not geoms:
        return None
    parts = []
    for i in range(0, len(geoms), size):
        parts.append(unary_union(geoms[i : i + size]))
    while len(parts) > 1:
        next_parts = []
        for i in range(0, len(parts), size):
            next_parts.append(unary_union(parts[i : i + size]))
        parts = next_parts
    return parts[0]


def build_buffer(conn):
    buffer_m = get_buffer_m(conn)
    t0 = time.time()

    # Transformers (only used if not PRETRANSFORM_DB)
    to_utm = Transformer.from_crs(4326, 32610, always_xy=True).transform
    to_wgs = Transformer.from_crs(32610, 4326, always_xy=True).transform

    # Load geometries (either WGS84 or pre-transformed to UTM with simplify/snap)
    geoms_utm = []
    for row_wkb in fetch_runs_raw(conn):
        g = wkb.loads(row_wkb)
        if g.is_empty:
            continue
        if PRETRANSFORM_DB:
            g_utm = g  # already 32610 with simplify/snap applied
        else:
            g_utm = shp_transform(to_utm, g)
            g_utm = g_utm.simplify(SIMPLIFY_TOLERANCE_M, preserve_topology=True)
            if SNAP_GRID_M > 0:
                g_utm = snap(g_utm, g_utm, SNAP_GRID_M)
        geoms_utm.append(g_utm)

    if not geoms_utm:
        raise RuntimeError("No runs_raw geometries found")

    print(
        f"Loaded {len(geoms_utm)} runs; simplify {SIMPLIFY_TOLERANCE_M} m, snap {SNAP_GRID_M} m; pipeline={PIPELINE}, batch={BATCH_SIZE}"
    )

    if PIPELINE == "buffer_then_union":
        # Buffer each geometry first, then union polygons in batches
        polys = [g.buffer(float(buffer_m)) for g in geoms_utm]
        unioned = _chunked_unary_union(polys, BATCH_SIZE)
    else:
        # Union lines first, then buffer
        union_lines = _chunked_unary_union(geoms_utm, BATCH_SIZE)
        if SNAP_GRID_M > 0:
            union_lines = snap(union_lines, union_lines, SNAP_GRID_M)
        unioned = union_lines.buffer(float(buffer_m))

    # Back to WGS84
    buffered_wgs = shp_transform(to_wgs, unioned)
    buffered_wgs = to_multipolygon(buffered_wgs)

    print(f"Built buffer in {time.time() - t0:.2f}s; area ~ {buffered_wgs.area:.6f} (deg^2)")
    return buffer_m, buffered_wgs


def upsert_external(conn, buffer_m: int, mp: MultiPolygon):
    wkb_bytes = mp.wkb
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO runmap.coverage_buffer_external (gid, buffer_m, geom, updated_at)
            VALUES (1, %s, ST_SetSRID(ST_GeomFromWKB(%s), 4326), now())
            ON CONFLICT (gid) DO UPDATE
              SET buffer_m = EXCLUDED.buffer_m,
                  geom      = EXCLUDED.geom,
                  updated_at= now()
            """,
            (buffer_m, psycopg.Binary(wkb_bytes)),
        )
    conn.commit()


def main():
    with psycopg.connect(DSN) as conn:
        with conn.cursor() as cur:
            cur.execute("SET statement_timeout=0; SET jit=off; SET work_mem='256MB';")
        buffer_m, mp = build_buffer(conn)
        upsert_external(conn, buffer_m, mp)
        print("Upserted runmap.coverage_buffer_external (gid=1)")

        if os.environ.get("REFRESH_AFTER", "0") == "1":
            with conn.cursor() as cur:
                cur.execute("SELECT public.refresh_after_external();")
            print("Refreshed dependents via refresh_after_external()")


if __name__ == "__main__":
    main()
