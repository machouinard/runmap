# RunMap Architecture

## System Overview

RunMap is a geospatial web application for tracking running coverage across Sacramento streets. The system processes GPX tracks using an **incremental block-based coverage calculation** that scales to handle unlimited runs with constant memory usage.

**Key Innovation:** Incremental coverage processing - only updates blocks touched by each new run instead of recalculating everything, enabling O(streets touched) memory usage regardless of total run count.

## Components

### 1. Database Layer (PostgreSQL 16 + PostGIS 3)

#### Core Tables

**`runmap.runs_raw`**
- Stores individual GPX track geometries (immutable history)
- Fields:
  - `id` (UUID): Primary key
  - `filename` (TEXT): Original GPX filename
  - `uploaded_at` (TIMESTAMPTZ): Upload timestamp
  - `start_time` (TIMESTAMPTZ): Workout start time
  - `duration_seconds` (INTEGER): Workout duration
  - `distance_km` (NUMERIC): Calculated distance
  - `geom` (GEOMETRY MultiLineString, 4326): GPS track
  - `location` (TEXT): Auto-detected location (sacramento, portland, other)
  - `total_distance_m` (DOUBLE PRECISION): Distance in meters (UTM calculation)
  - `workout_hash` (TEXT): Deduplication hash (date+time in 10-min buckets)
  - `activity_type` (TEXT): 'run', 'walk', or 'cycle'
- Unique constraint on `workout_hash` prevents duplicates
- Never deleted (append-only)

**`runmap.walks_raw`, `runmap.cycling_raw`**
- Same schema as `runs_raw` for walks and cycling activities
- Unified via `all_activities` view

**`runmap.streets_reference` (EPSG:4326)**
- OSM street network baseline for Sacramento
- Fields: `gid`, `osm_id`, `name`, `highway`, `geom`, `runnable`
- Excludes `highway = 'service'` (alleys not tracked)

**`runmap.streets_reference_32610` (EPSG:32610 UTM)**
- UTM-projected streets with precomputed lengths
- Fields: `ogc_fid`, `name`, `highway`, `geom_32610`, `total_length_m`
- Used for all distance calculations

**`runmap.runs_buffered_32610`**
- Per-run 10m buffers in UTM (one row per run)
- Fields: `run_id` (UUID), `geom` (MULTIPOLYGON, 32610)
- No global union needed - incremental approach

#### Incremental Coverage Tables

**`runmap.street_coverage_32610`**
- **Incremental coverage state** (one row per street)
- Fields:
  - `ogc_fid`: Street ID (references streets_reference_32610)
  - `covered_geom`: Accumulated covered geometry (union of all intersections)
  - `covered_length_m`: Total covered length
  - `total_length_m`: Street total length
- Updated only for streets touched by each new run
- Coverage percentage: `covered_length_m / total_length_m * 100`

**`runmap.block_coverage_32610`**
- **Incremental block-level coverage** (one row per 100m street block)
- Fields:
  - `id`: Block ID
  - `ogc_fid`: Parent street ID
  - `block_geom`: 100m segment geometry
  - `covered_geom`: Accumulated covered geometry
  - `block_length_m`: Block length (~100m)
  - `covered_length_m`: Covered length within block
- Completion threshold: ≥90% coverage
- Enables fine-grained progress tracking

**`runmap.settings`**
- Configuration key-value store (JSONB)
- `buffer_distance_m`: GPS buffer radius (default: 10m)
- `tiles_version`: Cache-busting timestamp for map tiles

#### Views & Materialized Views

**`runmap.all_activities`** (VIEW)
- Union of runs_raw, walks_raw, cycling_raw
- Used for cross-activity queries

**`runmap.coverage_stats_blocks`** (MATERIALIZED VIEW)
- Overall coverage statistics
- Fields: `total_blocks`, `incomplete_blocks`, `complete_blocks`, `total_length_m`, `covered_length_m`, `overall_coverage_pct`, `block_completion_pct`
- Refreshed after each import

**Street Status Views:**
- `runmap.streets_incomplete` - Blocks with <90% coverage
- `runmap.streets_complete` - Blocks with ≥90% coverage
- Used for tile generation (incomplete=purple, complete=green)

