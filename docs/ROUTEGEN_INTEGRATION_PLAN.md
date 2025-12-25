# routegen Integration Plan

**Status:** Planning
**Priority:** Medium
**Type:** Feature Addition (Turn-by-Turn Navigation)
**Estimated Effort:** 6-9 hours

---

## Overview

Integrate the `routegen` Python tool into RunMap to add turn-by-turn directions to any uploaded GPX file. This enables conversion of hand-drawn or generated routes into WorkOutDoors-compatible navigation files with audio/visual turn prompts.

### Goal
Add turn-by-turn direction generation for any uploaded GPX file, allowing you to enhance routes you're satisfied with before importing to WorkOutDoors.

### Scope & Constraints
- **Single-user feature** (admin-only, requires API key)
- **Medium priority** (safe, non-disruptive integration)
- **No changes to existing features** (purely additive)
- **Works with any uploaded GPX file** (not tied to activity overlays or sharing)
- **GraphHopper already running** at https://map.chouinard.me (verified)

---

## Current State Analysis

### What routegen Does

**routegen** is a Python CLI tool that converts hand-drawn routes (KML/GPX) into turn-by-turn GPX route files for WorkOutDoors on Apple Watch.

**Input → Output Flow:**
1. **Input**: Hand-drawn KML from Google My Maps OR existing GPX track
2. **Resampling**: Optionally thins waypoints to reduce routing overhead (default: 30m spacing)
3. **Routing**: Sends coordinates to GraphHopper routing engine for turn-by-turn directions
4. **Normalization**: Converts GraphHopper turn codes to standard types (Left, Right, etc.)
5. **Output**: GPX route file with `<rtept>` elements containing turn cues in `<name>` tags

### routegen Source Structure

**Location:** `/Users/markchouinard/Development/GIS/runs-cdm/python/routegen/`

```
routegen/
├── routegen/
│   ├── __init__.py                    # Version info (0.1.0)
│   ├── cli.py                         # Typer CLI (build, preview commands)
│   ├── io/
│   │   ├── readers.py                 # read_kml(), read_gpx(), read_track()
│   │   ├── writers.py                 # write_gpx_route() + format variants
│   │   └── tcx_writer.py              # write_tcx_course() - full TCX support
│   ├── router/
│   │   └── graphhopper.py             # GraphHopperClient class + routing logic
│   ├── cues/
│   │   └── normalize.py               # TurnType enum, TurnCue, normalization
│   └── utils/
│       ├── geo.py                     # haversine_distance(), resample_coordinates()
│       └── validation.py              # check_input_quality(), validate_route_coverage()
```

### Key Dependencies

From `python/routegen/pyproject.toml`:
- `typer>=0.12.0` - CLI framework
- `httpx>=0.27.0` - HTTP client for routing
- `lxml>=5.1.0` - XML parsing for KML
- `gpxpy>=1.6.0` - GPX parsing
- `tenacity>=8.2.0` - Retry logic
- `rich>=13.7.0` - CLI output formatting

**Compatibility:** No conflicts with existing Flask API dependencies.

### GraphHopper Setup

**Status:** Already running at https://map.chouinard.me

**Nginx Configuration:**
```nginx
upstream graphhopper { server 127.0.0.1:8989; }

server {
  listen 443 ssl http2;
  server_name map.chouinard.me;

  location ~ ^/(route|isochrone|map-matching|spt|nearest|info|health) {
    limit_req zone=gh_api burst=20 nodelay;
    proxy_pass http://graphhopper;
  }
}
```

**Docker:** `israelhikingmap/graphhopper:latest` (ARM64-compatible)
**OSM Data:** Sacramento region (~200MB PBF)
**Port:** 8989 (internal), proxied via Nginx

---

## Implementation Plan

## Phase 1: Backend Setup (Flask API Integration)

### 1.1 Install routegen Package
**Location:** Server Python environment (same as Flask API)

**Development (Mac):**
```bash
cd /Users/markchouinard/Development/GIS/runs-cdm/python/routegen
pip install -e .
```

**Production (Server):**
```bash
ssh mark@server
cd /home/mark/runmap/python/routegen
source /home/mark/runmap/venv/bin/activate  # or wherever Flask venv lives
pip install -e .
```

**Verification:**
```bash
python -c "from routegen.router.graphhopper import GraphHopperClient; print('OK')"
routegen --help  # Should show CLI commands
```

### 1.2 Add Flask API Endpoint

