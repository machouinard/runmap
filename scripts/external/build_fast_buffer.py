#!/usr/bin/env python3
import os
import sys
import time
from typing import Iterable

import psycopg
from shapely import wkb
from shapely.geometry import MultiLineString, MultiPolygon, Polygon
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

if not all([PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD]):
    print("Missing one or more PG* env vars (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD)", file=sys.stderr)
    sys.exit(1)

DSN = f"host={PGHOST} port={PGPORT} dbname={PGDATABASE} user={PGUSER} password={PGPASSWORD} sslmode=require application_name=external_buffer_builder"


def fetch_runs_raw(conn) -> Iterable[bytes]:
    with conn.cursor() as cur:
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
    # Attempt polygonize if needed
    return MultiPolygon([geom])


def build_buffer(conn):
    buffer_m = get_buffer_m(conn)
    t0 = time.time()

    # Transformers
    to_utm = Transformer.from_crs(4326, 32610, always_xy=True).transform
    to_wgs = Transformer.from_crs(32610, 4326, always_xy=True).transform

    # Load and union lines in UTM meters
    geoms = []
    for row_wkb in fetch_runs_raw(conn):
        g = wkb.loads(row_wkb)
        if g.is_empty:
            continue
        g_utm = shp_transform(to_utm, g)
        g_utm = g_utm.simplify(SIMPLIFY_TOLERANCE_M, preserve_topology=True)
        geoms.append(g_utm)

    if not geoms:
        raise RuntimeError("No runs_raw geometries found")

    print(f"Loaded {len(geoms)} runs; simplifying {SIMPLIFY_TOLERANCE_M} m, snapping {SNAP_GRID_M} m…")
    # Snap to grid by snapping to a coarse grid using a zero-length segment trick
    # Alternatively, use shapely.affinity.translate/scale to grid coordinates; we'll use snap-to-self approach.
    union_lines = unary_union(geoms)
    if SNAP_GRID_M > 0:
        # snap to itself with tolerance makes vertices align to grid-like tolerance
        union_lines = snap(union_lines, union_lines, SNAP_GRID_M)

    # Buffer in meters
    buffered = union_lines.buffer(float(buffer_m))

    # Back to WGS84
    buffered_wgs = shp_transform(to_wgs, buffered)
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

        # Optionally refresh dependents here; safer to do separately via refresh_after_external
        if os.environ.get("REFRESH_AFTER", "0") == "1":
            with conn.cursor() as cur:
                cur.execute("SELECT public.refresh_after_external();")
            print("Refreshed dependents via refresh_after_external()")


if __name__ == "__main__":
    main()
