// deno-lint-ignore-file no-explicit-any
// Minimal GPX ingest Edge Function
// - Input: JSON { path: string, start_time?: string, duration_s?: number, distance_km?: number }
// - Reads the file from Storage bucket `gpx`, parses GPX trksegs -> MULTILINESTRING
// - Computes SHA-256 content_hash; inserts via RPC runmap.insert_run_from_wkt; returns inserted id

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
        if (time) {
          if (!firstTime) firstTime = time;
          lastTime = time;
        }
        if (lat == null || lon == null) continue;
        const nlat = Number(lat), nlon = Number(lon);
        coords.push(`${nlon} ${nlat}`);
        if (prevLat != null && prevLon != null) {
          distance_m += haversine(prevLat, prevLon, nlat, nlon);
        }
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
        const lat = pt?.lat ?? pt?.["@_lat"]; // handle alt attr naming if any
        const lon = pt?.lon ?? pt?.["@_lon"];
        if (lat == null || lon == null) continue;
        coords.push(`${Number(lon)} ${Number(lat)}`);
      }
      if (coords.length >= 2) parts.push(`(${coords.join(", ")})`);
    }
  }
  if (parts.length === 0) throw new Error("No GPX track segments found");
  return `MULTILINESTRING(${parts.join(", ")})`;
}

export const handler = async (req: Request): Promise<Response> => {
  try {
    const { path, start_time, duration_s, distance_km } = await req.json();
    if (!path || typeof path !== "string") {
      return new Response(JSON.stringify({ error: "Missing path" }), { status: 400 });
    }

    // Read from preferred names (SB_*) and fall back to SUPABASE_* if present
    const url = Deno.env.get("SB_URL") || Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SB_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) {
      return new Response(JSON.stringify({ error: "Missing Supabase env" }), { status: 500 });
    }

    const supabase = createClient(url, serviceKey);

    // Download GPX from Storage
    const { data: fileData, error: dlErr } = await supabase.storage.from("gpx").download(path);
    if (dlErr || !fileData) {
      return new Response(JSON.stringify({ error: dlErr?.message ?? "download failed" }), { status: 404 });
    }

    const bytes = await fileData.arrayBuffer();
    const hash = await crypto.subtle.digest("SHA-256", bytes);
    const content_hash = bytesToHex(hash);

    const text = await fileData.text();
    const parsed = parseGpx(text);
       const wkt = parsed.wkt;
    const inferred_start = parsed.firstTime ? new Date(parsed.firstTime).toISOString() : null;
    const inferred_end = parsed.lastTime ? new Date(parsed.lastTime).toISOString() : null;
    const inferred_duration_s = (inferred_start && inferred_end) ? Math.max(0, Math.round((new Date(inferred_end).getTime() - new Date(inferred_start).getTime())/1000)) : null;
    const inferred_distance_km = parsed.distance_m != null ? parsed.distance_m/1000 : null;

    const { data: inserted, error: rpcErr } = await supabase.rpc("insert_run_from_wkt", {
    wkt,
      start_time: start_time ?? inferred_start,
      duration_s: duration_s ?? inferred_duration_s,
      distance_km: distance_km ?? inferred_distance_km,
      source_file: path,
      content_hash,
    });
    if (rpcErr) {
      return new Response(JSON.stringify({ error: rpcErr.message }), { status: 500 });
    }

    return new Response(JSON.stringify({ id: inserted, content_hash }), { headers: { "Content-Type": "application/json" } });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message ?? String(e) }), { status: 500 });
  }
};

Deno.serve(handler);
