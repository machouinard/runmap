# AOI Management Guide

This guide covers how to modify, sync, and reimport streets for the Area of Interest (AOI).

## Prerequisites

- QGIS installed locally
- Access to local PostgreSQL database (`runmap_local`)
- SSH access to production server

## Workflow Overview

1. Edit AOI geometry in QGIS
2. Deploy AOI to production
3. Reimport streets on production
4. Rebuild coverage

---

## Step 1: Edit AOI in QGIS

1. Open QGIS and connect to local database:
   - Host: `localhost`
   - Database: `runmap_local`
   - User: `runmap_user`

2. Add the `runmap.aoi` layer

3. Edit the geometry as needed (expand, shrink, reshape)

4. Save edits

5. Verify in terminal:
   ```bash
   psql -U runmap_user -d runmap_local -c "SELECT name, ST_Area(geom::geography)/1000000 as area_km2 FROM runmap.aoi;"
   ```

---

## Step 2: Deploy AOI to Production

### Option A: Using deploy.sh (recommended)

```bash
./scripts/deploy.sh --aoi
```

This exports the AOI geometry from local and updates it on production.

### Option B: Manual sync

If the AOI row doesn't exist on production yet, you need to INSERT:

```bash
# Export geometry from local
AOI_GEOM=$(psql -U runmap_user -d runmap_local -t -A -c "SELECT ST_AsText(geom) FROM runmap.aoi WHERE name='sacramento';")

# SSH to production and insert
ssh -p 2222 mark@192.168.68.25 "psql -U runmap_user -d runmap -c \"INSERT INTO runmap.aoi (name, geom) VALUES ('sacramento', ST_GeomFromText('$AOI_GEOM', 4326)) ON CONFLICT (name) DO UPDATE SET geom = EXCLUDED.geom;\""
```

### Verify on production

```bash
ssh -p 2222 mark@192.168.68.25 "psql -U runmap_user -d runmap -c \"SELECT name, ST_Area(geom::geography)/1000000 as area_km2 FROM runmap.aoi;\""
```

---

## Step 3: Reimport Streets on Production

SSH to the production server and run the street import with `--prune` to wipe and reimport:

```bash
ssh -p 2222 mark@192.168.68.25

# On the server:
cd /home/mark/runmap
bash scripts/add_streets_for_aoi.sh --prune norcal-latest.osm.pbf sacramento
```

The `--prune` flag:
- Wipes all existing streets, blocks, and segments
- Reimports only streets within the current AOI boundary
- Ensures clean data matching the new AOI

**Note:** This process takes 5-10 minutes depending on AOI size.

---

## Step 4: Rebuild Coverage

Still on the production server:

```bash
bash scripts/rebuild_all_coverage.sh
```

This reprocesses all runs against the new street segments to calculate coverage.

---

## Quick Reference

### Full deployment with AOI update

```bash
# From Mac
./scripts/deploy.sh --aoi

# SSH to server
ssh -p 2222 mark@192.168.68.25
cd /home/mark/runmap
bash scripts/add_streets_for_aoi.sh --prune norcal-latest.osm.pbf sacramento
bash scripts/rebuild_all_coverage.sh
```

### Check current AOI on local

```bash
psql -U runmap_user -d runmap_local -c "SELECT name, ST_Area(geom::geography)/1000000 as area_km2 FROM runmap.aoi;"
```

### Check current AOI on production

```bash
ssh -p 2222 mark@192.168.68.25 "psql -U runmap_user -d runmap -c \"SELECT name, ST_Area(geom::geography)/1000000 as area_km2 FROM runmap.aoi;\""
```

### Check street counts

```bash
# Local
psql -U runmap_user -d runmap_local -c "SELECT COUNT(*) as streets FROM runmap.streets_reference; SELECT COUNT(*) as blocks FROM runmap.streets_blocks_32610;"

# Production
ssh -p 2222 mark@192.168.68.25 "psql -U runmap_user -d runmap -c \"SELECT COUNT(*) as streets FROM runmap.streets_reference; SELECT COUNT(*) as blocks FROM runmap.streets_blocks_32610;\""
```

---

## Troubleshooting

### "AOI not found" error

The AOI row doesn't exist. Use INSERT instead of UPDATE:

```bash
AOI_GEOM=$(psql -U runmap_user -d runmap_local -t -A -c "SELECT ST_AsText(geom) FROM runmap.aoi WHERE name='sacramento';")

ssh -p 2222 mark@192.168.68.25 "psql -U runmap_user -d runmap -c \"INSERT INTO runmap.aoi (name, geom) VALUES ('sacramento', ST_GeomFromText('$AOI_GEOM', 4326));\""
```

### Streets outside AOI after shrinking

Use `--prune` flag to wipe and reimport:

```bash
bash scripts/add_streets_for_aoi.sh --prune norcal-latest.osm.pbf sacramento
```

### Coverage stats incorrect after reimport

Refresh the materialized view:

```bash
psql -U runmap_user -d runmap -c "REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;"
```

Or run the full rebuild:

```bash
bash scripts/rebuild_all_coverage.sh
```
