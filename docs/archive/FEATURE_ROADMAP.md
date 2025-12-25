# Feature Roadmap

**Created**: 2025-10-19
**Updated**: 2025-10-19 (Revised for production scale)
**Status**: Planning Phase
**Current Coverage**: 24.0% (624/2,597 blocks complete - 7 runs imported)

## Production Scale Context

**IMPORTANT**: This roadmap is optimized for **production scale**, not small development datasets:

- **Current**: 7 runs (development testing)
- **Ready to Import**: 125 runs + ~300 walks from 600+ total routes (50/50 split assumed)
- **Growth Rate**: 3-5 runs + 1-3 walks per week = ~250 activities/year
- **1-Year Projection**: 250-375 runs, 500+ walks
- **2-Year Projection**: 500-700 runs, 1000+ walks

This scale significantly affects implementation priorities and architectural decisions.

---

This document outlines the planned feature enhancements for RunMap, organized by implementation priority. Each feature includes complexity analysis, technical approach, and learning resources.

---

## Implementation Tiers

**CRITICAL NOTE**: With 125 runs + 300 walks ready to import, **Feature #2 (Run/Walk Detection) must be implemented BEFORE bulk import**. Otherwise, 300 walks will corrupt coverage data.

---

### Tier 1: Data Quality & Foundation (MUST DO BEFORE BULK IMPORT)

#### 1. Run vs Walk Detection **← IMPLEMENT FIRST**

**Priority**: **CRITICAL** - Must complete before importing 600+ routes
**Complexity**: Low-Medium (3-4 hours)
**Status**: Not implemented

**Why This is Now #1 Priority**:
- You have ~300 walks in your 600 routes waiting to import
- Importing walks as runs would **completely corrupt** coverage statistics
- Retroactively cleaning up walks from `runs_raw` is extremely painful
- This is a **blocking requirement** for bulk import

**What You'll Learn**:
- GPX structure (trackpoints, timestamps, distances)
- Calculating pace from GPS data
- Python GPX parsing with `gpxpy` library
- Database schema design (separate tables)

**Technical Background**:

Running vs walking is distinguished by **average pace**:
- **Walking pace**: >12 min/mile (>7.5 min/km) or <4.0 mph (<6.4 km/h)
- **Running pace**: ≤12 min/mile or ≥4.0 mph
- **Edge cases**:
  - Runs with walk breaks (e.g., 13 min/mile average) → classify as run if any segment is <10 min/mile
  - Very short tracks (<0.5 miles) → may be GPS tests, not real activities

**Implementation Plan**:

1. **Create Walks Table** (`db/12_walks_table.sql`):
```sql
CREATE TABLE runmap.walks_raw (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  filename TEXT NOT NULL,
  uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  geom geometry(MultiLineString, 4326),
  content_hash TEXT UNIQUE NOT NULL,
  avg_pace_min_per_mile FLOAT,  -- For analysis
  total_distance_m FLOAT,
  duration_seconds INT
);

CREATE INDEX idx_walks_geom ON runmap.walks_raw USING GIST(geom);
CREATE INDEX idx_walks_uploaded_at ON runmap.walks_raw(uploaded_at);  -- For date queries
```

2. **Add Pace Calculation Function** (`scripts/detect_activity_type.py`):
```python
import gpxpy
from datetime import datetime

def analyze_gpx(file_path):
    """
    Returns: {
        'type': 'run' | 'walk',
        'avg_pace_min_per_mile': float,
        'total_distance_m': float,
        'duration_seconds': int,
        'fastest_mile_pace': float  # For detecting run segments
    }
    """
    # Parse GPX, calculate pace per segment
    # If any mile is <10 min/mile → run
    # Otherwise use average pace
```

3. **Update Ingest Script** (`scripts/ingest_gpx.sh`):
```bash
# Before ogr2ogr, detect activity type
ACTIVITY_TYPE=$(python scripts/detect_activity_type.py "$GPX_FILE")

if [ "$ACTIVITY_TYPE" = "walk" ]; then
  # Import to walks_raw instead
  ogr2ogr -f PostgreSQL ... -nln runmap.walks_raw ...
  echo "Imported as walk"
else
  # Existing run import logic
  ogr2ogr -f PostgreSQL ... -nln runmap.runs_raw ...
  echo "Imported as run"
fi
```

4. **Update API Response**:
```python
return jsonify({
    'import_result': 'success_run' | 'success_walk' | 'duplicate' | 'error',
    'activity_type': 'run' | 'walk',
    'message': 'Run imported' | 'Walk imported (not counted in coverage)' | ...,
    'avg_pace_min_per_mile': 8.5,
    'distance_miles': 5.2
})
```

**Learning Resources**:
- GPX format: https://www.topografix.com/gpx.asp
- `gpxpy` library: https://github.com/tkrajina/gpxpy
- Pace calculation: `time / distance` (convert to min/mile)

**Testing Scenarios**:
- Upload easy run (9 min/mile) → should classify as run
- Upload long run with walk breaks (12.5 min/mile avg) → classify as run if any mile <10 min/mile
- Upload walking track (15 min/mile) → should classify as walk, not affect coverage

**Bulk Import Testing**:
- Process sample of 10 routes (5 known runs, 5 known walks)
- Verify classification accuracy before processing all 600 routes
- Check database: walks go to `walks_raw`, runs go to `runs_raw`

**Future Enhancements** (Tier 3+):
- View walks on separate map layer (toggle on/off)
- Calculate walking coverage separately
- Detect other activities (cycling, hiking) by speed

---

#### 2. Bulk Import Script (Optimized for 100+ Routes)

**Priority**: CRITICAL - Needed immediately after walk detection
**Complexity**: Low-Medium (2-3 hours)
**Status**: Not implemented

**Why This is Important**:
- Current manual process: ~2-3 minutes per run × 125 runs = **5-6 hours**
- Optimized bulk process: **~30-40 minutes for 300 runs**
- Auto-trigger (from `db/11_auto_process_trigger.sql`) is inefficient for bulk imports:
  - Refreshes `coverage_stats_blocks` 125 times (wasteful)
  - Better: Disable trigger, import all, rebuild once

**Implementation Plan**:

**Script**: `scripts/bulk_import_runs.sh`

```bash
#!/bin/bash
# Bulk import optimized for 100+ GPX files

# 1. Disable auto-process trigger (optimization)
DROP TRIGGER IF EXISTS trigger_auto_process_run ON runmap.runs_raw;

# 2. Import all GPX files (with walk detection)
for GPX_FILE in "$@"; do
  bash scripts/ingest_gpx.sh "$GPX_FILE"
  # Activity type detection happens in ingest_gpx.sh
done

# 3. Buffer all new runs (only runs, not walks)
SELECT runmap.buffer_one_run(id) FROM runmap.runs_raw WHERE id NOT IN (SELECT run_id FROM runmap.runs_buffered_32610);

# 4. Rebuild coverage (one pass, all runs)
SELECT runmap.rebuild_block_coverage();

# 5. Refresh stats (once at end)
REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;

# 6. Re-enable auto-process trigger
psql -f db/11_auto_process_trigger.sql

# 7. Export tiles
bash scripts/export_tiles_blocks.sh
```

**Performance Estimates** (125 runs + 300 walks):
- **Activity detection**: ~1 second per file × 425 files = **7 minutes**
- **Import to database**: ~2 seconds per file × 425 files = **14 minutes**
- **Buffering**: ~5 seconds per run × 125 runs = **10 minutes**
- **Coverage rebuild**: ~10 minutes (one-time cost)
- **Tile export**: ~5-8 minutes (with 125 runs)
- **Total**: ~45-55 minutes

