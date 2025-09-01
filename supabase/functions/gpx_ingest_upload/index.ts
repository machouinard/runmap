// deno-lint-ignore-file no-explicit-any
// GPX upload + ingest Edge Function
// Accepts multipart/form-data with fields:
// - file: the GPX file (required)
// - filename: optional original filename (string)
// - path: optional storage key under gpx/ (e.g., my-runs/foo.gpx). If omitted, we generate one.
// - start_time?: ISO8601
// - duration_s?: number
// - distance_km?: number
// Saves to Storage bucket 'gpx', parses to WKT MULTILINESTRING, and calls public.insert_run_from_wkt.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { XMLParser } from "https://esm.sh/fast-xml-parser@4";

function bytesToHex(bytes: ArrayBuffer): string {
  const b = new Uint8Array(bytes);
  return Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join("");
}

function arrayify<T>(x: T | T[] | undefined | null): T[] {
  if (x == null) return [];
  return Array.isArray(x) ? x : [x];
}

function haversine(lat1:number, lon1:number, lat2:number, lon2:number): number {
  const R = 6371000; // meters
  const toRad = (d:number)=> d*Math.PI/180;
  const dLat = toRad(lat2-lat1);
  const dLon = toRad(lon2-lon1);
  const a = Math.sin(dLat/2)**2 + Math.cos(toRad(lat1))*Math.cos(toRad(lat2))*Math.sin(dLon/2)**2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  return R*c;
}

function parseGpx(xmlText: string): { wkt: string, firstTime?: string, lastTime?: string, distance_m?: number } {
  const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: "" });
  const obj = parser.parse(xmlText);
  const gpx = obj?.gpx;
  const tracks = arrayify<any>(gpx?.trk);
  const parts: string[] = [];
  let firstTime: string | undefined;
  let lastTime: string | undefined;
  let distance_m = 0;
  for (const trk of tracks) {
    const segs = arrayify<any>(trk?.trkseg);
    for (const seg of segs) {
      const pts = arrayify<any>(seg?.trkpt);
      const coords: string[] = [];
      let prevLat: number | undefined, prevLon: number | undefined;
      for (const pt of pts) {
        const lat = pt?.lat ?? pt?.["@_lat"];
        const lon = pt?.lon ?? pt?.["@_lon"];
        const time = pt?.time as string | undefined;
        if (time) { if (!firstTime) firstTime = time; lastTime = time; }
        if (lat == null || lon == null) continue;
        const nlat = Number(lat), nlon = Number(lon);
        coords.push(`${nlon} ${nlat}`);
        if (prevLat != null && prevLon != null) distance_m += haversine(prevLat, prevLon, nlat, nlon);
        prevLat = nlat; prevLon = nlon;
      }
      if (coords.length >= 2) parts.push(`(${coords.join(", ")})`);
    }
  }
  if (parts.length === 0) throw new Error("No GPX track segments found");
  return { wkt: `MULTILINESTRING(${parts.join(", ")})`, firstTime, lastTime, distance_m };
}

function buildWktFromGpxText(xmlText: string): string {
  const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: "" });
  const obj = parser.parse(xmlText);
  const gpx = obj?.gpx;
  const tracks = arrayify<any>(gpx?.trk);
  const parts: string[] = [];
  for (const trk of tracks) {
    const segs = arrayify<any>(trk?.trkseg);
    for (const seg of segs) {
      const pts = arrayify<any>(seg?.trkpt);
      const coords: string[] = [];
      for (const pt of pts) {
        const lat = pt?.lat ?? pt?.["@_lat"]; // some parsers prefix attrs
        const lon = pt?.lon ?? pt?.["@_lon"];
        if (lat == null || lon == null) continue;
        coords.push(`${Number(lon)} ${Number(lat)}`); // WKT uses lon lat
      }
      if (coords.length >= 2) parts.push(`(${coords.join(", ")})`);
    }
  }
  if (parts.length === 0) throw new Error("No GPX track segments found");
  return `MULTILINESTRING(${parts.join(", ")})`;
}

