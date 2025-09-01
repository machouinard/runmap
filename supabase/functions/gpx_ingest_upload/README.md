# gpx_ingest_upload — Upload GPX from iOS Shortcuts

Purpose
- Accept a GPX file via multipart/form-data, store it in the private `gpx` bucket, parse to WKT, and call `public.insert_run_from_wkt()`.
- This avoids the extra Storage download round-trip.

Deploy
1) Deploy the function:
   supabase functions deploy gpx_ingest_upload --project-ref <project-ref>
2) Ensure secrets are set (same as `gpx_ingest`):
   supabase secrets set --project-ref <project-ref> SB_URL=https://<ref>.supabase.co SB_SERVICE_ROLE_KEY=<service-role-key>

Call (curl)
- curl -X POST "https://<ref>.functions.supabase.co/gpx_ingest_upload" \
    -H "Authorization: Bearer <anon-key>" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@/path/to/file.gpx" \
    -F "filename=file.gpx" \
    -F "path=my-runs/file.gpx" \
    -F "start_time=2024-06-07T12:16:00Z" -F "duration_s=3600" -F "distance_km=10.2"

iOS Shortcut (Share Sheet)
1) New Shortcut → Settings → Show in Share Sheet → Types: GPX
2) Actions:
   - Get Contents of Shortcut Input (as File)
   - Get Name from (Provided File) → result = Filename
   - Get Contents of URL:
     - URL: https://<ref>.functions.supabase.co/gpx_ingest_upload
     - Method: POST
     - Headers: Authorization = Bearer <anon-key>
     - Request Body = Form:
       • file = (Provided File)
       • filename = (Filename)
       • path = my-runs/(Filename)  # optional; leave blank to auto-generate
       • start_time = (Optional)
       • duration_s = (Optional)
       • distance_km = (Optional)
   - Show Result (optional)

Notes
- The function auto-generates a path if none is provided: `my-runs/<YYYY-MM-DD>_<hash12>_<filename>`
- Use your project’s anon key in the Authorization header. Never put the service key on device.
- After upload, the DB pipeline runs and derived views refresh.