**File:** `api/app.py` (or create new `api/routes.py` for organization)

**Endpoint:** `POST /api/routes/generate-turn-by-turn`

**Request:**
```json
{
  "gpx_content": "<gpx>...</gpx>",  // GPX track to convert
  "route_name": "Saturday Morning Route",
  "output_format": "gpx"  // or "tcx"
}
```

**Response:** Binary GPX/TCX file download

**Implementation:**
```python
from flask import request, send_file
from routegen.io.readers import read_track
from routegen.router.graphhopper import GraphHopperClient
from routegen.io.writers import write_gpx_route
from routegen.io.tcx_writer import write_tcx_course
from routegen.utils.validation import validate_route_coverage
from pathlib import Path
import tempfile
import uuid

@app.route('/api/routes/generate-turn-by-turn', methods=['POST'])
@require_api_key
def generate_turn_by_turn():
    """Convert GPX track to turn-by-turn route"""
    try:
        # Parse request
        data = request.get_json()
        gpx_content = data.get('gpx_content')
        route_name = data.get('route_name', 'Route')
        output_format = data.get('output_format', 'gpx')

        if not gpx_content:
            return jsonify({'error': 'gpx_content required'}), 400

        # Save temp input file
        with tempfile.NamedTemporaryFile(mode='w', suffix='.gpx', delete=False) as f:
            f.write(gpx_content)
            input_path = Path(f.name)

        # Read and parse track
        coordinates = read_track(input_path)

        if len(coordinates) == 0:
            return jsonify({'error': 'No coordinates found in GPX'}), 400

        # Route through GraphHopper
        with GraphHopperClient(base_url="http://localhost:8989", profile="foot") as client:
            if not client.health_check():
                return jsonify({'error': 'GraphHopper service unavailable'}), 503

            cues, route_path = client.route(coordinates)

        # Validate route coverage
        validation_result = validate_route_coverage(coordinates, route_path)
        if validation_result.has_significant_deviation:
            app.logger.warning(f'Route has significant deviation: {validation_result.max_deviation_m}m')
            # Continue anyway, but could add to response

        # Write output file
        output_path = Path(tempfile.mktemp(suffix=f'.{output_format}'))

        if output_format == 'tcx':
            write_tcx_course(cues, route_path, output_path, course_name=route_name)
        else:
            write_gpx_route(cues, route_path, output_path, route_name=route_name)

        # Clean up input
        input_path.unlink()

        # Return file
        return send_file(
            output_path,
            as_attachment=True,
            download_name=f"{route_name.replace(' ', '_')}_turn_by_turn.{output_format}"
        )

    except Exception as e:
        app.logger.error(f'Turn-by-turn generation failed: {str(e)}', exc_info=True)
        return jsonify({'error': str(e)}), 500
```

**Error Handling:**
- GraphHopper unreachable → 503 Service Unavailable
- Invalid GPX → 400 Bad Request
- Route validation fails → Log warning, continue (or 422 with warnings)
- Timeout → 504 Gateway Timeout (add `timeout=60` to client)

**Optional Enhancements:**
- Add `resample_spacing` parameter (default: 30m)
- Return validation warnings in response
- Add route statistics (total distance, turn count)
- Cache routes by input hash

---

## Phase 2: Frontend Integration (Upload & Generate UI)

### 2.1 New Component: TurnByTurnGenerator

**File:** `web/src/components/TurnByTurnGenerator.tsx`

**UI Elements:**
- **File upload input** (accepts .gpx, .kml)
- **Route name text field** (optional, defaults to filename)
- **Output format radio buttons** (GPX / TCX)
- **"Generate Turn-by-Turn" button** (primary action)
- **Loading state** (spinner + "Routing through GraphHopper...")
- **Success state** (checkmark + auto-download)
- **Error display** (red alert with API error message)
- **Validation warnings** (amber warning if route deviates)