**Testing Strategy**:
1. Test with 10 files first (5 runs, 5 walks)
2. Verify correct classification and database routing
3. Run full bulk import on all 600 routes
4. Validate coverage stats look reasonable

---

#### 3. Tile Export Optimization (Geometry Simplification)

**Priority**: HIGH - Needed before bulk import
**Complexity**: Low (1-2 hours)
**Status**: Not implemented

**Why This is Important**:

Current tile export performance:
- 7 runs: ~60 seconds
- 125 runs (projected): ~5-8 minutes
- 250 runs (1 year): ~15-20 minutes
- 500 runs (2 years): ~30-40 minutes

Current file sizes (with full GPS density):
- 7 runs: ~350KB
- 125 runs (projected): **~6MB** (slow on mobile)
- 250 runs: **~12MB** (unacceptable)
- 500 runs: **~25MB** (unusable)

**Solution: Simplify Geometry**

GPX tracks have 1 point per second (~3600 points for 10-mile run). For map display, we only need 1 point per 10-20 meters.

**Implementation**:

Modify `scripts/export_tiles_blocks.sh`:

```bash
# OLD (full detail):
ogr2ogr -f GeoJSON "$TMP_DIR/runs.geojson" \
  PG:"..." \
  -sql "SELECT id, filename, uploaded_at, ST_Transform(geom, 4326) as geometry FROM runmap.runs_raw"

# NEW (simplified):
ogr2ogr -f GeoJSON "$TMP_DIR/runs.geojson" \
  PG:"..." \
  -sql "SELECT
    id,
    filename,
    uploaded_at,
    ST_Transform(ST_Simplify(geom, 0.0001), 4326) as geometry
  FROM runmap.runs_raw"
```

**ST_Simplify tolerance values**:
- `0.0001` (WGS84 degrees) ≈ 10m resolution → **70-80% size reduction**
- `0.00005` ≈ 5m resolution → **50-60% size reduction**
- Too aggressive = jagged corners, missed turns

**Results After Optimization**:
- 125 runs: **6MB → 1.5MB** (acceptable on mobile)
- 250 runs: **12MB → 3MB** (good)
- 500 runs: **25MB → 6MB** (manageable)

**Testing**:
- Export tiles with simplified geometry
- View on map, verify runs still look smooth
- Check file sizes match expectations
- Zoom in to verify detail is sufficient

**Future Enhancement**: Use different simplification levels per zoom (z4-z10 = more simplified, z11-z14 = more detail)

---

#### 4. Cloudflare R2 Integration (CDN + Zero Egress Costs)

**Priority**: HIGH - Implement before bulk import
**Complexity**: Low-Medium (1-2 hours)
**Status**: Not implemented

**Why This is Critical**:

Serving PMTiles from Cloudflare R2 instead of your server provides:
- **Zero egress fees** (R2 doesn't charge for bandwidth out)
- **Global CDN edge caching** (faster loads worldwide)
- **Reduced server load** (tiles served by Cloudflare, not your server)
- **Better scalability** (R2 handles traffic spikes automatically)
- **Perfect for PMTiles** (HTTP Range Requests work natively)

**Cost Analysis**:

**Storage** (500 runs @ 6MB total):
- R2: $0.015/GB × 0.006 GB = **$0.00009/month** (negligible)

**Bandwidth** (assume 100 page loads/day):
- 100 loads/day × 30 days × 6MB = 18GB/month
- R2 egress: **$0** (free!)
- Self-hosted: $5-20/month depending on host
- **Annual savings**: $60-240

**At higher traffic** (1,000 loads/day):
- 180GB/month bandwidth
- R2: **Still $0 egress**
- Self-hosted: $50-100/month
- **Annual savings**: $600-1,200

**Architecture**:

```
BEFORE (Self-Hosted):
User → Nginx → PMTiles files on disk

AFTER (With R2):
User → Cloudflare R2 (Edge CDN) → PMTiles
       └─ Cached at edge locations globally

Server → Generate tiles → Upload to R2
```

**What You'll Learn**:
- Cloudflare R2 bucket setup
- S3-compatible API usage (R2 uses AWS S3 protocol)
- Custom domain configuration for R2
- boto3 or AWS CLI for uploads
- PMTiles serving from cloud storage

**Implementation Plan**:

**1. Create R2 Bucket** (~5 minutes):

Via Cloudflare Dashboard:
- Navigate to R2 → Create bucket
- Bucket name: `runmap-tiles`
- Location: Automatic (closest to your users)
- Generate API token (read/write permissions)
- Note: Account ID, Access Key ID, Secret Access Key

**2. Configure Custom Domain** (~5 minutes):

```
tiles.runmap.chouinard.me → R2 bucket: runmap-tiles
```

- R2 bucket settings → Custom domains → Add domain
- Cloudflare automatically:
  - Creates DNS CNAME record
  - Enables HTTPS (free SSL)
  - Configures CDN caching

**3. Install AWS CLI or boto3** (~2 minutes):

```bash
# Option A: AWS CLI
brew install awscli

# Option B: Python boto3 (if using Python scripts)
pip install boto3
```

**4. Configure R2 Credentials** (~2 minutes):

```bash
# ~/.aws/credentials (for AWS CLI)
[r2]
aws_access_key_id = <R2_ACCESS_KEY>
aws_secret_access_key = <R2_SECRET_KEY>

# Environment variables (for scripts)
export R2_ACCOUNT_ID=<account-id>
export R2_ACCESS_KEY=<access-key>
export R2_SECRET_KEY=<secret-key>
export R2_BUCKET=runmap-tiles
```

**5. Update Tile Export Script** (`scripts/export_tiles_blocks.sh`):

```bash
#!/bin/bash
set -e

# Existing tile generation (tippecanoe, etc.)
# ... (no changes to generation logic)

# NEW: Upload tiles to R2 after generation
echo "Uploading tiles to R2..."

R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

for TILE_FILE in tiles/*.pmtiles; do
  TILE_NAME=$(basename "$TILE_FILE")

  echo "  Uploading $TILE_NAME..."

  aws s3 cp "$TILE_FILE" "s3://${R2_BUCKET}/${TILE_NAME}" \
    --endpoint-url "$R2_ENDPOINT" \
    --profile r2 \
    --content-type "application/vnd.pmtiles" \
    --cache-control "max-age=3600" \
    --metadata "generated-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
done

echo "✅ Tiles uploaded to R2"
echo "📍 Access at: https://tiles.runmap.chouinard.me/"
```

**Alternative: Python Upload Script** (`scripts/upload_tiles_to_r2.py`):

```python
import boto3
import os
from pathlib import Path
from datetime import datetime

# Configure R2 client (S3-compatible)
s3 = boto3.client('s3',
    endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
    aws_access_key_id=os.environ['R2_ACCESS_KEY'],
    aws_secret_access_key=os.environ['R2_SECRET_KEY']
)

bucket = os.environ['R2_BUCKET']
tiles_dir = Path('tiles')

# Upload all PMTiles files
for tile_file in tiles_dir.glob('*.pmtiles'):
    print(f"Uploading {tile_file.name}...")

    s3.upload_file(
        str(tile_file),
        bucket,
        tile_file.name,
        ExtraArgs={
            'ContentType': 'application/vnd.pmtiles',
            'CacheControl': 'max-age=3600',  # 1 hour cache
            'Metadata': {
                'generated-at': datetime.utcnow().isoformat()
            }
        }
    )

print("✅ All tiles uploaded to R2")
print(f"📍 Access at: https://tiles.runmap.chouinard.me/")
```

**6. Update Frontend** (`web/build/index.html`):

```javascript
// OLD (self-hosted):
const runsUrl = 'pmtiles:///tiles/runs.pmtiles';

// NEW (R2 with CDN):
const R2_BASE_URL = 'https://tiles.runmap.chouinard.me';

map.addSource('runs', {
  type: 'vector',
  url: `pmtiles://${R2_BASE_URL}/runs.pmtiles`
});

