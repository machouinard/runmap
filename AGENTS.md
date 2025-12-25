# AGENTS.md - AI Assistant Context

This file helps AI assistants understand the project structure and common commands.

## Project Overview

Runmap is a running coverage tracker for Sacramento streets using PostGIS, Flask API, and vector tiles.

## Common Commands

### Database

```bash
# Connect to database
psql -U runmap_user -d runmap -h localhost

# Run schema setup
psql -U runmap_user -d runmap -h localhost -f /home/mark/runmap/db/01_create_tables.sql
psql -U runmap_user -d runmap -h localhost -f /home/mark/runmap/db/02_create_views.sql

# Check coverage stats
psql -U runmap_user -d runmap -c "SELECT * FROM runmap.coverage_stats;"

# Count runs
psql -U runmap_user -d runmap -c "SELECT COUNT(*) FROM runmap.runs_raw;"

# Refresh materialized views manually
psql -U runmap_user -d runmap << EOF
REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.runs_merged;
REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_buffer;
REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.streets_unrun;
REFRESH MATERIALIZED VIEW CONCURRENTLY runmap.coverage_stats;
EOF
```

### API Service

```bash
# Manage API service
sudo systemctl status runmap-api
sudo systemctl start runmap-api
sudo systemctl stop runmap-api
sudo systemctl restart runmap-api

# View logs
sudo journalctl -u runmap-api -f
sudo journalctl -u runmap-api -n 50

# Test health endpoint
curl https://runmap.chouinard.me/api/health
```

### Processing Pipeline

```bash
# Upload GPX
curl -X POST https://runmap.chouinard.me/api/upload -F "file=@/path/to/run.gpx"

# Or upload locally
curl -X POST http://localhost:5000/api/upload -F "file=@/path/to/run.gpx"

# Manual GPX ingestion
bash /home/mark/runmap/scripts/ingest_gpx.sh /home/mark/runmap/gpx/run.gpx

# Run fast path (runs.pmtiles only)
bash /home/mark/runmap/scripts/fast_path.sh

# Run slow path (coverage + unrun streets)
bash /home/mark/runmap/scripts/slow_path.sh

# Trigger coverage refresh via API
curl -X POST https://runmap.chouinard.me/api/refresh-coverage
```

### Tiles

```bash
# List generated tiles
ls -lh /home/mark/runmap/tiles/*.pmtiles

# Show tile metadata
pmtiles show /home/mark/runmap/tiles/runs.pmtiles
pmtiles show /home/mark/runmap/tiles/coverage.pmtiles
pmtiles show /home/mark/runmap/tiles/streets_unrun.pmtiles

# Test tile serving
curl -I https://runmap.chouinard.me/tiles/runs.pmtiles
curl -I https://runmap.chouinard.me/tiles/coverage.pmtiles
curl -I https://runmap.chouinard.me/tiles/streets_unrun.pmtiles
```

### Nginx

```bash
# Reload nginx config
sudo nginx -t
sudo systemctl reload nginx

# View logs
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log

# Check nginx status
sudo systemctl status nginx
```

### Development

```bash
# Activate Python venv
cd /home/mark/runmap/api
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Run API locally
python app.py

# Deactivate venv
deactivate
```

## File Locations

### Important Paths
- **Project Root**: `/home/mark/runmap/`
- **GPX Storage**: `/home/mark/runmap/gpx/`
- **Generated Tiles**: `/home/mark/runmap/tiles/`
- **Scripts**: `/home/mark/runmap/scripts/`
- **Database Schema**: `/home/mark/runmap/db/`
- **API**: `/home/mark/runmap/api/`
- **Web Root**: `/var/www/runmap/`

### Configuration Files
- **Nginx Site**: `/etc/nginx/sites-available/runmap`
- **Systemd Service**: `/etc/systemd/system/runmap-api.service`
- **Environment**: `/home/mark/runmap/api/.env`
- **MIME Types**: `/etc/nginx/mime.types` (added `application/vnd.pmtiles pmtiles;`)

## Code Style & Conventions

### Database
- Schema name: `runmap`
- Primary keys: `gid` (materialized views), `ogc_fid` (tables from ogr2ogr)
- Geometry SRID: 4326 (WGS84)
- Buffering SRID: 32610 (UTM Zone 10N)
- Use `IF NOT EXISTS` for views/tables
- Use `CONCURRENTLY` for materialized view refreshes
- All tables and views in `runmap` schema

### Python/Flask
- Use environment variables for configuration
- Secure filenames with `werkzeug.secure_filename`
- JSON responses for all API endpoints
- Error handling with try/except, return 500 on errors
- Use subprocess.Popen for async tasks, subprocess.run for blocking

