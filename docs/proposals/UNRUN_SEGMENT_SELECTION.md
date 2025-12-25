# Unrun Segment Selection & Route Planning: Technical Proposal

**Date:** 2025-10-27
**Status:** Proposal - Awaiting Approval
**Target:** Phase 1 (Selection & Extraction) + Phase 2 Preview (TSP Routing)

---

## Executive Summary

This proposal outlines a two-phase approach to enable intelligent route planning for completing unrun street segments in Sacramento:

**Phase 1:** Add polygon selection tool to the RunMap frontend that extracts centroids of all unrun segments within the selected area, exportable as GeoJSON/CSV.

**Phase 2:** Integrate with routing engine (e.g., OSRM, Valhalla, or jsprit) to generate optimal running routes that visit all selected unrun segments, solving the traveling salesman problem (TSP) for efficient street coverage completion.

---

## Context & Motivation

### Current System Architecture

RunMap uses a **segment-visited approach** with 5-meter subdivisions of street blocks:

-   **`block_segments`**: 52,295 segments (5m pieces of streets)
-   **`block_segment_visited`**: Boolean flags for each segment (visited = TRUE/FALSE)
-   **`block_coverage_segments`**: Aggregate coverage % per block
-   **Coverage threshold**: Blocks with <90% coverage are "incomplete"

### The Problem

When planning which streets to run next, users currently must:

1. Visually scan the map for unrun/incomplete streets (orange lines)
2. Mentally plan a route that hits multiple unrun segments
3. Miss opportunities for efficient coverage (distant segments, complex routing)

### The Solution

Enable users to:

1. **Draw a polygon** around a neighborhood/area of interest
2. **Extract centroids** of all unrun segments within that polygon
3. **Inspect the data** (modal/CSV) to verify selection and centroid extraction
4. **[Phase 2] Generate optimal route** that visits all those points efficiently

---

## Phase 1: Polygon Selection & Centroid Extraction

### 1.1 Frontend Architecture

#### New Components

```
web/src/
├── components/
│   ├── PolygonSelector.tsx          # Drawing UI component
│   ├── UnrunSegmentPanel.tsx        # Results display modal
│   └── CentroidExport.tsx           # Download buttons (GeoJSON/CSV)
├── hooks/
│   └── usePolygonSelection.ts       # Selection state & API calls
└── lib/
    └── mapUtils.ts                  # GeoJSON helpers
```

#### Dependencies to Add

```json
{
	"dependencies": {
		"@mapbox/mapbox-gl-draw": "^1.4.3",
		"@turf/centroid": "^7.0.0",
		"@turf/boolean-point-in-polygon": "^7.0.0"
	}
}
```

**Rationale:**

-   **MapLibre GL Draw**: Industry-standard drawing library, fork-compatible with MapLibre
-   **Turf.js**: Geospatial utilities for centroid calculation and polygon operations
-   **Lightweight**: Combined ~150KB gzipped

#### UI/UX Flow

1. **Activation:**

    - Add "Select Unrun Segments" button to ControlPanel
    - Button toggles polygon drawing mode (blue highlight when active)
    - Map cursor changes to crosshair

2. **Drawing:**

    - Click map to place polygon vertices
    - Visual feedback: blue outline, semi-transparent fill
    - Double-click existing vertex to close polygon
    - ESC key to cancel, Delete to clear polygon

3. **Results Display:**

    - Modal/panel slides in from right (mobile: bottom sheet)
    - Header: "Found **42 unrun segments** in selected area"
    - Scrollable list: Segment IDs, street names, coordinates
    - Action buttons:
        - "Download GeoJSON" (for routing tools)
        - "Download CSV" (for spreadsheet analysis)
        - "Clear Selection"

4. **Map Visualization:**
    - Selected polygon remains visible (blue outline)
    - Unrun segment centroids shown as red dots (z-index above all layers)
    - Hover centroid → tooltip with street name

#### State Management

```typescript
interface UnrunSegmentSelection {
	polygon: GeoJSON.Polygon | null
	centroids: CentroidPoint[]
	isDrawing: boolean
	isLoading: boolean
}

interface CentroidPoint {
	segment_id: number
	block_id: number
	street_name: string
	lon: number
	lat: number
	segment_length_m: number
}
```

