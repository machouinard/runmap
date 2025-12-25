# Phase 1 Implementation Summary: Unrun Segment Selection

**Date:** 2025-10-27
**Status:** ✅ Complete - Ready for Testing

## What Was Built

Phase 1 of the Unrun Segment Selection feature allows users to:

1. **Draw a polygon** on the map to select an area
2. **Extract centroids** of all unrun 5m segments within that polygon
3. **View results** in a scrollable panel
4. **Export data** as GeoJSON or CSV for routing tools

## Components Created

### Frontend Components

1. **[PolygonSelector.tsx](../web/src/components/PolygonSelector.tsx)**
   - Integrates MapLibre GL Draw for polygon drawing
   - Handles user clicks to create vertices
   - Double-click or close polygon to complete
   - ESC key to cancel

2. **[UnrunSegmentPanel.tsx](../web/src/components/UnrunSegmentPanel.tsx)**
   - Right-side panel showing results
   - Groups centroids by street name
   - Displays lat/lon coordinates
   - Export buttons for GeoJSON and CSV

3. **[centroidExport.ts](../web/src/lib/centroidExport.ts)**
   - `exportAsGeoJSON()` - Downloads GeoJSON FeatureCollection
   - `exportAsCSV()` - Downloads CSV with headers

### Backend API

