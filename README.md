# RunMap - Sacramento Running Coverage Tracker

A geospatial web application for tracking running coverage across Sacramento streets. Upload GPX tracks and see which city blocks you've completed.

**[Usage Guide](docs/USAGE_GUIDE.md)** | **[Technical Docs](CLAUDE.md)** | **[Live Map](https://runmap.chouinard.me)**

![Block Completion](https://img.shields.io/badge/Blocks%20Complete-24.0%25-orange) ![Complete Blocks](https://img.shields.io/badge/Complete-624/2597-green) ![Threshold](https://img.shields.io/badge/Threshold-90%25-blue)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Ubuntu Server                         │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Nginx (Reverse Proxy + Static Files)              │ │
│  │  - Serves React frontend (/)                       │ │
│  │  - Proxies API (/api/*)                           │ │
│  │  - Serves PMTiles (/tiles/*.pmtiles)              │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Flask API (systemd service)                       │ │
│  │  - /api/upload (GPX ingestion)                     │ │
│  │  - /api/health (status check)                      │ │
│  │  - /api/refresh-coverage (manual refresh)          │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │  PostgreSQL + PostGIS                              │ │
│  │  - Street network (from OSM)                       │ │
│  │  - Run tracks (from GPX)                           │ │
│  │  - Coverage calculations (materialized views)      │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Processing Pipeline                               │ │
│  │  - Fast path: runs.pmtiles (~30s)                  │ │
│  │  - Slow path: coverage + unrun streets (~5min)     │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Features

- **Block-Percentage Coverage**: Streets split at intersections into 2,597 blocks (avg 98m each)
- **Configurable Threshold**: Set completion percentage (default 90%) to mark blocks as done
- **Highway-Specific Buffers**: Different GPS buffers by road type (10-20m) for accuracy
- **Incremental Processing**: Processes only new runs, constant memory usage
- **GPX Upload**: Web interface or API upload
- **Vector Tiles**: Fast, zoomable maps using PMTiles format
- **Real-time Stats**: See coverage percentage, blocks completed, top streets

## Quick Start

### Upload a New Run

**Option 1: Web Interface** (easiest)
1. Open https://runmap.chouinard.me
2. Click "Upload GPX"
3. Select your .gpx file from WorkOutDoors
4. Wait ~30 seconds, refresh page

**Option 2: Command Line**
```bash
scp run.gpx runmap:/home/mark/runmap/gpx/
ssh runmap "cd /home/mark/runmap && bash scripts/process_new_run.sh gpx/run.gpx"
```

See **[Usage Guide](docs/USAGE_GUIDE.md)** for complete instructions.

## How It Works

### Block-Based Coverage
1. Streets split at intersections → 2,597 blocks (natural city blocks)
2. Each run creates GPS buffer (10-20m depending on road type)
3. Blocks intersecting buffer show coverage percentage
4. Block ≥90% covered = Complete (green), <90% = Incomplete (grey)

### Incremental Processing
- Processes only new runs, not historical data
- Constant O(blocks touched) memory usage
- Fast: ~10-30 seconds per run
- No reprocessing needed when adding new runs

## Project Structure

```
/home/mark/runmap/
├── api/                    # Flask API
│   ├── app.py
│   └── requirements.txt
├── db/                     # Database schema
│   ├── 01_create_tables.sql
│   └── 02_create_views.sql
├── docs/                   # Documentation
│   ├── ARCHITECTURE.md
│   └── DEPLOYMENT.md
├── gpx/                    # Uploaded GPX files
├── scripts/                # Processing scripts
│   ├── ingest_gpx.sh
│   ├── fast_path.sh
│   └── slow_path.sh
├── tiles/                  # Generated PMTiles
│   ├── runs.pmtiles
│   ├── coverage.pmtiles
│   └── streets_unrun.pmtiles
└── web/                    # React frontend
    └── build/
```

## Setup

See [info/setup_checklist.md](info/setup_checklist.md) for complete setup instructions.

### Quick Start

1. **Database Setup**
```bash
psql -U runmap_user -d runmap -f db/01_create_tables.sql
psql -U runmap_user -d runmap -f db/02_create_views.sql
```

2. **Import Street Network**
```bash
osm2pgsql -d runmap streets.osm.pbf
psql -U runmap_user -d runmap -c "INSERT INTO runmap.streets_reference SELECT * FROM planet_osm_line WHERE highway IS NOT NULL"
```

3. **Start API**
```bash
sudo systemctl start runmap-api
sudo systemctl enable runmap-api
```

4. **Upload GPX**
```bash
curl -X POST https://runmap.chouinard.me/api/upload -F "file=@run.gpx"
```

## Usage

### Upload a Run
```bash
curl -X POST https://runmap.chouinard.me/api/upload -F "file=@/path/to/run.gpx"
```

### Trigger Coverage Refresh
```bash
curl -X POST https://runmap.chouinard.me/api/refresh-coverage
```

### Check API Health
```bash
curl https://runmap.chouinard.me/api/health
```

### View Coverage Stats
```bash
psql -U runmap_user -d runmap -c "SELECT * FROM runmap.coverage_stats;"
```

## Configuration

### Environment Variables

The API uses these environment variables (configured in systemd service):

- `GPX_DIR`: Directory for uploaded GPX files (default: `/home/mark/runmap/gpx`)
- `TILES_DIR`: Directory for generated tiles (default: `/home/mark/runmap/tiles`)
- `SCRIPTS_DIR`: Directory for processing scripts (default: `/home/mark/runmap/scripts`)
- `DB_*`: Database connection settings

See `api/.env.example` for all available options.

## Technology Stack

- **Backend**: Flask (Python)
- **Database**: PostgreSQL 16 + PostGIS 3
- **Frontend**: React + MapLibre GL JS
- **Tiles**: PMTiles (vector tiles)
- **Server**: Nginx + Systemd (Ubuntu 24.04)
- **Processing**: GDAL/OGR, Tippecanoe
- **Optional**: Cloudflare R2 for tile hosting (CDN, no egress fees)

## Development

### Running Locally

1. Set up Python virtual environment:
```bash
cd api
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

2. Start Flask dev server:
```bash
python app.py
```

3. Test endpoints:
```bash
curl http://localhost:5000/api/health
```

## Monitoring

### Check API Status
```bash
sudo systemctl status runmap-api
sudo journalctl -u runmap-api -f
```

### Check Tile Generation
```bash
ls -lh /home/mark/runmap/tiles/*.pmtiles
pmtiles show /home/mark/runmap/tiles/runs.pmtiles
```

### Database Stats
```bash
psql -U runmap_user -d runmap -c "SELECT COUNT(*) FROM runmap.runs_raw;"
psql -U runmap_user -d runmap -c "SELECT * FROM runmap.coverage_stats;"
```

## License

Private project - not licensed for public use.

## Repository

https://github.com/machouinard/runs-cdm