**Component Structure:**
```tsx
import { useState } from 'react'
import { Upload, Navigation, AlertCircle, CheckCircle } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'

interface TurnByTurnGeneratorProps {
  // Optional: could accept centroids from UnrunSegmentPanel
}

export function TurnByTurnGenerator() {
  const [file, setFile] = useState<File | null>(null)
  const [routeName, setRouteName] = useState('')
  const [outputFormat, setOutputFormat] = useState<'gpx' | 'tcx'>('gpx')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)
  const { getAuthHeaders } = useAuth()

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const selectedFile = e.target.files?.[0]
    if (selectedFile) {
      setFile(selectedFile)
      setRouteName(selectedFile.name.replace(/\.(gpx|kml)$/i, ''))
      setError(null)
    }
  }

  const handleGenerate = async () => {
    if (!file) return

    setLoading(true)
    setError(null)
    setSuccess(false)

    try {
      // Read file content
      const gpxContent = await file.text()

      // Call API
      const response = await fetch('/api/routes/generate-turn-by-turn', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...getAuthHeaders()
        },
        body: JSON.stringify({
          gpx_content: gpxContent,
          route_name: routeName,
          output_format: outputFormat
        })
      })

      if (!response.ok) {
        const error = await response.json()
        throw new Error(error.error || 'Failed to generate route')
      }

      // Download file
      const blob = await response.blob()
      const url = window.URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `${routeName.replace(/\s+/g, '_')}_turn_by_turn.${outputFormat}`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      window.URL.revokeObjectURL(url)

      setSuccess(true)
      setTimeout(() => setSuccess(false), 3000)

    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="border-t border-gray-200 pt-4">
      <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-3">
        Turn-by-Turn Navigation
      </h3>

      <div className="space-y-3">
        {/* File upload */}
        <label className="block">
          <span className="text-sm text-gray-700">Upload GPX/KML</span>
          <input
            type="file"
            accept=".gpx,.kml"
            onChange={handleFileChange}
            className="block w-full text-sm text-gray-500 file:mr-4 file:py-2 file:px-4 file:rounded-md file:border-0 file:text-sm file:font-semibold file:bg-blue-50 file:text-blue-700 hover:file:bg-blue-100"
          />
        </label>

        {file && (
          <>
            {/* Route name */}
            <label className="block">
              <span className="text-sm text-gray-700">Route Name</span>
              <input
                type="text"
                value={routeName}
                onChange={(e) => setRouteName(e.target.value)}
                className="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 sm:text-sm"
              />
            </label>

            {/* Output format */}
            <div className="flex items-center space-x-4">
              <span className="text-sm text-gray-700">Format:</span>
              <label className="flex items-center">
                <input
                  type="radio"
                  value="gpx"
                  checked={outputFormat === 'gpx'}
                  onChange={() => setOutputFormat('gpx')}
                  className="mr-2"
                />
                <span className="text-sm">GPX</span>
              </label>
              <label className="flex items-center">
                <input
                  type="radio"
                  value="tcx"
                  checked={outputFormat === 'tcx'}
                  onChange={() => setOutputFormat('tcx')}
                  className="mr-2"
                />
                <span className="text-sm">TCX</span>
              </label>
            </div>

            {/* Generate button */}
            <button
              onClick={handleGenerate}
              disabled={loading}
              className="w-full px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-gray-400 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2"
            >
              {loading ? (
                <>
                  <div className="animate-spin h-4 w-4 border-2 border-white border-t-transparent rounded-full" />
                  Generating...
                </>
              ) : (
                <>
                  <Navigation className="w-4 h-4" />
                  Generate Turn-by-Turn
                </>
              )}
            </button>
          </>
        )}

        {/* Status messages */}
        {error && (
          <div className="flex items-start gap-2 p-3 bg-red-50 border border-red-200 rounded-md">
            <AlertCircle className="w-4 h-4 text-red-600 mt-0.5" />
            <div className="text-sm text-red-800">{error}</div>
          </div>
        )}

        {success && (
          <div className="flex items-center gap-2 p-3 bg-green-50 border border-green-200 rounded-md">
            <CheckCircle className="w-4 h-4 text-green-600" />
            <div className="text-sm text-green-800">Route generated successfully!</div>
          </div>
        )}

        {/* Help text */}
        <p className="text-xs text-gray-500">
          Converts GPX tracks into turn-by-turn routes for WorkOutDoors
        </p>
      </div>
    </div>
  )
}
```

### 2.2 Integration Point

**Option A: Add to ControlPanel** (Recommended)
- Below "Planned Route Overlay" section
- Keeps all route tools centralized

**Option B: Separate Admin Tools Page**
- Accessible via hamburger menu
- Better for multiple admin features

**Option C: Modal/Popup**
- Floating dialog triggered by toolbar button
- Less clutter in main UI

**Implementation for Option A:**

**File:** `web/src/components/ControlPanel.tsx`

```tsx
import { TurnByTurnGenerator } from './TurnByTurnGenerator'

// Inside ControlPanel render:
{isAdmin && (
  <TurnByTurnGenerator />
)}
```