4. **`/api/centroids/extract` endpoint** ([app.py:895-1060](../api/app.py#L895-L1060))
   - **Method:** POST
   - **Auth:** Requires API key (`@require_api_key`)
   - **Input:** GeoJSON Polygon
   - **Output:** Array of centroid objects

   **Request:**
   ```json
   {
     "polygon": {
       "type": "Polygon",
       "coordinates": [[[lon, lat], ...]]
     }
   }
   ```

   **Response:**
   ```json
   {
     "status": "success",
     "count": 42,
     "area_km2": 2.5,
     "centroids": [
       {
         "segment_id": 12345,
         "block_id": 789,
         "street_name": "J Street",
         "lon": -121.4944,
         "lat": 38.5816,
         "segment_length_m": 5.0
       }
     ]
   }
   ```

### Map Integration

5. **Updated [Map.tsx](../web/src/components/Map.tsx)**
   - Added centroid visualization layer (red circles)
   - Integrated PolygonSelector component
   - Props for polygon selection state

6. **Updated [ControlPanel.tsx](../web/src/components/ControlPanel.tsx)**
   - "Select Unrun Segments" button
   - Orange button when inactive, red when active
   - Instruction text: "Click to draw polygon, ESC to cancel"

7. **Updated [App.tsx](../web/src/App.tsx)**
   - State management for polygon selection
   - API call to `/api/centroids/extract`
   - Export handlers

## Dependencies Added

```bash
npm install @mapbox/mapbox-gl-draw @turf/centroid @turf/boolean-point-in-polygon
npm install --save-dev @types/mapbox__mapbox-gl-draw
```

## Database Query

The API endpoint uses this optimized PostGIS query:

```sql
WITH polygon AS (
    SELECT ST_GeomFromGeoJSON(%s) AS geom
),
unvisited_segments AS (
    SELECT
        bs.segment_id,
        bs.block_id,
        b.name AS street_name,
        bs.segment_geom,
        bs.segment_length_m
    FROM runmap.block_segments bs
    JOIN runmap.block_segment_visited bsv ON bs.segment_id = bsv.segment_id
    JOIN runmap.streets_blocks_32610 b ON bs.block_id = b.block_id
    WHERE bsv.visited = FALSE
        AND ST_Intersects(
            bs.segment_geom,
            (SELECT ST_Transform(geom, 32610) FROM polygon)
        )
)
SELECT
    segment_id,
    block_id,
    COALESCE(street_name, 'Unnamed') as street_name,
    ST_X(ST_Transform(ST_Centroid(segment_geom), 4326)) AS lon,
    ST_Y(ST_Transform(ST_Centroid(segment_geom), 4326)) AS lat,
    segment_length_m
FROM unvisited_segments
ORDER BY street_name, segment_id
LIMIT 5000;
```

**Performance:**
- Uses `idx_block_segments_geom` (GIST index)
- Expected query time: <200ms for 500 blocks
- Area limit: 25 km² maximum
- Result limit: 5000 segments maximum

## User Flow

### 1. Activate Selection Mode

User clicks **"Select Unrun Segments"** button in ControlPanel:
- Button turns red ("Cancel Selection")
- Map enters polygon drawing mode
- Cursor changes (via MapLibre GL Draw)

### 2. Draw Polygon

User clicks map to create vertices:
- First click: Start polygon
- Additional clicks: Add vertices
- Double-click or click first vertex: Close polygon
- ESC key: Cancel without selection

### 3. Extract Centroids

On polygon complete:
- Polygon sent to `/api/centroids/extract`
- Loading spinner shows in panel
- API queries database for unvisited segments
- Centroids calculated in WGS84

### 4. View Results

UnrunSegmentPanel appears on right side:
- Header shows count and area (e.g., "42 segments in 2.5 km²")
- Centroids grouped by street name
- Each centroid shows: lat, lon, segment length
- Red dots appear on map at centroid locations

### 5. Export Data

User clicks export button:
- **GeoJSON**: Point FeatureCollection with properties
- **CSV**: segment_id, block_id, street_name, lat, lon, segment_length_m

## File Changes Summary

### Created Files (7)

```
web/src/components/PolygonSelector.tsx
web/src/components/UnrunSegmentPanel.tsx
web/src/lib/centroidExport.ts
docs/proposals/UNRUN_SEGMENT_SELECTION.md
docs/PHASE1_IMPLEMENTATION_SUMMARY.md (this file)
```

### Modified Files (5)

```
web/src/components/Map.tsx (added centroid layer + polygon selector)
web/src/components/ControlPanel.tsx (added selection button)
web/src/App.tsx (state management + API integration)
web/src/index.css (MapLibre GL Draw styles)
api/app.py (new /api/centroids/extract endpoint)
web/package.json (new dependencies)
```

## Testing Checklist

Before deploying, verify:

- [ ] **Frontend builds successfully** (`npm run build`)
- [ ] **Button appears** in ControlPanel sidebar
- [ ] **Polygon drawing works** (click vertices, double-click to close)
- [ ] **ESC cancels** polygon drawing
- [ ] **API returns centroids** (check browser network tab)
- [ ] **Panel displays results** grouped by street
- [ ] **Red dots appear** on map at centroid locations
- [ ] **GeoJSON export works** (downloads valid file)
- [ ] **CSV export works** (opens in Excel/Google Sheets)
- [ ] **Large polygons rejected** (>25 km²)
- [ ] **Fully-covered areas** show "No unrun segments" message

## Deployment Steps

### 1. Deploy Frontend

```bash
cd web
npm run build
```

Copy `web/build/` to server:

```bash
rsync -avz --delete web/build/ mark@192.168.68.25:/home/mark/runmap/web/build/
```

### 2. Deploy Backend

No additional steps needed - API changes are in `api/app.py` which is already deployed.

Restart API if needed:

```bash
ssh mark@192.168.68.25
sudo systemctl restart runmap-api
```

### 3. Verify Deployment

- Visit https://runmap.chouinard.me/
- Open ControlPanel → "Select Unrun Segments"
- Draw polygon in Sacramento
- Verify centroids extracted and displayed

## Known Limitations

1. **Sacramento Only**: Only works where OSM data exists (Sacramento currently)
2. **Max Area**: 25 km² polygon limit (prevents abuse)
3. **Max Results**: 5000 segments (prevents memory issues)
4. **Requires Auth**: Admin API key required (prevents public abuse)

## Security Considerations

### Area Limit Protection

```python
MAX_AREA_KM2 = 25.0
if area_km2 > MAX_AREA_KM2:
    return jsonify({
        'status': 'error',
        'message': f'Selection area too large ({area_km2:.1f} km²). Maximum allowed: {MAX_AREA_KM2} km²'
    }), 400
```

### Result Limit Protection

```sql
LIMIT 5000;  -- Safety limit in SQL query
```

### Authentication

```python
@require_api_key  # Decorator on /api/centroids/extract
```

## Performance Benchmarks (Estimated)

| Polygon Size | Blocks | Unrun Segments | Query Time | Response Size |
|--------------|--------|----------------|------------|---------------|
| Small (0.5 km²) | 50 | 30 | <50ms | ~5 KB |
| Medium (5 km²) | 250 | 150 | <100ms | ~25 KB |
| Large (25 km²) | 1000 | 500 | <200ms | ~80 KB |

## Next Steps: Phase 2

Once Phase 1 is tested and validated, Phase 2 will add:

1. **OSRM Integration** - Self-hosted routing engine
2. **Route Optimization** - TSP solver for efficient routes
3. **GPX Export** - Upload route to watch/phone
4. **Route Visualization** - Purple line showing optimized route

See [UNRUN_SEGMENT_SELECTION.md](proposals/UNRUN_SEGMENT_SELECTION.md) for full Phase 2 details.

## Questions?

- **Q: Why centroids instead of full segment geometries?**
  - A: Centroids are single points (~30 bytes) vs. LineString (~200 bytes). For 500 segments, this saves ~85 KB. Also simpler for routing engines.

- **Q: Why 5m segments instead of full blocks?**
  - A: Blocks can be long (100m+). 5m segments provide granular coverage info and better routing waypoints.

- **Q: Why require API key?**
  - A: PostGIS queries are expensive. Prevents abuse from public users running city-wide extractions.

- **Q: Can I select multiple polygons?**
  - A: Not in Phase 1. Single polygon only. Phase 2+ could add multi-polygon support.

## Success Metrics

Phase 1 is successful if:

- ✅ Users can extract <500 segments in <5 seconds
- ✅ GeoJSON export works with external routing tools
- ✅ No performance degradation on map rendering
- ✅ No security issues (area limits enforced)
- ✅ API response time <500ms for typical selections

---

**Implementation Complete:** 2025-10-27
**Ready for:** User Acceptance Testing