map.addSource('coverage', {
  type: 'vector',
  url: `pmtiles://${R2_BASE_URL}/coverage.pmtiles`
});

map.addSource('blocks-incomplete', {
  type: 'vector',
  url: `pmtiles://${R2_BASE_URL}/streets_incomplete.pmtiles`
});

map.addSource('blocks-complete', {
  type: 'vector',
  url: `pmtiles://${R2_BASE_URL}/streets_complete.pmtiles`
});
```

**7. Optional: Cache Invalidation** (for instant updates):

```bash
# Purge specific tiles from Cloudflare cache after upload
# (Only needed if you want instant updates instead of waiting for TTL)

CLOUDFLARE_ZONE_ID=<zone-id>
CLOUDFLARE_API_TOKEN=<api-token>

curl -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "files": [
      "https://tiles.runmap.chouinard.me/runs.pmtiles",
      "https://tiles.runmap.chouinard.me/coverage.pmtiles"
    ]
  }'
```

**Benefits for Date-Filtered Tiles**:

When implementing Feature #5 (Date Filtering), R2 makes caching much better:

```bash
# Generate date-filtered tiles
bash scripts/export_tiles_by_date.sh "2025-01-01" "2025-01-31"

# Upload to R2 cache directory
aws s3 cp tiles/cache/runs_2025-01-01_2025-01-31.pmtiles \
  s3://${R2_BUCKET}/cache/runs_2025-01-01_2025-01-31.pmtiles \
  --endpoint-url "$R2_ENDPOINT" \
  --profile r2

# Frontend loads from R2
const tileUrl = 'https://tiles.runmap.chouinard.me/cache/runs_2025-01-01_2025-01-31.pmtiles';
map.getSource('runs').setUrl(`pmtiles://${tileUrl}`);
```

**Cache Management Strategy**:

```python
# Clean up old cached tiles (run weekly via cron)
import boto3
from datetime import datetime, timedelta

s3 = boto3.client('s3', ...)
bucket = 'runmap-tiles'

# List all cached tiles
response = s3.list_objects_v2(Bucket=bucket, Prefix='cache/')

# Delete tiles older than 30 days
for obj in response.get('Contents', []):
    if obj['LastModified'] < datetime.now(timezone.utc) - timedelta(days=30):
        s3.delete_object(Bucket=bucket, Key=obj['Key'])
        print(f"Deleted old cached tile: {obj['Key']}")
```

**Testing**:

1. **Upload test tile**:
   ```bash
   aws s3 cp tiles/runs.pmtiles s3://runmap-tiles/test.pmtiles \
     --endpoint-url https://<account-id>.r2.cloudflarestorage.com \
     --profile r2
   ```

2. **Access via custom domain**:
   ```bash
   curl -I https://tiles.runmap.chouinard.me/test.pmtiles
   # Should return 200 OK with Content-Type: application/vnd.pmtiles
   ```

3. **Verify range requests work** (critical for PMTiles):
   ```bash
   curl -I -H "Range: bytes=0-1023" https://tiles.runmap.chouinard.me/test.pmtiles
   # Should return 206 Partial Content
   ```

4. **Load in map**:
   - Update frontend to use R2 URL
   - Verify tiles load correctly
   - Check browser DevTools → Network tab for 206 responses

**Performance Monitoring**:

Cloudflare provides R2 analytics:
- Total requests
- Bandwidth served (always free!)
- Cache hit rate
- Geographic distribution

**Fallback Strategy** (Optional):

Keep self-hosted tiles as backup:

```javascript
async function loadTiles(source, r2Url, fallbackUrl) {
  try {
    // Try R2 first
    await map.addSource(source, {
      type: 'vector',
      url: `pmtiles://${r2Url}`
    });
  } catch (error) {
    console.warn('R2 tiles unavailable, using fallback', error);
    // Fallback to self-hosted
    await map.addSource(source, {
      type: 'vector',
      url: `pmtiles://${fallbackUrl}`
    });
  }
}
```

**Migration Path**:

1. Set up R2 and test with one tile
2. Keep self-hosted tiles running
3. Frontend tries R2 first, falls back to self-hosted
4. Monitor for 1 week
5. Once confident, remove self-hosted tiles

**Security Considerations**:

- R2 bucket is **public read** (tiles are public anyway)
- API credentials are **server-side only** (never in frontend)
- Custom domain uses HTTPS automatically
- No CORS issues (R2 handles CORS headers)

**Estimated Costs** (Reality Check):

**Your scale** (500 runs, 1,000 page loads/day):
- Storage: $0.00009/month (free tier covers this)
- Bandwidth: $0 (egress is free)
- **Total monthly cost: ~$0**

**At massive scale** (10,000 runs, 100,000 loads/day):
- Storage: 100MB = $0.0015/month
- Bandwidth: 6TB/month = **still $0** (egress free!)
- **Total monthly cost: <$0.01**

R2 is essentially **free at your scale**, with massive room to grow.

---

#### 5. Enhanced Duplicate Detection Feedback

**Priority**: MEDIUM (was CRITICAL, but bulk import is more urgent)
**Complexity**: Very Low (1-2 hours)
**Status**: Partial (server logic exists, needs shortcut feedback)

**Current State**:
- Server-side duplicate detection implemented via `content_hash` column
- Database constraint prevents duplicate imports
- iOS Shortcut doesn't display feedback to user

**What You'll Learn**:
- iOS Shortcut "Get Contents of URL" action
- JSON response parsing in Shortcuts
- Conditional notifications

**Implementation Plan**:

1. **Update API Response** (`api/app.py`):
```python
# Current: Returns 201 for new run, 409 for duplicate
# Change: Always return 200 with detailed JSON

return jsonify({
    'import_result': 'success' | 'duplicate' | 'error',
    'message': 'Run imported successfully' | 'Run already exists in database' | 'Error message',
    'run_id': 'uuid' | null,
    'filename': 'run.gpx'
}), 200
```

2. **Update iOS Shortcut**:
- Parse `import_result` field from response
- Show notification based on result:
  - `success`: "✅ Run imported: [filename]"
  - `duplicate`: "⚠️ Run already exists: [filename]"
  - `error`: "❌ Import failed: [message]"

**Testing**:
- Upload new run → should see success notification
- Re-upload same run → should see duplicate notification
- Upload corrupted GPX → should see error notification

**Files to Modify**:
- `api/app.py` (upload endpoint response format)
- iOS Shortcut (add JSON parsing + notifications)

---

#### 2. Run vs Walk Detection

**Priority**: HIGH
**Complexity**: Low-Medium (3-4 hours)
**Status**: Not implemented

**What You'll Learn**:
- GPX structure (trackpoints, timestamps, distances)
- Calculating pace from GPS data
- Python GPX parsing with `gpxpy` library
- Database schema design (separate tables)

**Technical Background**:

Running vs walking is distinguished by **average pace**:
- **Walking pace**: >12 min/mile (>7.5 min/km) or <4.0 mph (<6.4 km/h)
- **Running pace**: ≤12 min/mile or ≥4.0 mph
- **Edge cases**:
  - Runs with walk breaks (e.g., 13 min/mile average) → classify as run if any segment is <10 min/mile
  - Very short tracks (<0.5 miles) → may be GPS tests, not real activities

**Implementation Plan**:

1. **Create Walks Table** (`db/12_walks_table.sql`):
```sql
CREATE TABLE runmap.walks_raw (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  filename TEXT NOT NULL,
  uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  geom geometry(MultiLineString, 4326),
  content_hash TEXT UNIQUE NOT NULL,
  avg_pace_min_per_mile FLOAT,  -- For analysis
  total_distance_m FLOAT,
  duration_seconds INT
);