---

## Phase 3: GraphHopper Configuration Verification

### 3.1 Test GraphHopper Health

**Development (Mac):**
```bash
curl http://localhost:8989/health
```

**Production (Server):**
```bash
curl http://localhost:8989/health
curl https://map.chouinard.me/health
```

**Expected Response:**
```json
{"status":"ok"}
```

### 3.2 Test Routing Endpoint

```bash
curl "http://localhost:8989/route?point=38.5816,-121.4944&point=38.5800,-121.4930&vehicle=foot&locale=en&instructions=true&points_encoded=false"
```

**Expected:** JSON with `paths[0].instructions` array containing turn instructions

### 3.3 Configuration in Flask

**Default:** Use `http://localhost:8989` (since Flask runs on same server)

**If Flask is Dockerized/Isolated:** Use `https://map.chouinard.me` (public URL)

**Environment Variable (Optional):**
```bash
# Add to .env
GRAPHHOPPER_URL=http://localhost:8989
```

**In Flask:**
```python
GRAPHHOPPER_URL = os.getenv('GRAPHHOPPER_URL', 'http://localhost:8989')
```

---

## Phase 4: Testing & Validation

### 4.1 Test Files

**Sample files in routegen:**
- `python/routegen/examples/input/sample.kml`
- Create test GPX from activities dashboard

**Test Routes:**
1. **Short route** (~2 miles, 10-20 turns) - fast test
2. **Medium route** (~5 miles, 30-50 turns) - typical use case
3. **Long route** (~10+ miles, 100+ turns) - stress test
4. **Complex route** (many small turns in tight grid) - validation test

### 4.2 Backend Testing

**Test 1: Health Check**
```bash
python -c "
from routegen.router.graphhopper import GraphHopperClient
with GraphHopperClient('http://localhost:8989', 'foot') as client:
    print('Health:', client.health_check())
"
```

**Test 2: API with curl**
```bash
# Save sample GPX to file
cat > test-route.gpx << 'EOF'
<?xml version="1.0"?>
<gpx version="1.1">
  <trk>
    <trkseg>
      <trkpt lat="38.5816" lon="-121.4944"/>
      <trkpt lat="38.5800" lon="-121.4930"/>
    </trkseg>
  </trk>
</gpx>
EOF

# Call API
curl -X POST http://localhost:5000/api/routes/generate-turn-by-turn \
  -H "X-API-Key: $ADMIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"gpx_content\": \"$(cat test-route.gpx | sed 's/"/\\"/g')\", \"route_name\": \"Test Route\"}" \
  --output turn-by-turn.gpx

# Verify output
grep -o '<rtept' turn-by-turn.gpx | wc -l  # Should show route points
grep '<name>' turn-by-turn.gpx  # Should show turn instructions
```

### 4.3 Frontend Testing

**Test Scenarios:**
1. **Happy path:** Upload GPX → generate → download → verify turn cues
2. **Invalid input:** Upload non-GPX file → should show error
3. **Empty file:** Upload empty GPX → should show error
4. **Long route:** 10+ mile route → should complete within 60s
5. **GraphHopper down:** Stop docker container → should show 503 error
6. **No auth:** Remove API key → should show 401 error

### 4.4 WorkOutDoors Validation

**Final verification:**
1. Transfer generated GPX to iPhone via AirDrop/Files app
2. Open WorkOutDoors
3. Import route: Settings → Routes → Import
4. Start navigation on route
5. **Verify:**
   - Turn prompts appear at intersections
   - Turn type is correct (Left, Right, Slight Left, etc.)
   - Distance to next turn is accurate
   - Audio prompts work

---

## File Changes Summary

### New Files

**Frontend:**
1. `web/src/components/TurnByTurnGenerator.tsx` - Upload & generate UI component (~150 lines)

**Backend:**
2. `api/routes.py` (optional) - Separate module for routing endpoints (~100 lines)
   - Alternative: Add directly to `api/app.py`

**Documentation:**
3. `docs/ROUTEGEN_INTEGRATION_PLAN.md` - This file

### Modified Files

**Backend:**
1. `api/app.py`
   - Add `/api/routes/generate-turn-by-turn` endpoint (~80 lines)
   - Or import from `api/routes.py` if separated

**Frontend:**
2. `web/src/components/ControlPanel.tsx`
   - Import and render `TurnByTurnGenerator` component (~10 lines)
   - Wrap in `{isAdmin && <TurnByTurnGenerator />}` for access control

