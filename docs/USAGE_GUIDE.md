# RunMap Day-to-Day Usage Guide

## Quick Reference

| Task | Command |
|------|---------|
| **Upload new run** | `scp run.gpx runmap:/home/mark/runmap/gpx/ && ssh runmap "cd /home/mark/runmap && bash scripts/process_new_run.sh run.gpx"` |
| **View coverage** | Open https://runmap.chouinard.me |
| **Check stats** | `psql -h 192.168.68.25 -U runmap_user -d runmap -c "SELECT * FROM runmap.coverage_stats_blocks;"` |
| **Change threshold** | See [Changing Completion Threshold](#changing-completion-threshold) |
| **Change buffer** | See [Changing Buffer Distance](#changing-buffer-distance) |

---

## After Exporting a Run from WorkOutDoors

### Option 1: iOS Shortcut (Easiest - Recommended)

**One-tap upload from your iPhone:**

1. Export GPX from WorkOutDoors (share → Export → GPX)
2. Run the "Upload to RunMap" iOS Shortcut
3. Done! The shortcut will:
   - Upload GPX to server
   - Show success message with location and distance
   - Detect duplicates (if you already uploaded this run)

**Duplicate Detection:**
- The system uses your run's start time (rounded to 10-minute buckets) to detect duplicates
- Same workout from different apps (WorkOutDoors, Apple Health, Strava) = detected as duplicate
- You'll see: "This run was already uploaded!" with details of the existing run

**What happens automatically:**
- GPX uploaded to server
- Run imported to database
- **Database trigger auto-processes:**
  - Creates 10m buffer around your GPS track
  - Updates block coverage incrementally
  - Refreshes coverage statistics
- Tiles regenerated (~30 seconds)
- Map updates

---

### Option 2: Upload via Web Interface

1. Export GPX from WorkOutDoors to Files/iCloud
2. Open https://runmap.chouinard.me
3. Click **"Upload GPX"** button
4. Select your .gpx file
5. Success message shows location and distance
6. Map auto-reloads after ~30 seconds

**Duplicate Detection:**
- If you upload the same run twice, you'll get: "This run was already uploaded!"
- Shows original filename and upload date
- No changes made to database

**What happens automatically:**
- Same as iOS Shortcut (see above)

---

### Option 3: Manual Upload via SCP/SSH

If web interface isn't working or you prefer command line:

```bash
# 1. Copy GPX to server
scp ~/Downloads/run.gpx runmap:/home/mark/runmap/gpx/

# 2. SSH to server and process
ssh runmap
cd /home/mark/runmap

# 3. Run processing script
bash scripts/process_new_run.sh gpx/run.gpx

# 4. Export tiles
bash scripts/export_tiles_blocks.sh

# 5. Exit SSH
exit
```

**Processing takes:** ~10-30 seconds depending on run length

---

### Option 4: Bulk Import Multiple Runs

**For importing many runs at once (e.g., from Apple Health export):**

If you have multiple GPX files to upload:

```bash
# 1. Copy GPX files to server
scp ~/Downloads/*.gpx runmap:/home/mark/runmap/data/bulk-import/

# 2. SSH to server and run bulk import
ssh -p 2222 runmap
cd /home/mark/runmap

# 3. Bulk import (detects duplicates automatically)
DB_HOST=localhost bash scripts/bulk_import.sh /home/mark/runmap/data/bulk-import

# 4. Export tiles
bash scripts/export_tiles_blocks.sh

exit
```

**Bulk import features:**
- Disables triggers during import for speed
- Shows progress: ✓ SUCCESS / ⚠️ DUPLICATE / ✗ ERROR
- Batch processes all runs at end
- Much faster than one-by-one uploads
- Takes ~2-3 minutes for 20 runs

**After bulk import:**
- Check summary: "✓ Imported: 19, ⚠️ Duplicates: 1, ✗ Errors: 0"
- Duplicates are automatically skipped (based on workout_hash)
- Export tiles manually with `bash scripts/export_tiles_blocks.sh`

---

## Viewing Your Progress

### Web Map
Open https://runmap.chouinard.me

**Map Legend:**
- **Green blocks** = Complete blocks (≥90% coverage)
- **Purple blocks** = Incomplete blocks (<90% coverage)
- **Red lines** = Your actual runs

**Tips:**
- Zoom in to see individual 100m blocks
- Purple blocks are what you still need to run
- Coverage stats show in top right
- Auto-detects location (Sacramento vs Portland)
- Distance tracked per location

---

### Database Stats

```bash
# Overall stats
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT
  total_blocks,
  complete_blocks,
  ROUND(block_completion_pct::numeric, 1) as completion_pct,
  ROUND(overall_coverage_pct::numeric, 1) as distance_pct
FROM runmap.coverage_stats_blocks;
EOF
```

**Output example:**
```
 total_blocks | complete_blocks | completion_pct | distance_pct
--------------+-----------------+----------------+--------------
         2597 |             285 |           11.0 |         57.4
```

---

### Top Streets Needing Work

```bash
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT name, highway, complete_blocks, total_blocks,
  ROUND(avg_coverage_pct::numeric, 1) as avg_pct
FROM runmap.streets_least_complete
LIMIT 20;
EOF
```

Shows streets with incomplete blocks, sorted by least complete first.

---

### Top Completed Streets

```bash
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT name, highway, complete_blocks, total_blocks,
  ROUND(avg_coverage_pct::numeric, 1) as avg_pct
FROM runmap.streets_most_complete
LIMIT 20;
EOF
```

Shows your most completed streets.

---

## Changing Settings

### Changing Completion Threshold

The completion threshold determines when a block shows as green (complete) vs grey (incomplete).

**Current threshold:** 90%

**To change:**

```bash
# Example: Lower to 85% (more lenient)
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
UPDATE runmap.settings
SET value = '85'::jsonb
WHERE key = 'completion_threshold_pct';

REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
EOF

# Regenerate tiles
ssh runmap "cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh"
```

**Threshold guidelines:**
- **85%** - More forgiving, good if GPS gaps are common
- **90%** - Current default, balanced
- **95%** - Very strict, only near-perfect runs count

**No need to reprocess runs** - threshold change only affects how blocks are classified.

---

### Changing Buffer Distance

Buffer distance controls how far from your GPS track counts as "covered" (accounts for GPS accuracy and sidewalk offset).

**Current buffers (by road type):**
```json
{
  "primary": 20m,
  "secondary": 18m,
  "tertiary": 15m,
  "residential": 12m,
  "unclassified": 12m,
  "living_street": 10m,
  "default": 15m
}
```

**To change:**

```bash
# Example: Increase residential from 12m to 15m
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
UPDATE runmap.settings
SET value = jsonb_set(
  value,
  '{residential}',
  '15'
)
WHERE key = 'buffer_config';
EOF

# MUST rebuild ALL coverage (buffer changes require reprocessing)
ssh runmap
cd /home/mark/runmap
bash scripts/rebuild_all_coverage.sh
exit
```

⚠️ **Warning:** Changing buffers requires rebuilding ALL coverage from scratch. Takes ~5-10 minutes.

**When to change buffers:**
- GPS is consistently off (increase buffer)
- Getting false positives on parallel streets (decrease buffer)
- Sidewalk runs not being captured (increase buffer)

---

## Maintenance Tasks

### Clear Test/Bad Runs

If you accidentally uploaded a bad GPX file:

```bash
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
-- List all runs
SELECT id, filename, uploaded_at FROM runmap.runs_raw ORDER BY uploaded_at DESC;

-- Delete a specific run (replace UUID)
DELETE FROM runmap.runs_raw WHERE id = 'your-uuid-here';
EOF

# Rebuild coverage after deletion
ssh runmap "cd /home/mark/runmap && bash scripts/rebuild_all_coverage.sh"
```

---

### Full System Rebuild

If something gets corrupted or you want to start fresh:

```bash
ssh runmap
cd /home/mark/runmap

# Rebuild everything from scratch
bash scripts/rebuild_all_coverage.sh

# Export fresh tiles
bash scripts/export_tiles_blocks.sh

exit
```

**Takes:** ~5-10 minutes depending on number of runs

---

### Check Disk Space

```bash
ssh runmap "df -h /home/mark/runmap"
```

**Typical usage:**
- GPX files: ~1-2MB per hour of running
- Database: ~50-100MB
- Tiles: ~1-2MB total

---

### Backup Your Data

```bash
# Backup database
ssh runmap "pg_dump -U runmap_user -h localhost runmap | gzip > ~/runmap_backup_$(date +%Y%m%d).sql.gz"

# Download backup
scp runmap:~/runmap_backup_*.sql.gz ~/Backups/

# Backup GPX files
rsync -av runmap:/home/mark/runmap/gpx/ ~/Backups/runmap_gpx/
```

---

## Troubleshooting

### Map Not Updating After Upload

1. **Check API status:**
   - Open https://runmap.chouinard.me
   - Look for "API: Connected" in top left
   - If offline, check server: `ssh runmap "sudo systemctl status runmap-api"`

2. **Hard refresh browser:**
   - Mac: `Cmd + Shift + R`
   - Windows: `Ctrl + Shift + R`

3. **Check tiles were generated:**
   ```bash
   ssh runmap "ls -lh /var/www/runmap/tiles/"
   ```
   Should show recent timestamps on .pmtiles files

4. **Check tile serving:**
   ```bash
   curl -I https://runmap.chouinard.me/tiles/streets_incomplete.pmtiles
   ```
   Should return `200 OK`

---

### Coverage Looks Wrong

1. **Check completion threshold:**
   ```bash
   psql -h 192.168.68.25 -U runmap_user -d runmap \
     -c "SELECT value FROM runmap.settings WHERE key = 'completion_threshold_pct';"
   ```

2. **Check buffer settings:**
   ```bash
   psql -h 192.168.68.25 -U runmap_user -d runmap \
     -c "SELECT value FROM runmap.settings WHERE key = 'buffer_config';"
   ```

3. **Rebuild coverage:**
   ```bash
   ssh runmap "cd /home/mark/runmap && bash scripts/rebuild_all_coverage.sh"
   ```

---

### Upload Failed

1. **Check file is valid GPX:**
   ```bash
   head -20 your_file.gpx
   ```
   Should start with `<?xml` and contain `<gpx>` tags

2. **Check disk space:**
   ```bash
   ssh runmap "df -h"
   ```

3. **Check API logs:**
   ```bash
   ssh runmap "sudo journalctl -u runmap-api -n 50"
   ```

---

## Quick Commands Cheat Sheet

```bash
# View recent runs
psql -h 192.168.68.25 -U runmap_user -d runmap \
  -c "SELECT filename, uploaded_at FROM runmap.runs_raw ORDER BY uploaded_at DESC LIMIT 10;"

# View overall stats
psql -h 192.168.68.25 -U runmap_user -d runmap \
  -c "SELECT * FROM runmap.coverage_stats_blocks;"

# Count blocks by status
psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT
  CASE
    WHEN coverage_pct >= (SELECT value::float FROM runmap.settings WHERE key = 'completion_threshold_pct')
    THEN 'complete'
    ELSE 'incomplete'
  END as status,
  COUNT(*) as blocks
FROM runmap.block_coverage_32610
GROUP BY status;
EOF

# Regenerate tiles
ssh runmap "cd /home/mark/runmap && bash scripts/export_tiles_blocks.sh"

# Full rebuild
ssh runmap "cd /home/mark/runmap && bash scripts/rebuild_all_coverage.sh"
```

---

## Environment Variables

If commands aren't working, check environment variables:

**On Server (`/home/mark/runmap/.env`):**
```bash
DATABASE_NAME=runmap
DATABASE_USER=runmap_user
DATABASE_PASSWORD=<password>
DATABASE_HOST=192.168.68.25
GPX_DIR=/var/www/runmap/gpx
TILES_DIR=/var/www/runmap/tiles
```

**On Mac (for local development):**
```bash
DB_HOST=192.168.68.25
DB_USER=runmap_user
DB_NAME=runmap
# Password: Set in ~/.pgpass (chmod 600)
```

---

## Support

- **Project docs:** `/Volumes/RunMap/docs/`
- **Database schema:** `/Volumes/RunMap/db/`
- **Scripts:** `/Volumes/RunMap/scripts/`
- **API code:** `/Volumes/RunMap/api/`

For issues, check:
1. This guide
2. [BLOCK_PERCENTAGE_MIGRATION.md](BLOCK_PERCENTAGE_MIGRATION.md) - System architecture
3. [CLAUDE.md](../CLAUDE.md) - Full technical reference