CREATE INDEX idx_walks_geom ON runmap.walks_raw USING GIST(geom);
```

2. **Add Pace Calculation Function** (`scripts/detect_activity_type.py`):
```python
import gpxpy
from datetime import datetime

def analyze_gpx(file_path):
    """
    Returns: {
        'type': 'run' | 'walk',
        'avg_pace_min_per_mile': float,
        'total_distance_m': float,
        'duration_seconds': int,
        'fastest_mile_pace': float  # For detecting run segments
    }
    """
    # Parse GPX, calculate pace per segment
    # If any mile is <10 min/mile → run
    # Otherwise use average pace
```

3. **Update Ingest Script** (`scripts/ingest_gpx.sh`):
```bash
# Before ogr2ogr, detect activity type
ACTIVITY_TYPE=$(python scripts/detect_activity_type.py "$GPX_FILE")

if [ "$ACTIVITY_TYPE" = "walk" ]; then
  # Import to walks_raw instead
  ogr2ogr -f PostgreSQL ... -nln runmap.walks_raw ...
  echo "Imported as walk"
else
  # Existing run import logic
  ogr2ogr -f PostgreSQL ... -nln runmap.runs_raw ...
  echo "Imported as run"
fi
```

4. **Update API Response**:
```python
return jsonify({
    'import_result': 'success_run' | 'success_walk' | 'duplicate' | 'error',
    'activity_type': 'run' | 'walk',
    'message': 'Run imported' | 'Walk imported (not counted in coverage)' | ...,
    'avg_pace_min_per_mile': 8.5,
    'distance_miles': 5.2
})
```

**Learning Resources**:
- GPX format: https://www.topografix.com/gpx.asp
- `gpxpy` library: https://github.com/tkrajina/gpxpy
- Pace calculation: `time / distance` (convert to min/mile)

**Testing Scenarios**:
- Upload easy run (9 min/mile) → should classify as run
- Upload long run with walk breaks (12.5 min/mile avg) → classify as run if any mile <10 min/mile
- Upload walking track (15 min/mile) → should classify as walk, not affect coverage

**Future Enhancements** (Tier 3+):
- View walks on separate map layer (toggle on/off)
- Calculate walking coverage separately
- Detect other activities (cycling, hiking) by speed

---

### Tier 2: Core UX Improvements

#### 3. Layer Toggle Controls

**Priority**: MEDIUM
**Complexity**: Very Low (1-2 hours)
**Status**: Not implemented

**What You'll Learn**:
- MapLibre GL JS layer visibility API
- CSS styling for mobile-friendly controls
- Layer management in web mapping

**Technical Background**:

MapLibre GL JS allows toggling layer visibility without reloading tiles:
```javascript
map.setLayoutProperty('layer-id', 'visibility', 'visible' | 'none');
```

This is **client-side only** (no server changes needed) and instant.

**Current Layers**:
- `runs-layer` (red lines) - all your running tracks
- `coverage-layer` (green polygon) - buffered union of all runs
- `blocks-incomplete-layer` (grey lines) - streets <90% covered
- `blocks-complete-layer` (green lines) - streets ≥90% covered

**Implementation Plan**:

1. **Add Toggle UI** (`web/build/index.html`):
```html
<div id="layer-controls">
  <label><input type="checkbox" id="toggle-runs" checked> Running Tracks</label>
  <label><input type="checkbox" id="toggle-coverage" checked> Coverage Buffer</label>
  <label><input type="checkbox" id="toggle-incomplete" checked> Incomplete Streets</label>
  <label><input type="checkbox" id="toggle-complete" checked> Complete Streets</label>
</div>
```

2. **Wire Up Toggle Logic**:
```javascript
document.getElementById('toggle-runs').addEventListener('change', (e) => {
  const visibility = e.target.checked ? 'visible' : 'none';
  map.setLayoutProperty('runs-layer', 'visibility', visibility);
});
// Repeat for other layers
```

3. **Mobile-Friendly Styling**:
```css
#layer-controls {
  position: absolute;
  top: 60px;
  right: 10px;
  background: rgba(255,255,255,0.9);
  padding: 10px;
  border-radius: 4px;
  font-size: 14px;
  max-width: 200px;
}

@media (max-width: 768px) {
  #layer-controls {
    font-size: 12px;
    padding: 8px;
  }
}
```

**Use Cases**:
- Hide running tracks to see street coverage clearly
- Hide complete streets to focus on gaps
- Hide coverage buffer to see raw GPS tracks

**Testing**:
- Toggle each layer on desktop and mobile
- Verify performance (should be instant)
- Check that map interaction still works with layers hidden

---

#### 4. Basemap Switching

**Priority**: MEDIUM
**Complexity**: Very Low (1 hour)
**Status**: Not implemented

**What You'll Learn**:
- Raster tile sources in MapLibre
- MapLibre style layer ordering (basemap always bottom)
- Common basemap providers

**Technical Background**:

Current basemap: OpenStreetMap raster tiles (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`)

**Useful Alternatives**:
- **Satellite**: ESRI World Imagery (helps verify coverage accuracy)
- **Terrain**: OpenTopoMap (shows elevation/hills)
- **Dark**: Carto Dark Matter (better for night viewing)

Basemap is a **raster-source** layer that sits below all vector layers.

**Implementation Plan**:

1. **Add Basemap Selector**:
```html
<select id="basemap-selector">
  <option value="osm" selected>OpenStreetMap</option>
  <option value="satellite">Satellite</option>
  <option value="terrain">Terrain</option>
  <option value="dark">Dark</option>
</select>
```

2. **Define Basemap Sources**:
```javascript
const basemaps = {
  osm: {
    type: 'raster',
    tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
    tileSize: 256
  },
  satellite: {
    type: 'raster',
    tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
    tileSize: 256
  },
  terrain: {
    type: 'raster',
    tiles: ['https://tile.opentopomap.org/{z}/{x}/{y}.png'],
    tileSize: 256
  },
  dark: {
    type: 'raster',
    tiles: ['https://cartodb-basemaps-a.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png'],
    tileSize: 256
  }
};
```

3. **Switching Logic**:
```javascript
document.getElementById('basemap-selector').addEventListener('change', (e) => {
  const basemapId = e.target.value;

  // Remove old basemap layer
  if (map.getLayer('basemap')) {
    map.removeLayer('basemap');
  }
  if (map.getSource('basemap')) {
    map.removeSource('basemap');
  }

  // Add new basemap (must be first layer)
  map.addSource('basemap', basemaps[basemapId]);
  map.addLayer({
    id: 'basemap',
    type: 'raster',
    source: 'basemap'
  }, 'first-vector-layer-id');  // Insert before vector layers
});
```