**Storage Strategy:**

-   Selection state: React useState (ephemeral, not persisted)
-   Polygon drawn: localStorage (persist across refreshes)
-   Results: In-memory only (cleared on new selection)

---

### 1.2 Backend API Endpoint

#### New Route

```python
@app.route('/api/centroids/extract', methods=['POST'])
@require_api_key  # Existing auth decorator
def extract_unrun_centroids():
    """
    Extract centroids of unrun segments within a user-drawn polygon.

    Request Body:
    {
      "polygon": {
        "type": "Polygon",
        "coordinates": [[[lon, lat], [lon, lat], ...]]
      },
      "location": "sacramento"  # Optional filter
    }

    Response:
    {
      "status": "success",
      "count": 42,
      "centroids": [
        {
          "segment_id": 12345,
          "block_id": 789,
          "street_name": "J Street",
          "lon": -121.4944,
          "lat": 38.5816,
          "segment_length_m": 5.0
        },
        ...
      ]
    }
    """
```

#### SQL Query Logic

```sql
WITH polygon AS (
  -- Convert GeoJSON polygon to PostGIS geometry (SRID 4326)
  SELECT ST_GeomFromGeoJSON(%(polygon_geojson)s) AS geom
),
unvisited_segments AS (
  -- Find segments that are NOT visited (visited = FALSE)
  SELECT
    bs.segment_id,
    bs.block_id,
    b.name AS street_name,
    bs.segment_geom,
    bs.segment_length_m
  FROM runmap.block_segments bs
  JOIN runmap.block_segment_visited bsv USING (segment_id)
  JOIN runmap.streets_blocks_32610 b ON bs.block_id = b.block_id
  WHERE bsv.visited = FALSE  -- Only unrun segments
    AND bs.block_id IN (
      -- Filter to blocks in Sacramento (optional location filter)
      SELECT DISTINCT block_id
      FROM runmap.streets_blocks_32610
      WHERE ST_Intersects(
        geom_32610,
        -- Transform Sacramento boundary to UTM
        (SELECT ST_Transform(geom, 32610) FROM polygon)
      )
    )
)
SELECT
  segment_id,
  block_id,
  street_name,
  -- Calculate centroid in WGS84 for output
  ST_X(ST_Transform(ST_Centroid(segment_geom), 4326)) AS lon,
  ST_Y(ST_Transform(ST_Centroid(segment_geom), 4326)) AS lat,
  segment_length_m
FROM unvisited_segments
WHERE ST_Intersects(
  segment_geom,
  (SELECT ST_Transform(geom, 32610) FROM polygon)
)
ORDER BY street_name, segment_id;
```

**Performance Considerations:**

-   **Index Usage:**

    -   `idx_block_segments_geom` (GIST) for spatial intersection
    -   `idx_segment_visited_true` (partial index) for unvisited lookup

-   **Expected Query Time:**

    -   Polygon covering 100 blocks: <100ms
    -   Polygon covering 1000 blocks: <500ms

-   **Optimization:**
    -   Pre-filter by bounding box before expensive `ST_Intersects`
    -   LIMIT results to prevent massive extractions (e.g., max 5000 segments)

#### Error Handling

```python
# Validate polygon is valid GeoJSON
if not polygon or polygon['type'] != 'Polygon':
    return jsonify({'status': 'error', 'message': 'Invalid polygon'}), 400

# Prevent extracting entire city (limit by bounding box area)
bbox_area = calculate_bbox_area(polygon)
if bbox_area > MAX_SELECTION_AREA_KM2:  # e.g., 25 km²
    return jsonify({
        'status': 'error',
        'message': f'Selection area too large ({bbox_area:.1f} km²). Max: {MAX_SELECTION_AREA_KM2} km²'
    }), 400

# Handle no results gracefully
if len(centroids) == 0:
    return jsonify({
        'status': 'success',
        'count': 0,
        'message': 'No unrun segments found in selected area'
    })
```

---

### 1.3 Export Formats

#### GeoJSON (for routing tools)

