# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a personal running route tracking system for Sacramento that analyzes GPS tracks (GPX files) to measure street coverage and visualize progress on an interactive web map. The system combines Supabase (PostgreSQL + PostGIS), React with MapLibre GL, and PMTiles for efficient vector tile delivery.

**Architecture**: GPX data flows from iOS uploads → Supabase storage → PostGIS processing → PMTiles generation → web map visualization.

## Core Development Commands

### Web Application (React + Vite)
```bash
cd web
npm run dev     # Start development server
npm run build   # Production build 
npm run preview # Preview production build
```

### Database & ETL Pipeline
```bash
# Refresh materialized views after GPX import
./scripts/refresh_all.sh           # Full refresh (all views)
./scripts/refresh_all.sh quick     # Partial refresh (coverage only)
./scripts/refresh_all.sh fast      # Fastest refresh (buffer only)

# Bulk ingest GPX files from WorkOutDoors/ directory
./scripts/bulk_ingest_gpx.sh

# Export layers to PMTiles and upload to Supabase storage
./scripts/export_tiles.sh
REFRESH=quick ./scripts/export_tiles.sh  # Skip heavy refresh step
```

### Typical Development Workflow
1. Add GPX files to `WorkOutDoors/` directory
2. Run `./scripts/bulk_ingest_gpx.sh` to upload and parse GPX data
3. Run `./scripts/refresh_all.sh` to rebuild coverage calculations
4. Run `./scripts/export_tiles.sh` to generate updated PMTiles
5. Web app automatically loads new tiles via version cache-busting

## Data Architecture

### Database Schema (`runmap` schema in Supabase)
- **`runs_raw`** - Raw GPX tracks as MultiLineString geometries with metadata
- **`all_streets_runnable_aoi`** - Reference street network (from OSM, filtered for runnable streets)
- **`coverage_buffer_current`** - Materialized view: buffered runs to approximate street coverage  
- **`streets_unrun`** - Materialized view: streets not yet covered by runs
- **`settings`** - Global settings (buffer distance, etc.)
- **`aoi`** - Area of interest polygon (optional boundary)

### Key Spatial Operations
- **Buffer Distance**: 20m default (configurable in settings)
- **CRS**: EPSG:4326 (WGS84) for storage, EPSG:32610 (UTM Zone 10N) for meter-accurate operations
- **Coverage Logic**: ST_DWithin for segment-based coverage detection, avoiding double-counting
- **Geometry Types**: MultiLineString for runs, Polygon/MultiPolygon for coverage, LineString for streets

### PMTiles Layers
- **streets_unrun.pmtiles** - Red lines showing uncovered runnable streets
- **runs_collect.pmtiles** - Blue lines showing completed runs
- **coverage_buffer.pmtiles** - Green polygons showing coverage areas

## Configuration

### Environment Variables (.env at repo root)
```bash
# Supabase connection (for scripts)
PGHOST=db.ppuxdqqxhxfayjbsfzsw.supabase.co
PGPORT=6543
PGDATABASE=postgres  
PGUSER=postgres.ppuxdqqxhxfayjbsfzsw
PGPASSWORD=<password>
SUPABASE_URL=https://ppuxdqqxhxfayjbsfzsw.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<service-key>
SUPABASE_ANON_KEY=<anon-key>

# Optional: tile versioning
TILES_VERSION=20250901-11
```

### Web App Environment (web/.env.local)
```bash
VITE_PUBLIC_SUPABASE_URL=https://ppuxdqqxhxfayjbsfzsw.supabase.co
VITE_PUBLIC_SUPABASE_ANON_KEY=<anon-key>
VITE_PM_TILES_URL=<pmtiles-url>
VITE_PM_TILES_URL_RUNS=<runs-pmtiles-url>  
VITE_PM_TILES_URL_BUFFER=<buffer-pmtiles-url>
VITE_TILES_VERSION=20250901-11  # Cache busting
```

## Database Migration System

Migrations are in `db/migrations/` with numeric prefixes. Key migrations:
- `0001_enable_extensions_and_schema.sql` - PostGIS setup, core tables
- `0002_materialized_views.sql` - Coverage calculation views
- `0003_functions_and_policies.sql` - Refresh functions, RLS policies

Apply manually via psql or Supabase dashboard.

## Supabase Edge Functions

### GPX Ingest (`supabase/edge-functions/gpx_ingest/`)
- Endpoint: `/functions/v1/gpx_ingest`
- Input: JSON `{path, start_time?, duration_s?, distance_km?}`
- Reads GPX from storage, parses tracks to MULTILINESTRING WKT
- Deduplicates by SHA-256 content hash
- Calls `runmap.insert_run_from_wkt()` RPC function

### GPX Upload (`supabase/functions/gpx_ingest_upload/`)  
- Endpoint: `/functions/v1/gpx_ingest_upload`
- Input: multipart form with GPX file
- Stores to Supabase storage, then calls gpx_ingest for processing

## Development Patterns

### PostGIS Conventions
- Geometry column always named `geom`
- Materialized views include `gid` integer primary key
- GIST indexes on all geometry columns
- Explicit SRID specification in geometry types
- Use `ST_Transform()` for meter-based operations (EPSG:32610)

### SQL Refresh Functions
- `runmap.refresh_all()` - Complete rebuild (slow, ~2-5 minutes)  
- `runmap.refresh_quick()` - Partial rebuild (faster, ~30 seconds)
- `runmap.refresh_quick_fast()` - Buffer-only rebuild (fastest, ~10 seconds)

### React/MapLibre Integration
- PMTiles protocol registration for efficient vector tile loading
- Layer visibility controlled by URL query parameters (?run=1&unrun=1&buffer=1)
- Automatic map bounds fitting from PMTiles headers
- Cache-busting via TILES_VERSION environment variable

## External Dependencies

### Required Tools for Full Pipeline
- **GDAL** (`ogr2ogr`) - PostGIS to GeoJSON export
- **Tippecanoe** - GeoJSON to MBTiles conversion  
- **PMTiles** CLI - MBTiles to PMTiles conversion
- **psql** - Database connection for refresh operations
- **curl** - File uploads to Supabase storage

### iOS Integration
- GPX files exported from WorkOutDoors app
- iOS Shortcuts for automated upload to Supabase Edge Functions
- Seamless mobile-to-cloud data pipeline

## Performance Notes

- Materialized view refreshes are expensive (disable `jit` in PostgreSQL settings)
- Use `statement_timeout=0` for long-running refreshes
- Coverage buffer operations benefit from increased `work_mem`
- PMTiles provide efficient vector tile serving without tile server
- Web app uses `?v=<version>` cache busting for tile updates