**`runmap.streets_most_complete`** (VIEW)
- Top streets by completion percentage
- Used for stats display

#### Core Functions

**`runmap.buffer_one_run(run_id UUID)`**
- Creates 10m buffer for single run in UTM
- Inserts to `runs_buffered_32610`
- Fast: O(points in run)

**`runmap.apply_run_to_block_coverage(run_id UUID)`**
- **Incremental coverage update** - only touches intersecting blocks
- For each block intersecting the run buffer:
  - Calculate intersection geometry
  - If first coverage: store intersection as `covered_geom`
  - If already partial: union new intersection with existing coverage
  - Update `covered_length_m`
- Fast: O(blocks touched by run) - typically 50-100 blocks per run
- Memory efficient: No global geometry operations

**`runmap.detect_location(geom GEOMETRY)`**
- Auto-detects location from GPS track centroid
- Returns: 'sacramento', 'portland', or 'other'
- Uses geographic bounding boxes:
  - Sacramento: Lat 38.4-38.7, Lon -121.6 to -121.3
  - Portland: Lat 45.4-45.7, Lon -122.8 to -122.5

**`runmap.auto_process_new_run()` (TRIGGER)**
- Automatically fires AFTER INSERT on `runs_raw`
- Calls `buffer_one_run()` and `apply_run_to_block_coverage()`
- Refreshes `coverage_stats_blocks`
- Enables zero-config uploads

### 2. API Layer (Flask)

**Endpoints:**

**`GET /api/health`**
- Returns API status and database connectivity
- Response: `{status: 'healthy', database: 'connected'}`

**`GET /api/tiles/version`**
- Returns current tiles version for cache busting
- Response: `{version: <timestamp>}`
- Frontend polls this to detect tile updates

**`GET /api/stats`**
- Coverage statistics and top streets
- Response: `{total_runs, total_km, coverage: {...}, top_streets: [...]}`

**`POST /api/upload`**
- Accepts GPX file upload
- **Duplicate detection**: Calculates `workout_hash` from GPX before import
- **Hash strategy**: `SHA256(start_time rounded to 10-min bucket)`
  - Example: Run starting at 16:47:19 → bucket "2025-10-19 16:40"
  - Detects same workout from different apps (WorkoutDoors, Apple Health, Strava)
  - Tolerates timing differences (±5 minutes)
- Process flow:
  1. Parse GPX to calculate `workout_hash`
  2. Check database for existing hash
  3. If duplicate: return `{status: 'duplicate', existing: {...}}`
  4. If new: call `ingest_gpx.sh` (triggers auto-process)
  5. Export tiles asynchronously
  6. Return `{status: 'success', run: {...}, tiles_version}`
- Response includes location, distance, start_time for iOS shortcut

### 3. Processing Scripts

#### `scripts/ingest_gpx.sh`
- Imports single GPX file to `runs_raw`
- Calculates `workout_hash` (date+time in 10-min buckets)
- Uses Python with `gpxpy` for parsing
- Inserts with `ON CONFLICT (workout_hash) DO NOTHING`
- Trigger automatically processes buffer and coverage

#### `scripts/bulk_import.sh`
- Imports directory of GPX files
- Disables `trigger_auto_process_run` during import
- Imports all files via `ingest_gpx.sh`
- Re-enables trigger
- Manually processes all new runs in batch
- Refreshes coverage stats
- Does NOT export tiles (run separately)

#### `scripts/export_tiles_blocks.sh`
- Exports PMTiles for map display
- Generates 3 layers:
  - `runs.pmtiles` - All running tracks (red lines)
  - `streets_incomplete.pmtiles` - <90% coverage blocks (purple)
  - `streets_complete.pmtiles` - ≥90% coverage blocks (green)
- Pipeline: PostGIS → GeoJSON → Tippecanoe → PMTiles
- Updates `tiles_version` in database
- Runtime: ~30 seconds

#### `scripts/delete_recent_20_runs.sh [N]`
- Deletes N most recent runs **by run date** (start_time), not upload date
- Rebuilds coverage after deletion
- Used for development/testing

### 4. Web Server (Nginx)

**Configuration:**