```json
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": {
        "type": "Point",
        "coordinates": [-121.4944, 38.5816]
      },
      "properties": {
        "segment_id": 12345,
        "block_id": 789,
        "street_name": "J Street",
        "segment_length_m": 5.0
      }
    },
    ...
  ]
}
```

**Use Case:** Feed directly to OSRM/Valhalla for route optimization.

#### CSV (for spreadsheet analysis)

```csv
segment_id,block_id,street_name,lon,lat,segment_length_m
12345,789,J Street,-121.4944,38.5816,5.0
12346,789,J Street,-121.4945,38.5817,5.0
...
```

**Use Case:** Analyze in Google Sheets, sort by distance from home, etc.

---

### 1.4 Implementation Checklist

#### Frontend Tasks

-   [ ] Install dependencies (`@mapbox/mapbox-gl-draw`, `@turf/turf`)
-   [ ] Create `PolygonSelector.tsx` component with MapLibre GL Draw
-   [ ] Add "Select Unrun Segments" button to ControlPanel
-   [ ] Implement drawing mode toggle (blue cursor, ESC to cancel)
-   [ ] Create `usePolygonSelection.ts` hook for state management
-   [ ] Build `UnrunSegmentPanel.tsx` modal with results display
-   [ ] Add centroid visualization layer (red dots on map)
-   [ ] Implement GeoJSON export button
-   [ ] Implement CSV export button
-   [ ] Add loading spinner during API call
-   [ ] Write unit tests for polygon validation

#### Backend Tasks

-   [ ] Create `/api/centroids/extract` endpoint in `api/app.py`
-   [ ] Write SQL query for unvisited segment extraction
-   [ ] Add polygon area validation (prevent city-wide selections)
-   [ ] Implement GeoJSON response formatting
-   [ ] Add error handling (invalid polygon, no results, timeout)
-   [ ] Write integration test with sample polygon
-   [ ] Add performance logging (query time, segment count)
-   [ ] Document API in OpenAPI/Swagger spec

#### Testing Tasks

-   [ ] Unit test: polygon drawing with 3-10 vertices
-   [ ] Unit test: double-click to close polygon
-   [ ] Integration test: API with Sacramento polygon (~100 segments expected)
-   [ ] Integration test: Empty result (fully-run neighborhood)
-   [ ] Performance test: Large polygon (500+ blocks)
-   [ ] UI test: Mobile responsiveness (bottom sheet instead of modal)

---

## Phase 2: Route Optimization (Future Work)

### 2.1 Problem Statement

**Traveling Salesman Problem (TSP):**

Given N unrun segment centroids, find the shortest route that:

1. Starts from user's location (e.g., home)
2. Visits all N centroids (within running distance of segments)
3. Returns to start (or ends at specified location)
4. Respects street network (not straight-line "as crow flies")

**Constraints:**

-   Must use actual streets (not Euclidean distance)
-   Route should be runnable (avoid highways, private roads)
-   Optimize for total distance, not time (constant running pace assumed)

### 2.2 Recommended Approach: OSRM + Genetic Algorithm

#### Option A: OSRM (Open Source Routing Machine) - **RECOMMENDED**

**Pros:**

-   ✅ Open source, self-hostable (no API costs)
-   ✅ Excellent OSM integration (same data source as RunMap streets)
-   ✅ Fast (<1 second for 50 waypoints)
-   ✅ Supports "foot" profile (pedestrian/running routing)
-   ✅ Trip optimization API: `/trip` endpoint solves TSP directly

**Cons:**

-   ❌ Requires Docker container (adds deployment complexity)
-   ❌ ~2GB disk space for California extract

**Architecture:**

```
User selects polygon
  ↓
Frontend sends centroids to /api/routes/optimize
  ↓
Backend calls OSRM /trip endpoint
  ↓
OSRM returns optimized waypoint order + route geometry
  ↓
Frontend renders route on map (purple line)
  ↓
User exports GPX for watch/phone
```

**Example OSRM API Call:**

```bash
curl "http://localhost:5000/trip/v1/foot/-121.494,38.581;-121.495,38.582;-121.496,38.583?overview=full&geometries=geojson"
```

