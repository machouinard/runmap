# iOS Shortcut Setup for Auto-Upload

## Overview

Set up an iOS Shortcut to automatically upload GPX files from WorkOutDoors directly to your RunMap database. The database trigger will automatically process the run, update coverage, and regenerate tiles.

## How It Works

1. **Export from WorkOutDoors** → GPX file saved to iCloud/Files
2. **iOS Shortcut** → Uploads GPX directly to database via API or direct insert
3. **Database Trigger** → Automatically processes new run:
   - Creates buffer (highway-specific distances)
   - Updates block coverage
   - Refreshes statistics
4. **Tile Export** → Manual or scheduled (tiles don't auto-export yet)

## Database Trigger (Already Set Up)

The database now has an automatic trigger:

```sql
-- This trigger fires automatically when a run is inserted
CREATE TRIGGER trigger_auto_process_run
  AFTER INSERT ON runmap.runs_raw
  FOR EACH ROW
  EXECUTE FUNCTION runmap.auto_process_new_run();
```

**What the trigger does:**
- Creates buffer for new run using highway-specific distances
- Updates block coverage incrementally
- Refreshes coverage statistics
- Logs processing in database notices

**Note:** Tiles are NOT auto-exported by the trigger (too slow). You need to export tiles manually or set up a cron job.

## Option 1: Upload via Web API (Recommended)

### Pros
- Easiest to set up
- Handles tile export automatically
- No direct database access needed
- Works from anywhere with internet

### Cons
- Requires API to be running
- Slightly slower than direct insert

### iOS Shortcut Steps

1. **Open Shortcuts app** on iPhone/iPad
2. **Create New Shortcut**
3. **Add Actions:**

```
1. Get File
   - File Service: iCloud Drive / WorkOutDoors
   - Show Document Picker: ON

2. Set Variable
   - Variable Name: GPXFile
   - Value: [File from step 1]

3. Get Contents of URL
   - URL: https://runmap.chouinard.me/api/upload
   - Method: POST
   - Headers:
     - Content-Type: multipart/form-data
   - Request Body: Form
     - Key: file
     - Value: [GPXFile variable]

4. Get Dictionary from Input
   - Input: [Contents of URL]

5. Show Notification
   - Title: "Run Uploaded"
   - Body: [Get value for "message" in Dictionary]
```

4. **Name shortcut:** "Upload to RunMap"
5. **Add to Home Screen** or Share Sheet

### Using the Shortcut

1. Export GPX from WorkOutDoors
2. Run "Upload to RunMap" shortcut
3. Select the GPX file
4. Wait ~30 seconds for notification
5. Tiles will be generated automatically

---

## Option 2: Direct Database Insert (Advanced)

### Pros
- Fastest method
- No API dependency
- Trigger auto-processes immediately

### Cons
- Requires VPN or direct network access
- Requires database credentials in shortcut
- Does NOT export tiles automatically

### Prerequisites

**On Server:** Install PostgREST or create custom API endpoint for direct inserts

**Alternative:** Use `ogr2ogr` via SSH (see Option 3 below)

### iOS Shortcut Steps (if using PostgREST)

```
1. Get File (GPX from WorkOutDoors)
2. Read File Contents (as Text)
3. Run Script Over SSH
   - Host: runmap
   - Script:
     echo "[GPX contents]" | ogr2ogr -f PostgreSQL \
       PG:"host=192.168.68.25 dbname=runmap user=runmap_user password=<password>" \
       /vsistdin/ -nln runmap.runs_raw
```

**Note:** Trigger will auto-process, but you still need to export tiles manually.

---

## Option 3: SSH Upload (Most Reliable)

### Pros
- Most reliable
- Full control
- Can trigger tile export too

### Cons
- Requires SSH access
- Slower than direct insert
- Need SSH keys set up

### iOS Shortcut Steps

Requires **a-Shell** app (App Store) for SSH support:

```
1. Get File (GPX from WorkOutDoors)
2. Save to iCloud/RunMap folder
3. Run Shell Script (via a-Shell):

   scp ~/iCloud/RunMap/latest.gpx runmap:/home/mark/runmap/gpx/
   ssh runmap "cd /home/mark/runmap && bash scripts/process_new_run.sh gpx/latest.gpx"
   ssh runmap "cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh"
```

---

## Tile Export Options

Since the database trigger **does NOT export tiles** (too slow for a trigger), you have these options:

### Option A: Manual Export After Upload

After uploading via any method:
```bash
ssh runmap "cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh"
```

### Option B: Scheduled Cron Job (Recommended)

Set up a cron job on the server to export tiles every hour:

```bash
# On server, edit crontab
crontab -e

# Add this line (export tiles every hour at :05)
5 * * * * cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh > /tmp/tile_export.log 2>&1
```

This way, any runs uploaded (via API, trigger, or manual insert) will have tiles exported within the hour.

### Option C: Export on Demand via API

Update the API upload endpoint to trigger tile export asynchronously (already implemented in Flask API).

---

## Recommended Setup

**Best workflow:**

1. **Set up iOS Shortcut** using Option 1 (Web API)
2. **Set up Cron Job** to export tiles every 30-60 minutes
3. **Done!**

**Daily usage:**
1. Finish run in WorkOutDoors
2. Export → Share → Run "Upload to RunMap" shortcut
3. Wait for notification
4. Check map in ~30-60 min (after next cron tile export)

---

## Testing the Trigger

Test that the auto-process trigger works:

```sql
-- Check current stats
SELECT * FROM runmap.coverage_stats_blocks;

-- Insert a test run (trigger should auto-process)
-- [Upload a GPX via any method]

-- Check stats again (should be updated)
SELECT * FROM runmap.coverage_stats_blocks;

-- Check trigger was called (look for NOTICE in logs)
-- Should see: "Auto-processed run: [uuid] (file: [filename])"
```

---

## Troubleshooting

### Shortcut fails to upload

1. **Check API is running:**
   ```bash
   curl https://runmap.chouinard.me/api/health
   ```
   Should return `{"status": "healthy"}`

2. **Check network access:**
   - Try from browser: https://runmap.chouinard.me
   - May need to be on home WiFi or VPN

### Run uploads but coverage doesn't update

1. **Check trigger is enabled:**
   ```sql
   SELECT tgname, tgenabled FROM pg_trigger
   WHERE tgrelid = 'runmap.runs_raw'::regclass;
   ```

2. **Check for errors:**
   ```bash
   ssh runmap "sudo journalctl -u postgresql -n 50"
   ```

3. **Manually process the run:**
   ```bash
   ssh runmap "cd /home/mark/runmap && bash scripts/process_new_run.sh gpx/yourfile.gpx"
   ```

### Tiles don't update

Tiles are **not** auto-exported by the trigger. Either:

1. **Run manually:**
   ```bash
   ssh runmap "cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh"
   ```

2. **Set up cron job** (see Option B above)

3. **Hard refresh browser:** Cmd+Shift+R (may be cached)

---

## See Also

- [Usage Guide](USAGE_GUIDE.md) - Day-to-day operations
- [Scripts Reference](SCRIPTS_REFERENCE.md) - All available scripts
- [CLAUDE.md](../CLAUDE.md) - Technical documentation