```nginx
location / {
    root /var/www/runmap;
    try_files $uri $uri/ /index.html;
}

location /api/ {
    proxy_pass http://localhost:5000;
    proxy_set_header Host $host;
}

location /tiles/ {
    alias /home/mark/runmap/tiles/;
    add_header Access-Control-Allow-Origin *;
    types {
        application/vnd.pmtiles pmtiles;
    }
}
```

**Responsibilities:**
- Serve React frontend (static files)
- Proxy API requests to Flask
- Serve PMTiles with CORS headers
- SSL termination (Let's Encrypt)

### 5. Frontend (React + MapLibre GL JS)

**Features:**
- MapLibre GL JS map (center: Sacramento)
- PMTiles layer loading via `pmtiles` protocol
- Layers:
  - Runs (red lines, z4-14)
  - Complete blocks (green, ≥90% coverage)
  - Incomplete blocks (purple, <90% coverage)
- GPX upload form with drag-and-drop
- Coverage statistics display
- Auto-reload on tile version change (polls `/api/tiles/version` every 30s)
- Duplicate detection feedback
- Location and distance display

## Data Flow

### Upload Flow (iOS Shortcut / Web)

```
User uploads GPX
    ↓
Nginx → Flask API
    ↓
Parse GPX, calculate workout_hash
    ↓
Check database for duplicate
    ├─ Duplicate found → return {status: 'duplicate'}
    └─ New run → continue
    ↓
Save to /var/www/runmap/gpx/
    ↓
ingest_gpx.sh
    ↓
INSERT to runs_raw (with workout_hash)
    ↓
TRIGGER: auto_process_new_run()
    ├─ buffer_one_run(run_id)
    │   └─ Insert to runs_buffered_32610
    ├─ apply_run_to_block_coverage(run_id)
    │   └─ Update only intersecting blocks
    └─ REFRESH coverage_stats_blocks
    ↓
export_tiles_blocks.sh (async)
    ├─ Export runs.pmtiles
    ├─ Export streets_incomplete.pmtiles
    ├─ Export streets_complete.pmtiles
    └─ Update tiles_version
    ↓
Frontend polls /api/tiles/version
    ↓
Detects change → reloads map tiles
```

### Bulk Import Flow

```
Run bulk_import.sh <directory>
    ↓
DISABLE TRIGGER trigger_auto_process_run
    ↓
For each GPX file:
    ├─ Calculate workout_hash
    ├─ Check for duplicate
    ├─ If new: call ingest_gpx.sh
    └─ Count: SUCCESS/DUPLICATE/ERROR
    ↓
RE-ENABLE TRIGGER
    ↓
Get all run IDs without buffers
    ↓
For each new run:
    ├─ buffer_one_run(run_id)
    └─ apply_run_to_block_coverage(run_id)
    ↓
REFRESH coverage_stats_blocks
    ↓
(Manually run export_tiles_blocks.sh)
```

## Coordinate Systems

- **Storage**: EPSG:4326 (WGS84) - runs_raw, streets_reference
- **Calculations**: EPSG:32610 (UTM Zone 10N) - all distance/buffer operations
- **Display**: EPSG:3857 (Web Mercator) - MapLibre GL JS

**Why UTM for calculations?**
- Accurate meter-based buffering (10m buffer = exactly 10 meters)
- Accurate distance calculations (`ST_Length` in meters)
- WGS84 degrees would be inaccurate for Sacramento's latitude

## Performance Characteristics

### Memory Usage
- **Old system**: O(all runs × all streets) → 112GB RAM with 11 runs (crashed)
- **New system**: O(streets touched by new run) → ~3GB RAM regardless of run count
- Server (20GB RAM) can now handle uploads without Mac Studio

### Processing Time
- Single run import: ~2-5 seconds (buffer + coverage update for ~50-100 blocks)
- Bulk import (20 runs): ~2-3 minutes
- Tile export: ~30 seconds
- Coverage refresh: instant (materialized view query)

### Scalability
- **Runs**: Unlimited (incremental processing, constant memory per run)
- **Streets**: ~8,000 streets, ~80,000 blocks (100m each) - sub-second queries
- **Concurrent uploads**: Single-threaded currently, could parallelize tile export

## Deduplication Strategy

### Workout Hash Algorithm

**Goal:** Detect same workout from different export sources (WorkoutDoors, Apple Health, Strava, etc.)

**Problem with naive approaches:**
- File content hash: Different apps export different metadata → different hashes
- Start time + duration: Apps record slightly different times (±1-2 seconds, ±30-60 seconds)
- Date + hour only: Multiple runs per day collision (e.g., 9am, 10am, 11am)
- Date + location + distance: GPS differences cause hash mismatches

**Solution: Date + Time in 10-minute buckets**

```python
# Round start time to nearest 10 minutes
minute_bucket = (start_time.minute // 10) * 10
workout_datetime = start_time.strftime(f"%Y-%m-%d %H:{minute_bucket:02d}")
workout_hash = hashlib.sha256(workout_datetime.encode()).hexdigest()
```

**Examples:**
- Run at 16:47:19 → bucket "2025-10-19 16:40" → hash `SHA256("2025-10-19 16:40")`
- Run at 16:40:53 → bucket "2025-10-19 16:40" → **same hash** ✅
- Run at 16:14:19 → bucket "2025-10-19 16:10" → **different hash** ✅

**Benefits:**
- ✅ Detects same workout from different apps
- ✅ Tolerates ±5 minute timing differences
- ✅ Handles multiple runs per day (different 10-min buckets)
- ✅ Simple to understand and debug
- ✅ Fast to calculate (no GPS parsing needed)

**Edge case:** Two runs starting in same 10-min window from same user
- Probability: Very low (user would need to start runs <10 min apart)
- Impact: Second run rejected as duplicate
- Mitigation: User can manually adjust one file's timestamp if needed

## Error Handling

### API
- 400: Invalid file type, missing file, no timestamps in GPX
- 500: Processing errors (GPX parsing, database errors)
- Returns JSON: `{status: 'error', error: <message>, code: <ERROR_CODE>}`

### Scripts
- `set -e`: Exit on any error
- Transaction-based imports (rollback on failure)
- Duplicate handling: `ON CONFLICT DO NOTHING`

### Database
- Unique constraint on `workout_hash` prevents duplicates at DB level
- Foreign key constraints ensure referential integrity
- Triggers use `PERFORM` for void returns

## Security

### Authentication
- No authentication currently implemented
- **TODO**: Add API key or JWT-based auth for production

### File Upload
- Filename sanitization via `werkzeug.secure_filename`
- File type validation (must end in .gpx)
- Saved to dedicated directory `/var/www/runmap/gpx/`

### Database
- Dedicated user `runmap_user` with limited permissions
- Password stored in `~/.pgpass` (not in code)
- Connection via localhost or server IP (no public access)

## Monitoring

### Health Checks
- `/api/health`: Database connectivity + API status
- Frontend displays connection status

### Logs
- API: `journalctl -u runmap-api -f`
- Nginx: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`
- PostgreSQL: `/var/log/postgresql/postgresql-16-main.log`

## Deployment

### Server Environment
- **OS**: Ubuntu 24.04 LTS
- **IP**: 192.168.68.25 (local network)
- **Domain**: runmap.chouinard.me (public)
- **RAM**: 20GB
- **SSH**: Port 2222

### Systemd Services

**runmap-api.service:**
- Runs Flask API on port 5000
- Auto-restart on failure
- Environment variables from `/home/mark/runmap/api/.env`

### Directories
- Code: `/home/mark/runmap/`
- GPX storage: `/var/www/runmap/gpx/`
- Tiles: `/home/mark/runmap/tiles/`
- Frontend: `/var/www/runmap/` (build output)
- Scripts: `/home/mark/runmap/scripts/`
- Database: `/home/mark/runmap/db/`

## Future Enhancements

### Short Term
- Add authentication (API keys)
- Implement activity classification (run vs walk vs cycle)
- Add time-based filtering (runs by date range)
- Heatmap visualization

### Long Term
- Neighborhood-based coverage stats
- Multi-city support (expand beyond Sacramento)
- Strava/Garmin integration
- Multi-user support
- Mobile app for uploads

### Infrastructure
- **Cloudflare R2 for PMTiles**: Offload tile serving, CDN distribution
- **Automated backups**: GPX files + database dumps
- **Monitoring**: Prometheus + Grafana for metrics