**Response:**

```json
{
  "trips": [{
    "geometry": { "type": "LineString", "coordinates": [[...]] },
    "distance": 5432.1,  // meters
    "duration": 3259.2,  // seconds
    "legs": [
      {"distance": 123.4, "duration": 74.0, "steps": [...]},
      ...
    ]
  }],
  "waypoints": [
    {"waypoint_index": 0, "trips_index": 0, "location": [-121.494, 38.581]},
    {"waypoint_index": 2, "trips_index": 0, "location": [-121.496, 38.583]},
    {"waypoint_index": 1, "trips_index": 0, "location": [-121.495, 38.582]}
  ]
}
```

**Key Feature:** `waypoints` array shows optimized order (0→2→1, not 0→1→2).

#### Option B: Valhalla (Mapbox alternative)

**Pros:**

-   ✅ Better handling of multi-modal routing (bike + foot)
-   ✅ More detailed turn-by-turn instructions

**Cons:**

-   ❌ Heavier than OSRM (~4GB disk space)
-   ❌ Slower route calculation
-   ❌ More complex setup

**Verdict:** Use OSRM unless you need bike routing.

#### Option C: jsprit (Vehicle Routing Problem solver)

**Pros:**

-   ✅ More sophisticated constraints (time windows, capacity, multiple vehicles)
-   ✅ Can handle 1000+ waypoints

**Cons:**

-   ❌ Requires Java runtime
-   ❌ Doesn't understand street network (needs pre-computed distance matrix)
-   ❌ Overkill for simple TSP

**Verdict:** Only if you expand to multi-day route planning or group runs.

### 2.3 Proposed Phase 2 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Frontend (React + MapLibre GL)                             │
│  ┌────────────────────┐  ┌──────────────────────────────┐  │
│  │ PolygonSelector    │→ │ UnrunSegmentPanel            │  │
│  │ (Phase 1)          │  │ - Shows 42 unrun segments    │  │
│  └────────────────────┘  │ - "Optimize Route" button ← │  │
│                          └──────────────┬───────────────┘  │
│                                         │                   │
│  ┌──────────────────────────────────────▼────────────────┐ │
│  │ RouteOptimizer Component                              │ │
│  │ - Loading spinner ("Calculating route...")           │ │
│  │ - Renders optimized route (purple line)              │ │
│  │ - Shows stats: "6.2 miles, ~50 min, visits 42 segs"  │ │
│  │ - "Download GPX" button                               │ │
│  └───────────────────────────┬───────────────────────────┘ │
└────────────────────────────────┼─────────────────────────────┘
                                 │ POST /api/routes/optimize
                                 │ { centroids: [...] }
┌────────────────────────────────▼─────────────────────────────┐
│  Backend API (Flask)                                         │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ /api/routes/optimize                                    │ │
│  │ 1. Validate centroids (max 100 waypoints)               │ │
│  │ 2. Format as OSRM coordinates                           │ │
│  │ 3. Call OSRM /trip endpoint                             │ │
│  │ 4. Parse response, extract geometry + waypoint order    │ │
│  │ 5. Generate GPX file                                    │ │
│  │ 6. Return GeoJSON route + download link                 │ │
│  └──────────────────────────┬──────────────────────────────┘ │
└─────────────────────────────┼────────────────────────────────┘
                              │ HTTP GET
                              │ /trip/v1/foot/lon,lat;lon,lat;...