### Shell Scripts
- Set `set -e` for fail-fast behavior
- Use `$TMP_DIR` and `$TILES_DIR` environment variables
- Clean up temp files after processing
- Use tippecanoe `--force` flag to overwrite tiles
- Do NOT use `-overwrite` with ogr2ogr SQL queries (causes errors)

### Tiles
- Format: PMTiles (single-file vector tiles)
- Zoom levels: `-Z4 -z14` (min 4, max 14)
- Layers:
  - `runs`: All running tracks
  - `coverage`: Buffer polygon showing covered areas
  - `streets_unrun`: Streets not yet run

## Testing Checklist

### After GPX Upload
1. Check API logs: `sudo journalctl -u runmap-api -f`
2. Verify file saved: `ls -lh /home/mark/runmap/gpx/`
3. Check database: `psql -U runmap_user -d runmap -c "SELECT COUNT(*) FROM runmap.runs_raw;"`
4. Wait 30s, check tiles updated: `ls -lh /home/mark/runmap/tiles/runs.pmtiles`
5. Verify tiles version: `psql -U runmap_user -d runmap -c "SELECT * FROM runmap.settings WHERE key='tiles_version';"`

### After Coverage Refresh
1. Check slow path logs: `tail -f /var/log/runmap-slow-path.log` (if using cron)
2. Verify materialized views: `psql -U runmap_user -d runmap -c "\d+ runmap.streets_unrun"`
3. Check coverage stats: `psql -U runmap_user -d runmap -c "SELECT * FROM runmap.coverage_stats;"`
4. Verify tiles generated: `ls -lh /home/mark/runmap/tiles/{coverage,streets_unrun}.pmtiles`

## Known Issues & Solutions

### Issue: "Permission denied" on GPX upload
**Solution:**
```bash
sudo chown -R mark:www-data /home/mark/runmap/gpx
sudo chmod 775 /home/mark/runmap/gpx
```

### Issue: Materialized view refresh fails (can't refresh concurrently)
**Solution:** View needs unique index:
```sql
CREATE UNIQUE INDEX viewname_id_uidx ON runmap.viewname(id);
```

### Issue: ogr2ogr "-overwrite" fails with SQL queries
**Solution:** Remove `-overwrite` flag, delete files manually before export:
```bash
rm -f /tmp/coverage.geojson /tmp/streets_unrun.geojson
```

### Issue: Coverage percentage too high (counts full streets)
**Solution:** Use `ST_Intersection` to measure only covered portions:
```sql
ST_Length(ST_Intersection(s.geom, cb.geom)::geography) AS covered_length_m
```

### Issue: Emoji rendering as garbage characters
**Solution:** Remove emoji or ensure proper UTF-8 font support in frontend

## Architecture Notes

### Two-Path Pipeline
- **Fast Path**: Runs on every upload, ~30s, generates runs.pmtiles only
- **Slow Path**: Manual/scheduled, ~5min, regenerates coverage + unrun streets

### Materialized Views Dependency Chain
1. `runs_merged` ← depends on `runs_raw`
2. `coverage_buffer` ← depends on `runs_merged`
3. `streets_unrun` ← depends on `runs_merged` + `streets_reference`
4. `coverage_stats` ← depends on `coverage_buffer` + `streets_reference`

### Coverage Calculation
- Uses 20m buffer (configurable in `runmap.settings`)
- Transforms to UTM for accurate meter-based buffering
- Simplifies geometry for performance
- Calculates intersection length, not full street length

## Environment Variables

Set in `/etc/systemd/system/runmap-api.service`:
```ini
Environment="GPX_DIR=/home/mark/runmap/gpx"
Environment="TILES_DIR=/home/mark/runmap/tiles"
Environment="SCRIPTS_DIR=/home/mark/runmap/scripts"
```

## Future Development

### Planned Features
- ✅ React + MapLibre GL JS frontend (basic)
- ✅ PMTiles layer loading and display
- User authentication (API keys or JWT)
- Neighborhood-based coverage stats
- Time-based filtering
- Strava/Garmin integration

### Infrastructure Options
- **Cloudflare R2 for PMTiles**
  - Cost: ~$0.015/GB/month (free for current <1MB tiles)
  - Benefits: CDN, no egress fees, offload bandwidth
  - Setup: rclone to sync tiles after generation
  - See docs/DEPLOYMENT.md for instructions

- **Coverage Processing**
  - Current server (20GB RAM) can only handle `slow_path_minimal.sh` (runs only)
  - Full coverage requires: Mac Studio OR server RAM upgrade to 32GB+
  
### TODO Items
- [ ] Add authentication to API
- [ ] Implement neighborhood stats (requires more RAM or Mac processing)
- [ ] Add automated tests
- [ ] Set up CI/CD pipeline
- [ ] Create mobile app for uploads
- [ ] Optional: Setup Cloudflare R2 for tiles
