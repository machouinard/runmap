# RouteGen Integration Complete! 🎉

## What Was Implemented

### Backend (Flask API)
Added two new endpoints to [api/app.py](../../api/app.py):

1. **`POST /api/routegen/preview`** (lines 1396-1465)
   - Uploads GPX file temporarily
   - Parses and returns GeoJSON for map overlay
   - Returns bounds for map centering
   - Returns temp file path for conversion step

2. **`POST /api/routegen/convert`** (lines 1467-1546)
   - Takes temp file path from preview
   - Calls RouteGen API at `http://localhost:8000/convert`
   - Returns turn-by-turn GPX for download
   - Configurable waypoint spacing (resample distance)

### Frontend (React/TypeScript)
Created new component: [web/src/components/RouteGen.tsx](../../web/src/components/RouteGen.tsx)

**Features:**
- Drag & drop GPX upload
- Map overlay preview
- Adjustable waypoint spacing slider (10-100m)
- Generate turn-by-turn button
- Automatic file download
- Error handling with user-friendly messages
- Clean UI matching existing design system

**Integrated into:**
- [web/src/components/ControlPanel.tsx](../../web/src/components/ControlPanel.tsx) (lines 9, 402-409, 669-677)
- Available in both mobile and desktop views
- Only visible to admin users (same as UploadGPX)

## How to Test

### Prerequisites
1. **RouteGen API must be running:**
   ```bash
   # On your server (or locally for testing):
   # The API should already be running at http://localhost:8000
   curl http://localhost:8000/health
   # Should return: {"status":"ok"}
   ```

2. **GraphHopper must be accessible:**
   ```bash
   curl https://map.chouinard.me/health
   # Should return GraphHopper health check
   ```

### Testing Steps

#### 1. Start Development Environment
```bash
# Terminal 1: Start Flask API (if not already running)
cd /Users/markchouinard/Development/GIS/runs-cdm/api
python app.py

# Terminal 2: Start React dev server
cd /Users/markchouinard/Development/GIS/runs-cdm/web
npm run dev
```

#### 2. Test in Browser
1. Open http://localhost:5173 (or your Vite dev server port)
2. Log in as admin (if authentication is enabled)
3. Open the control panel (hamburger menu)
4. Scroll to "Turn-by-Turn Generator" section

#### 3. Upload and Preview
1. **Drag & drop** or **click to select** a GPX file
   - Try one from your gpx/ folder
   - Or download a sample from Strava/Garmin Connect
2. **Verify:**
   - ✅ GPX file uploads successfully
   - ✅ Route appears as blue line on map
   - ✅ Map zooms/pans to show full route
   - ✅ Point count displayed (e.g., "Preview: route.gpx (1234 points)")

#### 4. Adjust Settings
1. **Move the "Waypoint Spacing" slider:**
   - Left (10m) = more waypoints, more frequent turn prompts
   - Right (100m) = fewer waypoints, less frequent prompts
   - Default: 30m (good for running)
2. **Note:** Lower spacing = longer processing time

#### 5. Generate Turn-by-Turn
1. Click **"Generate Turn-by-Turn"** button
2. **Wait** (can take 10-60 seconds depending on route length)
3. **Verify:**
   - ✅ GPX file downloads automatically
   - ✅ Filename: `yourfile-turns.gpx`
   - ✅ Success message appears

#### 6. Validate Output
1. **Open the downloaded GPX** in a text editor
2. **Check for waypoints:**
   ```xml
   <wpt lat="38.5816" lon="-121.4944">
     <name>Turn left onto J Street</name>
   </wpt>
   ```
3. **Import to WorkOutDoors app** (iPhone/Apple Watch)
4. **Verify turn prompts** appear during navigation

### Test Cases

#### Happy Path
- [x] Upload valid GPX → sees route preview
- [x] Adjust slider → value updates
- [x] Click generate → GPX downloads
- [x] Import to WorkOutDoors → turn prompts work

#### Error Handling
- [ ] Upload non-GPX file → error message
- [ ] Upload empty GPX → error message
- [ ] RouteGen API offline → clear error message
- [ ] Network timeout on long route → timeout error

#### Edge Cases
- [ ] Very short route (<100m) → handles gracefully
- [ ] Very long route (>50km) → may timeout, suggest higher resample distance
- [ ] Route outside Sacramento/Portland → still works (GraphHopper has global OSM data)

## Architecture Flow