┌─────────────────────────────▼────────────────────────────────┐
│  OSRM Docker Container                                       │
│  - California OSM extract (foot profile)                     │
│  - Exposed on localhost:5000                                 │
│  - Auto-restart via docker-compose                           │
└──────────────────────────────────────────────────────────────┘
```

### 2.4 Phase 2 Implementation Estimate

**Effort:** 12-16 hours

-   OSRM setup (Docker, OSM extract): 2-3 hours
-   Backend `/api/routes/optimize` endpoint: 3-4 hours
-   Frontend `RouteOptimizer` component: 4-5 hours
-   GPX export logic: 2-3 hours
-   Testing: 2-3 hours

**Dependencies:**

-   Docker installed on server
-   California OSM extract (~500MB download)
-   Python `requests` library for OSRM API calls

---

## Alternative Approaches Considered

### Alternative 1: Client-Side TSP Solver

**Approach:** Use JavaScript library (e.g., `tsp-solver.js`) to solve TSP in browser.

**Pros:**

-   ✅ No server-side routing engine needed
-   ✅ Instant results (no network latency)

**Cons:**

-   ❌ Uses straight-line distance (not street network)
-   ❌ Routes would cut through buildings/parks
-   ❌ Not runnable in practice

**Verdict:** ❌ Rejected - Must use street network.

### Alternative 2: Google Maps Directions API

**Approach:** Use Google's waypoint optimization.

**Pros:**

-   ✅ Excellent routing quality
-   ✅ No self-hosting required

**Cons:**

-   ❌ **Costs money** ($5-10 per 1000 requests)
-   ❌ Max 25 waypoints (RunMap needs 50-100+)
-   ❌ Vendor lock-in

**Verdict:** ❌ Rejected - Cost prohibitive, waypoint limit too low.

### Alternative 3: Mapbox Directions API

**Approach:** Similar to Google Maps.

**Cons:**

-   ❌ Still costs money ($4 per 1000 requests)
-   ❌ Max 25 waypoints

**Verdict:** ❌ Rejected - Same issues as Google.

### Alternative 4: Pre-compute Distance Matrix + Simulated Annealing

**Approach:**

1. Calculate distance between all pairs of centroids (N² operations)
2. Use simulated annealing to find good (not optimal) route

**Pros:**

-   ✅ Can handle 100+ waypoints

**Cons:**

-   ❌ Requires implementing SA algorithm
-   ❌ Not guaranteed optimal
-   ❌ Still needs routing engine for distance matrix

**Verdict:** ⚠️ Fallback if OSRM /trip is too slow for 100+ waypoints.

---

## Data Model Changes

### New Tables (Phase 1)

**None required!** All data derived from existing `block_segments` and `block_segment_visited`.

### New Tables (Phase 2 - Optional)

```sql
-- Cache optimized routes for repeated selections
CREATE TABLE IF NOT EXISTS runmap.route_cache (
  route_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  polygon geometry(Polygon, 4326) NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  centroid_count INTEGER NOT NULL,
  route_geom geometry(LineString, 4326) NOT NULL,
  total_distance_m NUMERIC NOT NULL,
  waypoint_order INTEGER[] NOT NULL,  -- Optimized order of segment_ids
  gpx_file_path TEXT
);

CREATE INDEX idx_route_cache_polygon ON runmap.route_cache USING GIST(polygon);
CREATE INDEX idx_route_cache_created ON runmap.route_cache(created_at DESC);
```

**Purpose:** Avoid re-calculating same route if user selects identical polygon.

**Cache Invalidation:** Delete routes older than 7 days (coverage changes as runs are uploaded).

---

## Security Considerations

### Phase 1 Risks

1. **Polygon Size Abuse:**

    - **Risk:** User draws city-wide polygon, extracts 50,000 segments, DoS the database
    - **Mitigation:** Max area limit (25 km²), max result count (5000 segments)

2. **API Key Leakage:**

    - **Risk:** Authenticated endpoint, but key could leak in browser storage
    - **Mitigation:** Use existing `@require_api_key` decorator, rotate keys regularly

3. **CSRF on Export:**
    - **Risk:** Malicious site triggers CSV download
    - **Mitigation:** Require API key in POST request (not vulnerable to CSRF)

### Phase 2 Risks

1. **OSRM Container Exposure:**

    - **Risk:** OSRM exposed on public port, external abuse
    - **Mitigation:** Bind to localhost only, Flask proxies requests

2. **Route Calculation DoS:**
    - **Risk:** User requests 1000 waypoints, OSRM takes 30 seconds, blocks other requests
    - **Mitigation:** Rate limit (1 route per 10 seconds per user), max 100 waypoints

---

## Testing Strategy

### Phase 1 Tests

#### Unit Tests

```typescript
// Test polygon drawing
test('closes polygon on double-click', () => {
	// Simulate clicks: (0,0), (1,0), (1,1), (0,1), (0,0)
	// Expect: polygon closed, 4 vertices
})