**Why Satellite is Useful**:
- Verify coverage: Did you actually run down that alley, or is it GPS drift?
- Find shortcuts: See paths through parks that aren't in OSM street data
- Identify errors: "I definitely ran that street" → check if OSM data is incomplete

**Future Enhancement** (Later):
- Save basemap preference to localStorage
- Move to settings table if you want it synced across devices

**Testing**:
- Switch between basemaps on desktop and mobile
- Verify vector layers (runs, streets) appear on top of basemap
- Check that satellite imagery aligns with street vectors

---

### Tier 3: Analysis Features

#### 5. View Runs by Date Range

**Priority**: HIGH (moved up from MEDIUM due to production scale)
**Complexity**: Medium-High (6-10 hours with caching)
**Status**: Not implemented

**What You'll Learn**:
- Server-side tile generation with date filters
- PMTiles caching strategies
- Mobile-friendly date pickers
- SQL date range queries
- Async tile generation

**Technical Background: Why Server-Side is Required**

**At Production Scale (125+ runs now, 250+ within 1 year)**:

**Client-Side Filtering** (NOT VIABLE):
- 125 runs × 50KB (full detail) = **6MB** download (slow on mobile)
- 125 runs × 12KB (simplified) = **1.5MB** (acceptable but growing)
- 250 runs = **3MB** (borderline)
- 500 runs = **6MB** (too slow)
- Every page load downloads all runs (wasteful)

**Server-Side Filtering** (REQUIRED):
- Default view: Last 30 days (~12-20 runs) = **250-400KB** (fast)
- Filtered view: Generate tiles on-demand for date range
- Caching: Pre-generate common periods ("Last 7 Days", "This Month")
- Scales to 1000+ runs without performance degradation

**Implementation Plan (Server-Side Approach)**:

1. **Create Tile Cache Directory Structure**:
```bash
tiles/
  runs.pmtiles              # All runs (fallback)
  cache/
    runs_last_7_days.pmtiles
    runs_last_30_days.pmtiles
    runs_this_month.pmtiles
    runs_this_year.pmtiles
    runs_2025-01-01_2025-01-31.pmtiles  # Custom ranges
```

2. **Add Date-Filtered Tile Export Function** (`scripts/export_tiles_by_date.sh`):
```bash
#!/bin/bash
# Export runs tiles filtered by date range
# Usage: bash scripts/export_tiles_by_date.sh "2025-01-01" "2025-01-31"

START_DATE=$1
END_DATE=$2
CACHE_FILE="tiles/cache/runs_${START_DATE}_${END_DATE}.pmtiles"

# Check if cached and recent
if [ -f "$CACHE_FILE" ]; then
  CACHE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))
  if [ $CACHE_AGE -lt 3600 ]; then  # 1 hour cache
    echo "Using cached tiles (age: ${CACHE_AGE}s)"
    exit 0
  fi
fi

# Export filtered runs
ogr2ogr -f GeoJSON "$TMP_DIR/runs_filtered.geojson" \
  PG:"..." \
  -sql "SELECT
    id, filename, uploaded_at,
    ST_Transform(ST_Simplify(geom, 0.0001), 4326) as geometry
  FROM runmap.runs_raw
  WHERE uploaded_at >= '$START_DATE' AND uploaded_at <= '$END_DATE'"

# Convert to PMTiles
tippecanoe -o "$CACHE_FILE" ...
```

3. **Add API Endpoint for Date-Filtered Tiles** (`api/app.py`):
```python
@app.route('/api/tiles/runs', methods=['GET'])
def get_runs_tiles():
    """
    Get runs tiles, optionally filtered by date
    Query params:
      - period: 'last_7_days' | 'last_30_days' | 'this_month' | 'this_year'
      - start_date: YYYY-MM-DD (custom range)
      - end_date: YYYY-MM-DD (custom range)

    Returns: PMTiles file or redirect to cached tile URL
    """
    period = request.args.get('period')
    start_date = request.args.get('start_date')
    end_date = request.args.get('end_date')

    # Map period to cache file
    if period == 'last_7_days':
        cache_file = 'tiles/cache/runs_last_7_days.pmtiles'
        # Generate if doesn't exist or older than 1 hour
        if not os.path.exists(cache_file) or cache_age(cache_file) > 3600:
            subprocess.run(['bash', 'scripts/export_tiles_by_date.sh',
                          (datetime.now() - timedelta(days=7)).strftime('%Y-%m-%d'),
                          datetime.now().strftime('%Y-%m-%d')])

    elif start_date and end_date:
        # Custom range
        cache_file = f'tiles/cache/runs_{start_date}_{end_date}.pmtiles'
        if not os.path.exists(cache_file):
            # Generate async, return "processing" status
            subprocess.Popen(['bash', 'scripts/export_tiles_by_date.sh', start_date, end_date])
            return jsonify({'status': 'processing', 'estimated_time': 30}), 202

    return send_file(cache_file)
```

4. **Add Mobile-Friendly Date Picker UI** (`web/build/index.html`):
```html
<div id="date-filter">
  <!-- Quick filters -->
  <div id="quick-filters">
    <button data-period="last_7_days">Last 7 Days</button>
    <button data-period="last_30_days">Last 30 Days</button>
    <button data-period="this_month">This Month</button>
    <button data-period="this_year">This Year</button>
    <button id="custom-range-toggle">Custom Range...</button>
  </div>

  <!-- Custom range picker (hidden by default) -->
  <div id="custom-range" style="display:none;">
    <label>Start: <input type="date" id="date-start"></label>
    <label>End: <input type="date" id="date-end"></label>
    <button id="apply-custom-filter">Apply</button>
  </div>

  <button id="show-all-runs">Show All Runs</button>
</div>
```

5. **Frontend Logic for Loading Filtered Tiles**:
```javascript
async function loadRunsByPeriod(period) {
  // Update map source to use filtered tiles
  const tileUrl = `/api/tiles/runs?period=${period}`;

  map.getSource('runs').setUrl(tileUrl);

  // Show loading indicator
  document.getElementById('loading').style.display = 'block';

  // Poll for tile generation completion if async
  // (handle 202 status from API)
}

async function loadRunsByDateRange(startDate, endDate) {
  const tileUrl = `/api/tiles/runs?start_date=${startDate}&end_date=${endDate}`;

  // Check if tile exists or is being generated
  const response = await fetch(tileUrl);

  if (response.status === 202) {
    // Tile being generated, show progress
    showNotification('Generating tiles for date range... (~30 seconds)');

    // Poll every 5 seconds until ready
    const pollInterval = setInterval(async () => {
      const checkResponse = await fetch(tileUrl);
      if (checkResponse.status === 200) {
        clearInterval(pollInterval);
        map.getSource('runs').setUrl(tileUrl);
        showNotification('Tiles ready!');
      }
    }, 5000);
  } else {
    // Tile exists, load immediately
    map.getSource('runs').setUrl(tileUrl);
  }
}
```

**Scope Options**:

**Option A: Filter Runs Layer Only** (Simplest)
- Show/hide running tracks by date
- Street coverage remains unchanged (cumulative)
- Use case: "What did I run in January?"