**Dependencies:**
3. `python/requirements.txt` or `api/requirements.txt`
   - Add routegen package reference (or install via `pip install -e`)

**Documentation:**
4. `docs/USAGE_GUIDE.md`
   - Add section: "Generating Turn-by-Turn Routes"
   - Document upload → generate → WorkOutDoors workflow

### No Changes To

- Database schema (no persistence needed)
- Existing GPX upload/processing pipeline
- Activity overlay features
- Tile generation
- Map rendering
- Centroids extraction
- Authentication system

---

## Deployment Checklist

### Development Environment (Mac)

- [ ] Verify GraphHopper running: `curl http://localhost:8989/health`
- [ ] Install routegen: `cd python/routegen && pip install -e .`
- [ ] Test routegen CLI: `routegen build examples/input/sample.kml`
- [ ] Verify routegen import: `python -c "from routegen.router.graphhopper import GraphHopperClient; print('OK')"`
- [ ] Add Flask endpoint to `api/app.py`
- [ ] Test endpoint with curl
- [ ] Create `TurnByTurnGenerator.tsx` component
- [ ] Add component to `ControlPanel.tsx`
- [ ] Test in browser (upload → generate → download)
- [ ] Verify GPX output in text editor (check for `<rtept>` and `<name>` tags)

### Production Environment (Server)

- [ ] SSH to server: `ssh mark@192.168.68.25 -p 8023`
- [ ] Navigate to runmap: `cd /home/mark/runmap`
- [ ] Activate virtualenv: `source venv/bin/activate`
- [ ] Install routegen: `cd python/routegen && pip install -e .`
- [ ] Verify GraphHopper: `curl http://localhost:8989/health`
- [ ] Test GraphHopper routing: `curl "http://localhost:8989/route?point=38.58,-121.49&point=38.57,-121.48&vehicle=foot"`
- [ ] Deploy API changes: Copy updated `api/app.py` to server
- [ ] Restart Flask: `sudo systemctl restart runmap-api` (or whatever service name)
- [ ] Build frontend: `cd web && npm run build`
- [ ] Deploy frontend: `rsync -avz web/build/ mark@server:/home/mark/runmap/web/build/`
- [ ] Test end-to-end with real GPX file
- [ ] Transfer to iPhone and test in WorkOutDoors
- [ ] Update documentation

---

## Estimated Effort

| Phase | Task | Time |
|-------|------|------|
| **1. Backend** | Install routegen + dependencies | 30 min |
| | Add Flask endpoint | 1.5-2 hrs |
| | Test with curl | 30 min |
| **2. Frontend** | Create TurnByTurnGenerator component | 2-3 hrs |
| | Integrate with ControlPanel | 30 min |
| | Test in browser | 30 min |
| **3. GraphHopper** | Verify health & test routing | 30 min |
| **4. Testing** | Backend tests | 1 hr |
| | Frontend tests | 1 hr |
| | WorkOutDoors validation | 30 min |
| **Documentation** | Update usage guide | 30 min |
| **Total** | | **8-10 hours** |

---

## Risk Assessment

### Low Risk Factors ✅

- **No database changes** - No schema modifications, no migrations
- **No impact on existing features** - Purely additive, isolated code
- **GraphHopper already deployed** - Stable, proven setup at https://map.chouinard.me
- **routegen code is mature** - Well-tested, production-ready
- **Admin-only feature** - Controlled rollout, single user
- **No breaking changes** - All existing APIs/features remain unchanged

### Potential Issues & Mitigations

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| **GraphHopper memory spike** | High CPU/RAM on large routes | Low | Add 60s timeout, rate limiting, monitor |
| **Dependency conflicts** | routegen deps conflict with Flask | Low | Test in virtualenv first, pin versions |
| **File size limits** | Large GPX files rejected | Low | Nginx `client_max_body_size` already 10M |
| **Routing timeout** | Long routes take >60s | Medium | Add configurable timeout, show progress |
| **Invalid GPX input** | Crashes endpoint | Low | Wrap in try/catch, validate before routing |
| **GraphHopper unavailable** | 503 errors | Low | Health check before routing, retry logic |

---

## Alternative: Minimal MVP (CLI-Only)

If full web integration is too much work initially, start with **API-only workflow**:

### Implementation (1 hour)

1. **Install routegen** on server
2. **Add Flask endpoint only** (no UI changes)
3. **Test with curl** for manual use

