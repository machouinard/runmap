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
    const wkt = buildWktFromGpxText(text);

    const { data: inserted, error: rpcErr } = await supabase.rpc("insert_run_from_wkt", {
      wkt,
      start_time: start_time ?? null,
      duration_s: duration_s ?? null,
      distance_km: distance_km ?? null,
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