export const handler = async (req: Request): Promise<Response> => {
  try {
    if (!req.headers.get("content-type")?.includes("multipart/form-data")) {
      return new Response(JSON.stringify({ error: "Expected multipart/form-data with 'file'" }), { status: 400 });
    }

    const url = Deno.env.get("SB_URL") || Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SB_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) {
      return new Response(JSON.stringify({ error: "Missing Supabase env" }), { status: 500 });
    }
    const supabase = createClient(url, serviceKey);

    const form = await req.formData();
    const file = form.get("file") as File | null;
    if (!file) return new Response(JSON.stringify({ error: "Missing form field 'file'" }), { status: 400 });

    const filename = (form.get("filename") as string | null) ?? file.name ?? "run.gpx";
    const providedPath = (form.get("path") as string | null) ?? null;
    const start_time = (form.get("start_time") as string | null) ?? null;
    const duration_s = form.get("duration_s") ? Number(form.get("duration_s")) : null;
    const distance_km = form.get("distance_km") ? Number(form.get("distance_km")) : null;

    const bytes = await file.arrayBuffer();
    const content_hash = bytesToHex(await crypto.subtle.digest("SHA-256", bytes));

    // Choose a storage key (sanitize filename: underscores, ensure .gpx)
    const datePart = start_time ? new Date(start_time).toISOString().slice(0, 10) : new Date().toISOString().slice(0, 10);
    let name = (filename || "run.gpx").trim();
    if (!name.toLowerCase().endsWith(".gpx")) name += ".gpx";
    // Normalize diacritics, replace spaces and any non [A-Za-z0-9_.-] with underscores
    let safeName = name
      .normalize("NFKD")
      .replace(/\s+/g, "_")
      .replace(/[^A-Za-z0-9_.-]/g, "_")
      .replace(/_+/g, "_");
    if (!safeName.toLowerCase().endsWith(".gpx")) safeName += ".gpx";
    // Trim leading/trailing underscores around basename
    {
      const dot = safeName.lastIndexOf('.')
      let base = dot > 0 ? safeName.slice(0, dot) : safeName
      let ext = dot > 0 ? safeName.slice(dot + 1) : 'gpx'
      base = base.replace(/^_+|_+$/g, '')
      if (!ext || ext.toLowerCase() !== 'gpx') ext = 'gpx'
      safeName = (base.length ? base : 'run') + '.' + ext
    }
    const key = providedPath && providedPath.trim().length > 0
      ? providedPath
      : `my-runs/${datePart}_${content_hash.substring(0, 12)}_${safeName}`;

    // Upload to Storage (upsert)
    const { error: upErr } = await supabase.storage.from("gpx").upload(key, new Blob([bytes], { type: "application/gpx+xml" }), { upsert: true, contentType: "application/gpx+xml" });
    if (upErr) {
      return new Response(JSON.stringify({ error: upErr.message }), { status: 500 });
    }

    // Parse and insert
    const text = await file.text();
    const parsed = parseGpx(text);
    const wkt = parsed.wkt;
    const inferred_start = parsed.firstTime ? new Date(parsed.firstTime).toISOString() : null;
    const inferred_end = parsed.lastTime ? new Date(parsed.lastTime).toISOString() : null;
    const inferred_duration_s = (inferred_start && inferred_end) ? Math.max(0, Math.round((new Date(inferred_end).getTime() - new Date(inferred_start).getTime())/1000)) : null;
    const inferred_distance_km = parsed.distance_m != null ? parsed.distance_m/1000 : null;

    const { data: inserted, error: rpcErr } = await supabase.rpc("insert_run_from_wkt", {
      content_hash,
      distance_km: (distance_km ?? inferred_distance_km),
      duration_s: (duration_s ?? inferred_duration_s),
      source_file: key,
      start_time: (start_time ?? inferred_start),
      wkt,
    });
    if (rpcErr) {
      return new Response(JSON.stringify({ error: rpcErr.message }), { status: 500 });
    }

    return new Response(JSON.stringify({ id: inserted, path: key, content_hash }), { headers: { "Content-Type": "application/json" } });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message ?? String(e) }), { status: 500 });
  }
};

Deno.serve(handler);