**Option B: Recalculate Coverage for Date Range** (Complex)
- Show which streets were covered during date range
- Requires server-side processing (can't do real-time in browser)
- Use case: "How much new coverage did I add this month?"

**Recommendation**: Start with **Option A** (runs layer only). Option B requires:
- Temporal coverage table (`block_coverage_by_date`)
- Date range query API endpoint
- Dynamic tile generation (30-60s delay)
- Caching strategy

Option B is more of a "Tier 4" feature due to complexity.

**Testing**:
- Filter to single day → should show only that run
- Filter to week → should show all runs in week
- Clear filter → should show all runs
- Test on mobile → date picker should work without zoom issues

---

#### 6. Most Run Streets

**Priority**: LOW
**Complexity**: Low (2-3 hours)
**Status**: Not implemented

**What You'll Learn**:
- Spatial join counting (how many runs touch each block)
- Ranking queries (TOP N)
- Aggregation in PostGIS
- Creating reusable views

**Technical Background**:

A street is "run multiple times" if multiple runs intersect its block. This is useful for:
- Identifying commute routes (streets you run frequently)
- Finding favorite routes
- Detecting GPS drift (same street counted multiple times in single run)

**Implementation Plan**:

1. **Create Run Count View** (`db/13_run_frequency.sql`):
```sql
CREATE OR REPLACE VIEW runmap.block_run_frequency AS
SELECT
  b.block_id,
  b.name,
  b.highway,
  COUNT(DISTINCT rb.run_id) as times_run,
  b.geom_32610,
  ST_Transform(b.geom_32610, 4326) as geom_4326
FROM runmap.streets_blocks_32610 b
JOIN runmap.runs_buffered_32610 rb ON ST_Intersects(b.geom_32610, rb.geom)
GROUP BY b.block_id, b.name, b.highway, b.geom_32610
ORDER BY times_run DESC;
```

2. **Add API Endpoint** (`api/app.py`):
```python
@app.route('/api/stats/most-run-streets', methods=['GET'])
def most_run_streets():
    limit = request.args.get('limit', 20, type=int)

    cur = get_db_cursor()
    cur.execute("""
        SELECT block_id, name, highway, times_run
        FROM runmap.block_run_frequency
        LIMIT %s
    """, (limit,))

    streets = cur.fetchall()
    return jsonify({
        'most_run_streets': [dict(row) for row in streets]
    })
```

3. **Add to Frontend** (optional UI):
```html
<div id="stats-panel">
  <h3>Most Run Streets</h3>
  <ol id="most-run-list">
    <!-- Populated via API -->
  </ol>
</div>
```

```javascript
async function loadMostRunStreets() {
  const response = await fetch('/api/stats/most-run-streets?limit=10');
  const data = await response.json();

  const listEl = document.getElementById('most-run-list');
  listEl.innerHTML = data.most_run_streets
    .map(s => `<li>${s.name || 'Unnamed'} (${s.highway}): ${s.times_run} times</li>`)
    .join('');
}
```

**Optional Enhancement**: Export as PMTiles layer with color gradient (1 run = grey, 5+ runs = dark red) to visualize on map.

**Use Cases**:
- "Which streets do I run most often?" → Identify commute routes
- "Do I have bias towards certain areas?" → See coverage patterns
- "Which streets should I avoid for variety?" → Mix up routes

---

### Tier 4: Advanced Features

#### 7. Route Planning for Unrun Streets

**Priority**: LOW (Future)
**Complexity**: Very High (20+ hours, ongoing learning)
**Status**: Research phase

**What You'll Learn** (Major topics):
- **PgRouting**: PostgreSQL extension for network routing
- **Graph theory**: Nodes, edges, weights, shortest path algorithms
- **Traveling Salesman Problem (TSP)**: Visiting multiple points efficiently
- **Route optimization**: Balancing distance, elevation, clustering
- **GPX generation**: Creating turn-by-turn navigation files

---

#### Technical Background: How Route Planning Works

**The Problem**:
You have 1,973 incomplete blocks scattered across Sacramento. You want to plan a 5-mile run that covers as many unrun blocks as possible, starting and ending near your home.

**Why This is Hard**:
This is a variant of the **Traveling Salesman Problem (TSP)**, which is NP-hard (no perfect solution for large datasets). We need heuristics (approximations) that give "good enough" routes.

**Key Concepts**:

1. **Road Network as a Graph**:
   - **Nodes**: Intersections (street endpoints)
   - **Edges**: Street segments (blocks)
   - **Weights**: Distance, time, elevation gain, or "coverage value"

2. **PgRouting**:
   - PostgreSQL extension for routing on spatial networks
   - Algorithms: Dijkstra (shortest path), A* (heuristic), TSP (multiple points)
   - Requires: Network topology (nodes + edges with connectivity)

3. **Coverage-Weighted Routing**:
   - Assign each block a "priority score":
     - Unrun blocks: High priority (score = 10)
     - Partial blocks: Medium priority (score = 5 * coverage_pct)
     - Complete blocks: Low priority (score = 1)
   - Route algorithm prefers high-priority edges

---

#### Implementation Plan (Multi-Phase)

**Phase 1: Setup PgRouting (Research & Install)**

1. **Install PgRouting Extension**:
```sql
CREATE EXTENSION pgrouting;
```

2. **Create Routable Network Table**:
```sql
-- Convert blocks to routable edges
CREATE TABLE runmap.routing_network AS
SELECT
  block_id as id,
  ST_StartPoint(geom_32610) as source_geom,
  ST_EndPoint(geom_32610) as target_geom,
  geom_32610,
  block_length_m as cost,  -- Default: distance
  name,
  highway
FROM runmap.streets_blocks_32610;

-- Add topology (source/target node IDs)
ALTER TABLE runmap.routing_network ADD COLUMN source INT;
ALTER TABLE runmap.routing_network ADD COLUMN target INT;

SELECT pgr_createTopology('runmap.routing_network', 0.001, 'geom_32610', 'id');
```

3. **Test Basic Routing**:
```sql
-- Find shortest path between two intersections
SELECT * FROM pgr_dijkstra(
  'SELECT id, source, target, cost FROM runmap.routing_network',
  start_node_id,
  end_node_id
);
```

**Learning Resources**:
- PgRouting docs: https://docs.pgrouting.org/
- Workshop: https://workshop.pgrouting.org/
- Tutorial: https://anitagraser.com/projects/pgrouting-tutorial/

---

**Phase 2: Coverage-Weighted Routing**

1. **Add Coverage Priority to Network**:
```sql
ALTER TABLE runmap.routing_network ADD COLUMN coverage_priority FLOAT;

UPDATE runmap.routing_network rn
SET coverage_priority = CASE
  WHEN bc.coverage_pct IS NULL OR bc.coverage_pct < 5 THEN 10.0  -- Unrun
  WHEN bc.coverage_pct < 90 THEN 5.0 * (1 - bc.coverage_pct/100)  -- Partial
  ELSE 1.0  -- Complete
END
FROM runmap.block_coverage_32610 bc
WHERE rn.id = bc.block_id;

-- Create weighted cost (prefer unrun streets)
ALTER TABLE runmap.routing_network ADD COLUMN weighted_cost FLOAT;
UPDATE runmap.routing_network
SET weighted_cost = cost / coverage_priority;  -- Lower cost = preferred
```

2. **Find Routes that Prioritize Unrun Streets**:
```sql
-- Shortest path that prefers unrun streets
SELECT * FROM pgr_dijkstra(
  'SELECT id, source, target, weighted_cost as cost FROM runmap.routing_network',
  start_node,
  end_node
);
```

---

**Phase 3: Area-Based Route Planning**

**Your Request**: "Select a general area" for route planning.

**Approach**: Use **neighborhoods** or create custom **planning zones**.

**Option A: Use Existing Neighborhoods** (If Available)
- Check if Sacramento GIS data includes neighborhood boundaries
- Source: https://data.cityofsacramento.org/

**Option B: Create Custom Planning Zones**
- Divide Sacramento into ~10-20 zones (2-3 sq miles each)
- Manual: Draw polygons in QGIS, import to PostGIS
- Automatic: Use PostGIS to create grid cells:

```sql
CREATE TABLE runmap.planning_zones AS
SELECT
  row_number() OVER () as zone_id,
  ST_Transform(cell, 32610) as geom_32610
FROM (
  SELECT ST_CreateFishnet(
    10,  -- 10 rows
    10,  -- 10 columns
    ST_Envelope(ST_Collect(geom_32610)),  -- Bounding box of all blocks
    'geom_32610'
  ) as cell
  FROM runmap.streets_blocks_32610
) subquery;
```

3. **Filter Blocks by Zone**:
```sql
-- Get all incomplete blocks in a zone
SELECT b.block_id, b.name, b.geom_32610
FROM runmap.streets_blocks_32610 b
JOIN runmap.block_coverage_32610 bc USING (block_id)
JOIN runmap.planning_zones z ON ST_Within(b.geom_32610, z.geom_32610)
WHERE z.zone_id = 5  -- User-selected zone
  AND bc.coverage_pct < 90;
```

**Future UI**: Map showing zones, click to select, generates route within that zone.

---

**Phase 4: Constrained TSP Route Generation**

**The Goal**: Generate a circular route (start/end at home) that:
- Covers maximum unrun street length
- Stays within distance constraint (e.g., 5 miles)
- Minimizes backtracking

**Algorithm**: PgRouting TSP with iterative refinement

```sql
-- Step 1: Find closest unrun blocks to home (within distance budget)
WITH nearby_unrun AS (
  SELECT block_id, geom_32610
  FROM runmap.streets_blocks_32610 b
  JOIN runmap.block_coverage_32610 bc USING (block_id)
  WHERE bc.coverage_pct < 90
    AND ST_DWithin(geom_32610, home_location, 5000)  -- 5km radius
  ORDER BY coverage_pct ASC  -- Prioritize least-covered
  LIMIT 20  -- Top 20 candidates
)
-- Step 2: Solve TSP to visit these blocks efficiently
SELECT * FROM pgr_TSP(
  $$
  SELECT block_id as id,
         ST_X(ST_Centroid(geom_32610)) as x,
         ST_Y(ST_Centroid(geom_32610)) as y
  FROM nearby_unrun
  $$
);
```

**Refinement**:
- Start with small radius (2km), increase if not enough blocks
- Balance "new coverage" vs "route efficiency"
- Add elevation penalty (prefer flat routes)

---

**Phase 5: GPX Export for Watch**

**Goal**: Convert route to GPX file with turn-by-turn navigation.

1. **Generate Route Geometry**:
```sql
-- Get ordered street segments from TSP solution
WITH route_segments AS (
  SELECT
    rn.geom_32610,
    rn.name,
    rn.block_length_m
  FROM pgr_TSP(...) tsp
  JOIN runmap.routing_network rn ON tsp.node = rn.id
  ORDER BY tsp.seq
)
SELECT ST_LineMerge(ST_Collect(geom_32610)) as route_geom
FROM route_segments;
```

2. **Convert to GPX** (Python script):
```python
import gpxpy
import gpxpy.gpx

def create_route_gpx(route_geom, waypoint_names):
    gpx = gpxpy.gpx.GPX()

    # Create route
    route = gpxpy.gpx.GPXRoute()
    gpx.routes.append(route)

    # Add points from route geometry
    for coord in route_geom.coords:
        route.points.append(gpxpy.gpx.GPXRoutePoint(coord[1], coord[0]))

    # Add waypoints for turn notifications
    for name, coord in waypoint_names:
        waypoint = gpxpy.gpx.GPXWaypoint(coord[1], coord[0], name=name)
        gpx.waypoints.append(waypoint)

    return gpx.to_xml()
```

3. **API Endpoint**:
```python
@app.route('/api/routes/plan', methods=['POST'])
def plan_route():
    """
    Request body: {
        "start_location": {"lat": 38.5, "lon": -121.5},
        "distance_miles": 5,
        "zone_id": 3 (optional)
    }

    Returns: GPX file download
    """
    # Run TSP algorithm
    # Generate GPX
    # Return file
    return send_file(gpx_path, as_attachment=True, download_name='planned_route.gpx')
```

4. **Import to WorkOutDoors App**:
- Download GPX from RunMap
- AirDrop to iPhone
- Open with WorkOutDoors
- App will show turn-by-turn navigation during run

---

#### Learning Path for Route Planning

**Week 1-2: PgRouting Basics**
1. Read PgRouting workshop: https://workshop.pgrouting.org/
2. Install extension, create test network
3. Run basic Dijkstra shortest path queries
4. Understand node/edge topology

**Week 3-4: Coverage Integration**
1. Add coverage weights to routing network
2. Test weighted routing (prefer unrun streets)
3. Experiment with different priority formulas
4. Validate routes visually in QGIS

**Week 5-6: TSP & Optimization**
1. Study TSP algorithm in PgRouting
2. Test with small sets of blocks (5-10)
3. Add distance constraints
4. Handle disconnected street networks

**Week 7-8: GPX Export & UI**
1. Learn GPX format and waypoints
2. Create Python GPX generator
3. Test import to WorkOutDoors
4. Build simple route planning UI

**Ongoing: Refinement**
- Add elevation data (DEM) for hill avoidance
- Optimize for multiple objectives (distance, coverage, elevation)
- Handle edge cases (dead ends, one-way streets)
- Performance tuning for large networks

---

#### Key Challenges & Solutions

**Challenge 1: Disconnected Street Network**
- **Problem**: Sacramento has bridges, highways that segment the network
- **Solution**: Pre-filter blocks to "reachable from home" using pgr_drivingDistance

**Challenge 2: Route Quality**
- **Problem**: TSP might create zig-zag routes, doubling back
- **Solution**: Post-process to smooth route, or use pgr_trsp (turn-restricted shortest path)

**Challenge 3: Performance**
- **Problem**: TSP is slow with 100+ points
- **Solution**: Pre-cluster blocks, solve TSP per cluster, then connect clusters

**Challenge 4: Elevation**
- **Problem**: Route might go up steep hills
- **Solution**: Add elevation cost from USGS DEM data, weight routes by climb

---

#### Realistic Timeline

- **Phase 1 (Setup)**: 5-10 hours (learning PgRouting, creating network)
- **Phase 2 (Coverage weights)**: 3-5 hours (SQL, testing)
- **Phase 3 (Zones)**: 2-4 hours (creating zones, filtering)
- **Phase 4 (TSP routing)**: 10-15 hours (algorithm experimentation, tuning)
- **Phase 5 (GPX export)**: 5-8 hours (Python script, API, testing)
- **Total**: 25-42 hours over 1-2 months of learning & iteration

---

## Summary: Revised Implementation Order (Production Scale)

**CRITICAL PATH (MUST DO BEFORE BULK IMPORT)**:
```
PHASE 1 (1 day - BLOCKING):
├─ 1. Run vs Walk Detection         🚨 CRITICAL - prevents data corruption (3-4 hrs)
├─ 2. Tile Export Optimization      ⚠️  HIGH - reduces 6MB to 1.5MB (1-2 hrs)
├─ 3. Cloudflare R2 Integration     ⚠️  HIGH - zero egress, CDN caching (1-2 hrs)
└─ 4. Bulk Import Script            ⚠️  HIGH - efficient import of 300+ runs (2-3 hrs)
```

**POST-IMPORT IMPROVEMENTS**:
```
PHASE 2 (1-2 days):
├─ 5. Database indexes              ✅ Performance for 100+ runs (30 min)
├─ 6. Duplicate detection feedback  ✅ Improves daily workflow (1-2 hrs)
├─ 7. Layer toggles                 ✅ Simple UX improvement (1-2 hrs)
└─ 8. Basemap switching             ✅ Helps verify coverage (1 hr)

PHASE 3 (3-5 days):
├─ 9. Async tile export (cron)      ⚠️  MEDIUM - decouple from uploads (2-3 hrs)
├─ 10. Date range filtering         ⚠️  HIGH - server-side with R2 caching (6-10 hrs)
└─ 11. Most-run streets             ✅ LOW - interesting insights (2-3 hrs)

PHASE 4 (1-2 months):
└─ 12. Route planning               ⚠️  VERY HIGH - major learning curve (25-42 hrs)
```

**Estimated Timeline**:
- **Phase 1**: 7-11 hours (must complete before importing 600 routes)
- **Phase 2**: 4-7 hours (quality of life improvements)
- **Phase 3**: 10-16 hours (production features for scale)
- **Phase 4**: 25-42 hours (advanced features, ongoing)

**Why R2 in Phase 1**:
- Zero egress costs save $60-1,200/year (pays for itself immediately)
- CDN edge caching = faster loads worldwide
- Better foundation for date filtering (Phase 3)
- Only adds 1-2 hours to Phase 1 timeline
- Much easier to set up now than migrate later

---

## Decision Summary from Discussion

### Scale Clarification (CRITICAL UPDATE):
- **Initial assumption**: 7 runs (development), growing slowly
- **Actual scale**: 125 runs + ~300 walks ready to import (600+ total routes)
- **Growth rate**: 3-5 runs + 1-3 walks per week = 250 activities/year
- **1-year projection**: 250-375 runs, significantly changes architectural decisions

### Feature #1 (Run vs Walk) - NOW TOP PRIORITY:
- **Threshold**: 12 min/mile average pace (4 mph)
- **Storage**: Separate `walks_raw` table (not counted in coverage)
- **API Response**: Return `import_result` with `activity_type` field
- **Shortcut**: Parse JSON, show notification based on activity type
- **CRITICAL**: Must implement before bulk import or 300 walks will corrupt coverage data

### Feature #5 (Date Filtering) - REVISED TO SERVER-SIDE:
- **UI**: Mobile-friendly date picker with quick filters ("Last 7 Days", "This Month")
- **Performance**: **Server-side filtering REQUIRED** (125+ runs = too large for client-side)
- **Caching**: Pre-generate common periods, 1-hour cache TTL
- **Default view**: Last 30 days (fast load)
- **Scope**: Runs layer only (coverage remains cumulative)

### Feature #7 (Route Planning):
- **Use Case**: Fill coverage gaps efficiently
- **Constraints**: Start with **distance only** (5K, 10K routes)
- **Areas**: Create **planning zones** (grid or neighborhoods) for focused route planning
- **Output**: Downloadable **GPX file** for WorkOutDoors navigation
- **Learning**: PgRouting, TSP, graph theory (1-2 month learning curve)

### Performance Considerations (Production Scale):
- **Tile export**: Simplify geometry (6MB → 1.5MB with ST_Simplify)
- **Cloudflare R2**: Serve tiles from CDN with zero egress costs (saves $60-1,200/year)
- **Database indexes**: Add indexes on `uploaded_at`, `activity_type` for queries
- **Async tile generation**: Decouple from uploads, use cron (every 15-30 minutes)
- **Bulk import optimization**: Disable trigger, process all, rebuild once
- **Date filtering**: Server-side with R2 caching (not client-side at 125+ runs)

---

## Next Steps (URGENT - Before Bulk Import)

### Immediate Action Required:

**DO NOT IMPORT 600 ROUTES YET** until Phase 1 is complete. Otherwise:
- 300 walks will be imported as runs
- Coverage statistics will be completely corrupted
- Cleaning up afterward is extremely difficult

### Implementation Sequence:

1. **Day 1 Morning (3-4 hours) - BLOCKING**:
   - Implement run/walk detection (#1)
   - Test with 5 known runs + 5 known walks
   - Verify classification accuracy

2. **Day 1 Afternoon (2-4 hours) - BLOCKING**:
   - Add tile geometry simplification (#2)
   - Set up Cloudflare R2 bucket (#3)
   - Configure custom domain: tiles.runmap.chouinard.me
   - Update tile export script to upload to R2
   - Test R2 tile serving

3. **Day 1 Evening (2-3 hours) - BLOCKING**:
   - Create bulk import script (#4)
   - Update frontend to load tiles from R2
   - Test entire pipeline with 10 sample files

4. **Day 1 Night or Day 2 - Bulk Import**:
   - Run bulk import on all 600 routes
   - Monitor classification (should be ~125 runs, ~300 walks, rest unknown)
   - Tiles automatically upload to R2
   - Spot-check results on map
   - Expected duration: 45-55 minutes

5. **Week 1 (Post-Import)**:
   - Add database indexes (#5)
   - Implement duplicate detection feedback (#6)
   - Add layer toggles (#7)
   - Add basemap switching (#8)

6. **Week 2-3**:
   - Implement async tile export (#9)
   - Implement date range filtering with R2 caching (#10)
   - Add most-run streets (#11)

7. **Month 2-3** (Optional):
   - Begin route planning research (#12)

---

## Questions to Consider Before Implementation

1. **Feature #1 (Run/Walk)**: Where are your 600 GPX files stored? Do you need to organize them first?
2. **Feature #1**: Do you know which files are runs vs walks, or should we classify all automatically?
3. **Feature #1**: Any edge cases to consider (hiking, cycling, treadmill runs)?
4. **Bulk Import**: What's the file structure? (e.g., `/gpx/*.gpx` or subdirectories?)
5. **Feature #5 (Date Filtering)**: Should "Last 30 Days" be the default view, or show all runs?
6. **Feature #7 (Route Planning)**: Do you have a preferred "home location" to start routes from?
7. **General**: Should I implement these features with detailed explanations so you can learn, or do you want to code them yourself with my guidance?

---

## Key Takeaways

**What Changed from Initial Plan**:
- Feature #2 (Run/Walk) moved from #2 to **#1 CRITICAL** (data corruption risk)
- Feature #5 (Date Filtering) revised from client-side to **server-side** (scale requirement)
- Added Feature #2 (Bulk Import) as **BLOCKING** requirement
- Added Feature #3 (Tile Optimization) as **HIGH** priority (6MB → 1.5MB)
- **Added Feature #4 (Cloudflare R2)** as **HIGH** priority (zero egress, CDN caching)
- All priorities reordered based on production scale (125 runs, not 7)

**Timeline Impact**:
- Original: "Won't hit 100 runs for years" → **Already at 125 runs**
- Original: "Client-side filtering is fine" → **Server-side required**
- Original: "Implement features gradually" → **Must complete Phase 1 before bulk import**
- Original: Phase 1 = 6-8 hours → **Updated: 7-11 hours** (added R2, worth it for cost savings)

Let me know when you're ready to begin Phase 1 implementation. I strongly recommend starting immediately with Feature #1 (Run/Walk Detection) to prevent data corruption during bulk import.
