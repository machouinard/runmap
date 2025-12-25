# Managing Multiple Areas of Interest (AOIs)

This guide explains how to add and manage multiple geographic areas in RunMap.

## Overview

RunMap supports **unlimited AOIs** (sacramento, portland, davis, etc.). Each area:
- Has its own street network
- Tracks coverage independently
- Auto-detects run locations
- Displays on the map with location filtering

## Quick Start: Add a New Area

### 1. Create AOI Polygon

First, define the boundary of your new area:

```sql
-- Example: Adding Davis, CA
INSERT INTO runmap.aoi (name, geom)
VALUES (
  'davis',
  ST_GeomFromText('POLYGON((
    -121.78 38.52,
    -121.78 38.58,
    -121.70 38.58,
    -121.70 38.52,
    -121.78 38.52
  ))', 4326)
);
```

**How to get coordinates:**
1. Go to https://geojson.io
2. Draw a polygon around your area
3. Copy the coordinates from the GeoJSON
4. Use them in the INSERT statement above

### 2. Download OSM Data

Get OpenStreetMap data for your area:

```bash
# Option 1: Use BBBike extract (recommended)
# Go to https://extract.bbbike.org/
# Draw bounding box → Select PBF format → Download

# Option 2: Use Overpass API (for smaller areas)
wget -O davis.osm.pbf "https://overpass-api.de/api/interpreter?data=..."

# Option 3: Use Geofabrik (for large regions)
wget https://download.geofabrik.de/north-america/us/california-latest.osm.pbf
```

**Recommended: BBBike** - Free extracts up to ~512 MB, email delivery in ~5 minutes.

### 3. Import Streets

Use the automated workflow script:

```bash
./scripts/add_streets_for_aoi.sh data/davis.osm.pbf davis
```

This script:
- ✅ Imports OSM streets within the AOI polygon
- ✅ Splits streets into blocks at intersections
- ✅ Creates 5m segments for coverage tracking
- ✅ Initializes coverage to 0%
- ✅ (Optional) Reprocesses existing runs

### 4. Export Tiles

```bash
bash scripts/export_tiles_blocks.sh
```

### 5. Update Tiles Version

```bash
psql -c "UPDATE runmap.settings SET value = to_jsonb(extract(epoch from now())::bigint) WHERE key = 'tiles_version';"
```

Done! The new area now appears on the map.

## Expanding an Existing AOI

To expand Sacramento, Portland, or any existing area:

### Option A: Update AOI Polygon (Recommended)

```sql
-- Example: Expand Sacramento to include Folsom
UPDATE runmap.aoi
SET geom = ST_GeomFromText('POLYGON((
  -- New larger coordinates here
  -121.60 38.40,
  -121.60 38.70,
  -121.30 38.70,
  -121.30 38.40,
  -121.60 38.40
))', 4326)
WHERE name = 'sacramento';
```

Then import streets for the expanded area:

```bash
./scripts/add_streets_for_aoi.sh data/sacramento_expanded.osm.pbf sacramento
```

### Option B: Create New AOI (for distinct areas)

If adding a separate area (like Folsom as its own location):

```sql
INSERT INTO runmap.aoi (name, geom)
VALUES ('folsom', ST_GeomFromText('POLYGON((...))'));
```

```bash
./scripts/add_streets_for_aoi.sh data/folsom.osm.pbf folsom
```

## How Location Detection Works

After upgrading to AOI-based detection ([db/16_aoi_based_location.sql](../db/16_aoi_based_location.sql)):

1. GPX uploaded → centroid calculated
2. Centroid tested against each AOI polygon with `ST_Within()`
3. If match: location = AOI name (e.g., 'davis')
4. If no match: location = 'other'

**Priority order** (if centroids overlap):
1. sacramento
2. portland
3. Other AOIs (alphabetical)
4. 'other'

## Viewing Multiple AOIs

The map automatically shows all areas. Use the location filter in the control panel to focus on specific areas:

- "Jump to Sacramento"
- "Jump to Portland"
- (Future: Add more location buttons as needed)

## Coverage Stats Per Location

Check coverage by location:

```sql
-- Runs per location
SELECT location, COUNT(*), ROUND(SUM(total_distance_m)/1609.34, 1) as miles
FROM runmap.runs_raw
GROUP BY location
ORDER BY location;

-- Coverage per location (requires AOI-based filtering)
-- Coming soon: Per-AOI coverage materialized views
```

## Advanced: Excluding Street Types

By default, these are **excluded**:
- `highway = 'service'` (alleys, driveways)

To exclude additional types (e.g., paths):

```sql
-- Add to import filter in add_streets_for_aoi.sh:
-- Change: "highway != 'service'"
-- To: "highway NOT IN ('service', 'path', 'footway')"
```

## Advanced: Using Custom AOI Shapes

Instead of rectangles, use actual city boundaries:

```bash
# Get city boundary from OpenStreetMap
wget -O city_boundary.geojson "https://nominatim.openstreetmap.org/search?q=Davis,CA&format=geojson&polygon_geojson=1"

# Import to PostGIS
ogr2ogr -f PostgreSQL PG:"dbname=runmap_local" \
  -nln runmap.aoi_temp \
  -lco GEOMETRY_NAME=geom \
  city_boundary.geojson

# Insert into aoi table
psql << EOF
INSERT INTO runmap.aoi (name, geom)
SELECT 'davis', ST_Transform(geom, 4326)
FROM runmap.aoi_temp
LIMIT 1;

DROP TABLE runmap.aoi_temp;
EOF
```

## Troubleshooting

### Streets not appearing after import

```bash
# Check if streets were added
psql -c "SELECT COUNT(*) FROM runmap.streets_reference;"

# Check if blocks were created
psql -c "SELECT COUNT(*) FROM runmap.streets_blocks_32610;"

# Re-export tiles
bash scripts/export_tiles_blocks.sh
```

### Location detection not working

```sql
-- Verify AOI polygon covers your area
SELECT name, ST_AsText(ST_Envelope(geom)) as bbox
FROM runmap.aoi;

-- Test specific coordinates
SELECT runmap.detect_location(
  ST_SetSRID(ST_MakePoint(-121.75, 38.55), 4326)
);
-- Should return 'davis' if Davis AOI exists and covers this point
```

### Runs showing as 'other' instead of AOI name

```sql
-- Check run centroid vs AOI
SELECT
  r.id,
  r.location,
  ST_AsText(ST_Centroid(r.geom)) as centroid,
  runmap.detect_location(r.geom) as should_be
FROM runmap.runs_raw r
WHERE r.location = 'other'
LIMIT 5;

-- Backfill if needed
UPDATE runmap.runs_raw
SET location = runmap.detect_location(geom)
WHERE geom IS NOT NULL;
```

## Best Practices

### For Future Expansions

1. **Always use AOI polygons** - Don't edit `detect_location()` function
2. **Download OSM extracts** - Don't try to import entire planet files
3. **Test on local database first** - Verify before deploying to production
4. **Keep AOI names lowercase** - Consistent with existing (sacramento, portland)
5. **Document new AOIs** - Update this file when adding new areas

### For Large Imports

If importing a large metro area (>500 MB OSM file):

1. Use Geofabrik extract (state or region level)
2. Filter during import with precise AOI polygon
3. Expect 5-15 minutes for block splitting
4. Monitor PostgreSQL memory during rebuild

### For Testing

```bash
# Test on local database first
psql -d runmap_local << EOF
INSERT INTO runmap.aoi (name, geom) VALUES ('test_area', ...);
EOF

./scripts/add_streets_for_aoi.sh test.osm.pbf test_area

# If successful, deploy to production
ssh production
psql -d runmap << EOF
INSERT INTO runmap.aoi (name, geom) VALUES ('test_area', ...);
EOF
```

## Migration Notes

If upgrading from hardcoded bounding boxes:

1. Run `db/16_aoi_based_location.sql` to switch to AOI-based detection
2. Existing AOIs (sacramento) work immediately
3. Add Portland AOI if not present
4. Backfill run locations (script does this automatically)

## See Also

- **[CLAUDE.md](../CLAUDE.md)** - Full project documentation
- **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** - Coverage system architecture
- **[USAGE_GUIDE.md](USAGE_GUIDE.md)** - Day-to-day usage
