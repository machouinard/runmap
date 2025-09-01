# gpx_ingest Edge Function

Minimal storage-driven GPX → runs_raw ingester.

How it works
- Input (HTTP POST JSON): `{ "path": "subdir/file.gpx", "start_time"?: ISO8601, "duration_s"?: int, "distance_km"?: number }`
- Downloads the GPX from the private `gpx` bucket, computes `content_hash` (SHA-256), parses track segments, builds `MULTILINESTRING` WKT, and calls `runmap.insert_run_from_wkt()` RPC.
- The RPC inserts/upserts into `runmap.runs_raw` and triggers `runmap.refresh_pipeline()`.

Deploy
1) Ensure DB migrations 0001–0003 are applied to your Supabase project.
2) Deploy the edge function (CLI):
   supabase functions deploy gpx_ingest
3) Set env (service key is required for Storage download):
   supabase secrets set --env-file ./supabase/.env
   # Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY

Call
- From local: curl -X POST \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path":"2025-08-31/example.gpx"}' \
    https://<project>.functions.supabase.co/gpx_ingest

Notes
- Dedupe: unique on `content_hash` prevents double inserts if you upload the same file again.
- If GPX has multiple segments, they are preserved as `MULTILINESTRING`.
- Buffer distance is configurable in `runmap.settings.buffer_m` (default 20 m). Re-run `SELECT runmap.refresh_pipeline();` after changing.