### Usage

```bash
# On development machine, prepare GPX
cat route.gpx

# Call API
curl -X POST http://localhost:5000/api/routes/generate-turn-by-turn \
  -H "X-API-Key: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"gpx_content\": \"$(cat route.gpx | tr -d '\n' | sed 's/"/\\"/g')\", \"route_name\": \"My Route\"}" \
  --output turn-by-turn.gpx

# Transfer to iPhone
# ... manually via AirDrop or Files app
```

### Benefits

- **Immediate value** - Turn-by-turn generation works now
- **Lower risk** - No frontend changes, easier rollback
- **Validation** - Prove concept before building UI
- **Flexibility** - Use in scripts, automation

### Drawbacks

- **Manual workflow** - No one-click UX
- **Requires command line** - Less convenient
- **No validation feedback** - Must check logs for errors

---

## Success Criteria

### MVP Success (Minimum Viable Product)

- [ ] Backend endpoint accepts GPX content and returns turn-by-turn GPX
- [ ] GraphHopper successfully routes through all test cases
- [ ] Generated GPX imports into WorkOutDoors without errors
- [ ] Turn prompts appear at intersections during navigation
- [ ] Documentation exists for manual API usage

### Full Success (Complete Integration)

- [ ] UI component allows drag-and-drop GPX upload
- [ ] One-click "Generate Turn-by-Turn" button works
- [ ] Loading states and error messages display correctly
- [ ] Downloaded GPX file has correct turn instructions
- [ ] WorkOutDoors navigation works end-to-end
- [ ] User documentation updated with screenshots
- [ ] Zero impact on existing RunMap features

---

## Future Enhancements (Post-MVP)

### Phase 2 Features (Optional)

1. **Route Preview**
   - Show turn-by-turn list before download
   - Display route map with turn markers
   - Show total distance, turn count, estimated time

2. **Batch Processing**
   - Upload multiple GPX files
   - Generate all turn-by-turn routes
   - Download as ZIP file

3. **Route Library**
   - Save generated routes to database
   - Browse/search previously generated routes
   - Share routes with others

4. **Customization**
   - Choose routing profile (foot, bike, car)
   - Adjust resample spacing (more/fewer waypoints)
   - Select turn instruction verbosity (brief/detailed)

5. **Integration with Unrun Segments**
   - "Generate Turn-by-Turn" button in UnrunSegmentPanel
   - Use sorted centroids as waypoints
   - Skip manual file upload step

6. **Multiple Routing Engines**
   - Add OSRM support (mentioned in routegen Phase 2)
   - Compare routes from different engines
   - Fallback if GraphHopper unavailable

7. **Advanced Validation**
   - Show deviation warnings before download
   - Suggest route improvements
   - Highlight problematic segments

---

## Questions & Decisions

### Resolved

- ✅ GraphHopper location: Already deployed at https://map.chouinard.me
- ✅ routegen source: Now in `python/routegen/` directory
- ✅ Priority: Medium (safe, non-disruptive)
- ✅ Scope: Any uploaded GPX file (not tied to activities/overlays)
- ✅ Access: Admin-only, single user

### Open Questions

- [ ] **Output format preference**: GPX or TCX? Or support both?
- [ ] **Resample spacing**: Default 30m OK? Or make configurable?
- [ ] **Timeout**: 60s sufficient for long routes?
- [ ] **Error handling**: Show validation warnings or auto-proceed?
- [ ] **Integration point**: ControlPanel or separate admin page?

---

## References

### Documentation
- `python/routegen/README.md` - routegen usage guide
- `python/routegen/NOTES.md` - Implementation notes
- `python/routegen/GRAPHHOPPER_SETUP.md` - GraphHopper setup
- `docs/USAGE_GUIDE.md` - RunMap usage guide

### Code
- `python/routegen/routegen/router/graphhopper.py` - GraphHopper client
- `python/routegen/routegen/io/writers.py` - GPX output writers
- `api/app.py` - Flask API endpoints
- `web/src/components/ControlPanel.tsx` - Control panel UI

### External
- [GraphHopper API Docs](https://docs.graphhopper.com/)
- [WorkOutDoors GPX Import](https://www.workoutdoors.net)
- [GPX Format Spec](https://www.topografix.com/gpx.asp)

---

**Status:** Ready for implementation
**Next Step:** Begin Phase 1 (Backend Setup) when ready
**Owner:** Mark Chouinard
**Last Updated:** 2025-10-29