test('validates polygon has at least 3 vertices', () => {
	// Expect: error if <3 vertices
})
```

```python
# Test centroid extraction
def test_extract_centroids_empty_polygon():
    # Polygon in fully-run neighborhood
    # Expect: {"count": 0, "centroids": []}

def test_extract_centroids_valid_selection():
    # Polygon covering known unrun segments
    # Expect: segment_ids [12345, 12346, ...]
```

#### Integration Tests

```bash
# End-to-end test
1. Draw polygon via MapLibre Draw API
2. POST polygon to /api/centroids/extract
3. Verify response contains expected segments
4. Trigger GeoJSON export
5. Validate exported file structure
```

### Phase 2 Tests

```python
def test_route_optimization_3_waypoints():
    # Simple triangle: A, B, C
    # Expect: A→B→C or A→C→B (both valid)

def test_route_optimization_osrm_timeout():
    # Mock OSRM timeout
    # Expect: graceful error, not 500 crash
```

---

## Performance Benchmarks (Estimated)

### Phase 1

| Operation                             | Input                          | Expected Time               |
| ------------------------------------- | ------------------------------ | --------------------------- |
| SQL query (small polygon, 50 blocks)  | 50 blocks, 30 unrun segments   | <50ms                       |
| SQL query (large polygon, 500 blocks) | 500 blocks, 300 unrun segments | <200ms                      |
| GeoJSON export                        | 100 segments                   | <10ms (in-memory)           |
| CSV export                            | 100 segments                   | <5ms (simple serialization) |

### Phase 2

| Operation                  | Input                    | Expected Time |
| -------------------------- | ------------------------ | ------------- |
| OSRM /trip (10 waypoints)  | 10 centroids             | 200-500ms     |
| OSRM /trip (50 waypoints)  | 50 centroids             | 1-2 seconds   |
| OSRM /trip (100 waypoints) | 100 centroids            | 5-10 seconds  |
| GPX generation             | 6-mile route, 100 points | <100ms        |

**Note:** OSRM times assume California extract pre-loaded. Initial container startup: ~30 seconds.

---

## Rollout Plan

### Phase 1 Rollout

1. **Week 1: Development**

    - Day 1-2: Frontend polygon drawing component
    - Day 3-4: Backend API endpoint + SQL query
    - Day 5: Export logic (GeoJSON/CSV)

2. **Week 2: Testing & Refinement**

    - Day 1-2: Integration testing, bug fixes
    - Day 3: UI polish (loading states, error messages)
    - Day 4: Performance optimization (query tuning)
    - Day 5: Documentation (user guide, API docs)

3. **Week 3: Deployment**
    - Deploy to staging server
    - User acceptance testing (dogfood on actual runs)
    - Deploy to production

### Phase 2 Rollout (Future)

1. **Milestone 1: OSRM Setup** (3-4 weeks after Phase 1)

    - Set up Docker container
    - Load California OSM extract
    - Test foot routing profile

2. **Milestone 2: Integration** (1 week)

    - Build `/api/routes/optimize` endpoint
    - Test with Phase 1 extracted centroids

3. **Milestone 3: Frontend** (1 week)
    - Add "Optimize Route" button to UnrunSegmentPanel
    - Render route on map
    - GPX export

---

## Success Metrics

### Phase 1 Metrics

-   **Adoption:** >50% of active users try polygon selection within 1 month
-   **Utility:** Average 20-100 segments extracted per selection
-   **Performance:** 95th percentile API response time <500ms
-   **Exports:** >30% of selections result in GeoJSON/CSV download

### Phase 2 Metrics

-   **Route Quality:** Generated routes are <110% of theoretical optimal (TSP lower bound)
-   **User Satisfaction:** >80% of users report routes are "runnable and efficient"
-   **Performance:** OSRM responds in <3 seconds for 90% of requests
-   **Completion:** Users who follow generated routes complete >80% of selected segments

---

## Open Questions

1. **Segment Granularity:** Should we extract ALL unvisited 5m segments, or only segments from blocks <90% covered?

    - **Recommendation:** Extract all unvisited segments (current proposal). Rationale: Blocks with 85% coverage still have unrun gaps worth targeting.

2. **Multi-Polygon Selection:** Allow multiple disjoint polygons (e.g., "select these 3 neighborhoods")?

    - **Recommendation:** Phase 1 = single polygon. Phase 2+ could add multi-polygon if requested.

3. **Start/End Points:** Phase 2 routing should start/end where?

    - **Options:** (a) User's home (configured in settings), (b) Nearest centroid to current location, (c) User clicks "Start here"
    - **Recommendation:** User clicks map to set start point (most flexible).

4. **OSRM Hosting:** Self-host or use public OSRM instance?

    - **Recommendation:** Self-host on RunMap server (avoid rate limits, customize foot profile).

5. **Waypoint Limit:** What's the max number of centroids for route optimization?
    - **Recommendation:** Phase 2 MVP = 50 waypoints (2-second OSRM response). Phase 2+ = 100 waypoints if performance acceptable.

---

## Appendix A: Similar Tools in the Wild

### Strava Route Builder

-   **Features:** Click waypoints, generates route on bike/run network
-   **Limitation:** No TSP optimization (waypoints visited in order clicked)
-   **RunMap Advantage:** Auto-optimize waypoint order

### Wandrer.earth

-   **Features:** Tracks % of streets covered (similar to RunMap)
-   **Limitation:** No route planning for unrun streets
-   **RunMap Advantage:** Integrated selection + routing

### CityStrides

-   **Features:** Leaderboards for city completion
-   **Limitation:** No polygon selection or route export
-   **RunMap Advantage:** Targeted neighborhood selection

---

## Appendix B: Estimated Costs

### Phase 1 Costs

-   **Development Time:** 40-50 hours (1-2 weeks)
-   **Infrastructure:** $0 (uses existing Flask API + PostGIS)
-   **Third-Party Services:** $0 (all open source)

### Phase 2 Costs

-   **Development Time:** 60-80 hours (2-3 weeks)
-   **Infrastructure:** +500MB disk space (OSM extract), +512MB RAM (OSRM container)
-   **Third-Party Services:** $0 (self-hosted OSRM)
-   **Ongoing:** ~2 hours/quarter to update OSM extract

**Total Estimated Cost:** $0 cash, ~100-130 developer hours

---

## Appendix C: Future Enhancements (Beyond Phase 2)

1. **Multi-Day Route Planning:**

    - Split large selections into multiple 5-10 mile runs
    - Example: "Cover this neighborhood in 3 runs"

2. **Social Features:**

    - Share generated routes with other users
    - "Challenge" friends to complete same route

3. **Route Preferences:**

    - Avoid steep hills (use elevation data)
    - Prefer shaded streets (tree canopy from OSM)
    - Stick to well-lit areas (streetlight data)

4. **Real-Time Updates:**

    - As you run, show remaining segments on watch
    - Re-route if you deviate from plan

5. **Integration with Garmin/Apple Watch:**
    - One-click "Send route to watch"

---

## Recommendation & Next Steps

**Recommendation:** ✅ **Proceed with Phase 1 implementation.**

**Rationale:**

-   Low risk (no new tables, uses existing data)
-   High value (enables data-driven route planning)
-   Fast to build (1-2 weeks)
-   Unlocks Phase 2 routing (huge UX win)

**Next Steps:**

1. **Get User Approval** on:

    - UI/UX flow (polygon drawing → modal → export)
    - Export formats (GeoJSON + CSV sufficient?)
    - Segment granularity (all unvisited vs. only <90% blocks)

2. **Refine Phase 2 Scope:**

    - Confirm OSRM as routing engine
    - Decide on waypoint limit (50 vs. 100)
    - Determine start/end point UX

3. **Begin Development:**
    - Create feature branch `feature/unrun-segment-selection`
    - Set up MapLibre GL Draw
    - Build `/api/centroids/extract` endpoint
    - Iterate on UI based on dogfooding

---

**Questions? Concerns? Feedback?** Let's discuss before I start writing code!