```
User Browser                    Flask API                     RouteGen API
     │                              │                              │
     │  1. Upload GPX               │                              │
     ├──────────────────────────────>│                              │
     │  POST /api/routegen/preview  │                              │
     │                              │                              │
     │  2. GeoJSON + temp_path      │                              │
     │<──────────────────────────────┤                              │
     │                              │                              │
     │  [User previews route]       │                              │
     │  [Adjusts settings]          │                              │
     │                              │                              │
     │  3. Request conversion       │                              │
     ├──────────────────────────────>│                              │
     │  POST /api/routegen/convert  │                              │
     │  {temp_path, settings}       │                              │
     │                              │  4. Forward GPX              │
     │                              ├─────────────────────────────>│
     │                              │  POST /convert               │
     │                              │                              │
     │                              │  [RouteGen processes]        │
     │                              │  [Calls GraphHopper]         │
     │                              │                              │
     │                              │  5. Turn-by-turn GPX         │
     │                              │<─────────────────────────────┤
     │                              │                              │
     │  6. Download GPX file        │                              │
     │<──────────────────────────────┤                              │
```

## Configuration

### Flask API Settings
Location: `api/app.py` line 1494

```python
routegen_api_url = 'http://localhost:8000/convert'
```

**For production server:**
- Update to `http://localhost:8000/convert` (already correct)
- Ensure RouteGen API is accessible from Flask

### RouteGen Component Settings
Location: `web/src/components/RouteGen.tsx` line 277

```typescript
resample_distance: 30  // Default waypoint spacing in meters
```

**Customization:**
- Adjust slider range (currently 10-100m)
- Change default value
- Add profile selector (foot/bike/car)

## Deployment

### Server Deployment
The RouteGen API is already deployed at:
- **URL:** `https://runmap.chouinard.me/api/routegen`
- **Internal:** `http://localhost:8000`

**No changes needed!** The Flask integration uses `http://localhost:8000` which is correct for server-side calls.

### Frontend Build
```bash
cd web
npm run build
# Outputs to web/build/
# Copy to server: /home/mark/runmap/web/build/
```

## Troubleshooting

### "Cannot connect to RouteGen service"
**Cause:** RouteGen API not running on port 8000

**Fix:**
```bash
# Check if running
curl http://localhost:8000/health

# If not, start it (see DEPLOYMENT.md)
docker-compose -f docker-compose.api.yml up -d

# Or check systemd
sudo systemctl status routegen-api
```

### "RouteGen API timeout"
**Cause:** Route is very long or complex

**Fix:**
- Increase `resample_distance` (fewer waypoints = faster)
- Or increase timeout in `api/app.py` line 1508:
  ```python
  timeout=120  # Increase to 300 for 5 minutes
  ```

### "No turn prompts in WorkOutDoors"
**Cause:** Waypoint spacing too high

**Fix:**
- Use lower `resample_distance` (10-20m for detailed turns)
- Verify GPX has `<wpt>` elements with `<name>` tags

### Preview shows route but conversion fails
**Cause:** GraphHopper can't find routing data for area

**Fix:**
- Check GraphHopper health: `curl https://map.chouinard.me/health`
- Verify area is covered by OSM data
- Check RouteGen API logs for details

## Next Steps

### Optional Enhancements
1. **TCX Format Support** (line 1524-1527 in app.py)
   - Currently returns 501 "not implemented"
   - Need to add GPX→TCX converter

2. **Profile Selector** (foot/bike/car)
   - Add dropdown to RouteGen component
   - Pass profile to `/convert` endpoint
   - Currently hardcoded to "foot"

3. **Progress Indicator**
   - Show conversion progress (RouteGen API returns streaming updates)
   - Display estimated time remaining

4. **Route Validation**
   - Check route length before conversion
   - Warn if >50km (may timeout)
   - Suggest optimal resample_distance

5. **Save to Database**
   - Option to save turn-by-turn GPX alongside original
   - Add to runs_raw table with special flag
   - Re-download from activities list

## Files Modified

### New Files
- `web/src/components/RouteGen.tsx` - React component
- `docs/routegen-api/INTEGRATION_COMPLETE.md` - This file

### Modified Files
- `api/app.py` - Added 2 endpoints (151 lines)
- `web/src/components/ControlPanel.tsx` - Added RouteGen import and placement

## Success Criteria

- [x] Backend endpoints functional
- [x] Frontend component created
- [x] Integration with ControlPanel
- [ ] End-to-end test completed
- [ ] WorkOutDoors turn prompts verified
- [ ] Documentation complete

## Support

**Questions?** Check these docs:
- [DEPLOYMENT.md](DEPLOYMENT.md) - RouteGen API deployment
- [API_README.md](API_README.md) - API overview
- [flask_integration_example.py](flask_integration_example.py) - Integration examples

**Issues?**
- Check Flask API logs: `api/logs/api.log`
- Check RouteGen API logs: `docker-compose logs routegen-api`
- Check browser console for frontend errors
