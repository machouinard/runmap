# Activity Dashboard Implementation Plan

**Status:** API complete, Frontend in progress
**Purpose:** Unified dashboard to view and manage all activities (runs + walks + cycling)

## Completed

### 1. Tile Export Updates ✅
**File:** `scripts/export_tiles_blocks.sh`

**Changes:**
- Exports ALL runs (all locations)
- Exports walks WHERE location = 'other' only
- Exports cycling WHERE location = 'other' only
- Creates separate PMTiles: `runs.pmtiles`, `walks.pmtiles`, `cycling.pmtiles`

### 2. API Endpoints ✅
**File:** `api/app.py`

**New endpoints:**
```python
GET  /api/activities
     # Returns all activities from all tables unified
     # Fields: id, filename, start_time, total_distance_m, duration_seconds,
     #         location, activity_type, processing_status

POST /api/activities/reclassify
     # Body: {id, current_type, new_type}
     # Moves activity between runs_raw/walks_raw/cycling_raw tables
     # Handles cleanup of processing data if moving FROM runs

DELETE /api/activities/delete/<activity_id>?type=run|walk|cycling
       # Deletes activity from specified table
       # Cascades handle dependent data
```

## TODO: Frontend Dashboard

### 3. Activity Dashboard Component
**File:** `web/src/components/ActivityDashboard.tsx` (CREATE NEW)

**Features needed:**

#### A. Data Fetching
```typescript
interface Activity {
  id: string
  filename: string
  start_time: string
  total_distance_m: number
  duration_seconds: number
  location: string
  activity_type: 'run' | 'walk' | 'cycling'
  processing_status?: 'pending' | 'processing' | 'processed' | 'failed'
  processing_completed_at?: string
}

// Fetch all activities
const [activities, setActivities] = useState<Activity[]>([])
useEffect(() => {
  fetch('/api/activities').then(r => r.json()).then(data => {
    setActivities(data.activities)
  })
}, [])
```

#### B. Table Display
- **Columns:**
  - Date/Time (formatted)
  - Filename
  - Location (badge with color: Sacramento=blue, Portland=green, Other=gray)
  - Type (badge: Run=red, Walk=blue, Cycling=green)
  - Distance (miles, converted from meters)
  - Duration (formatted HH:MM:SS)
  - Speed (calculated: distance/duration, show m/s or km/h)
  - Status (for runs only: badge showing processing_status)
  - Actions (dropdown menu)

- **Sorting:** Clickable column headers
- **Pagination:** Show 50 per page

#### C. Filtering
```typescript
const [filters, setFilters] = useState({
  location: 'all',      // all | sacramento | portland | other
  type: 'all',          // all | run | walk | cycling
  status: 'all',        // all | processed | failed | pending (runs only)
  dateFrom: null,
  dateTo: null,
  search: ''            // search in filename
})
```

Filter UI:
- Location dropdown
- Type dropdown
- Status dropdown (for runs)
- Date range picker
- Search box

#### D. Actions Menu (per row)
- **View Details** - Expand row to show:
  - Full path to GPX file
  - Upload timestamp
  - Workout hash
  - Processing error (if failed)
  - Calculated average speed

- **Reclassify** - Dropdown to select new type
  - Shows: "Change to: [Run] [Walk] [Cycling]"
  - Confirmation dialog: "Move this activity from {current} to {new}?"
  - Calls `/api/activities/reclassify`
  - Refreshes table on success

- **Retry Processing** (runs only, if failed)
  - Calls `/api/processing-queue/retry/<id>`
  - Shows success/error message

- **Delete** - With confirmation
  - Dialog: "Delete {filename}? This cannot be undone."
  - Calls `/api/activities/delete/<id>?type={type}`
  - Removes from table on success

#### E. Bulk Actions
- Checkbox column to select multiple
- "Selected (N)" counter
- Bulk actions:
  - Reclassify selected
  - Delete selected
  - Export selected to CSV

#### F. Summary Stats (top of page)
Cards showing:
- **Total Activities:** Count all
- **Runs:** Count, total miles
- **Walks:** Count, total miles
- **Cycling:** Count, total miles
- **By Location:**
  - Sacramento: X runs, Y miles
  - Portland: X runs, Y miles
  - Other: X runs + Y walks + Z cycling

#### G. Export to CSV
Button: "Export All to CSV"
- Generates CSV with all visible (filtered) activities
- Columns: date, filename, location, type, distance_miles, duration_sec, avg_speed_mph, status
- Downloads as `activities_export_YYYYMMDD.csv`

### 4. Routing
**File:** `web/src/App.tsx`

Update hash routing:
```typescript
const [currentView, setCurrentView] = useState<'map' | 'admin' | 'activities'>('map')

useEffect(() => {
  const hash = window.location.hash
  if (hash === '#admin') setCurrentView('admin')
  else if (hash === '#activities') setCurrentView('activities')
  else setCurrentView('map')
}, [])

// Render based on currentView
if (currentView === 'activities') {
  return <ActivityDashboard />
}
```

### 5. Navigation
**File:** `web/src/components/ControlPanel.tsx`

Add button after "Admin / Processing Queue":
```tsx
<button
  onClick={() => window.location.hash = 'activities'}
  className="w-full px-4 py-2 bg-blue-600 hover:bg-blue-700..."
>
  View All Activities
</button>
```

### 6. Map Layer Updates
**File:** `web/src/components/Map.tsx`

Add walks and cycling layers:

```typescript
// Add to sources
walks: {
  type: 'vector' as const,
  url: 'pmtiles:///tiles/walks.pmtiles',
},
cycling: {
  type: 'vector' as const,
  url: 'pmtiles:///tiles/cycling.pmtiles',
},

// Add layers (after runs layer)
<Source id="walks" type="vector" url="pmtiles:///tiles/walks.pmtiles">
  <Layer
    id="walks"
    type="line"
    source-layer="walks"
    paint={{
      'line-color': '#3b82f6', // Blue
      'line-width': 2,
      'line-opacity': 0.8
    }}
  />
</Source>

<Source id="cycling" type="vector" url="pmtiles:///tiles/cycling.pmtiles">
  <Layer
    id="cycling"
    type="line"
    source-layer="cycling"
    paint={{
      'line-color': '#10b981', // Green
      'line-width': 2,
      'line-opacity': 0.8
    }}
  />
</Source>
```

## Display Rules Summary

**Map displays:**
- **Runs:** All locations (red lines)
- **Walks:** Only 'other' location (blue lines)
- **Cycling:** Only 'other' location (green lines)

**Dashboard displays:**
- **ALL activities from ALL locations**

**Coverage calculation:**
- **Only Sacramento runs** contribute to coverage
- **Only Portland runs** will contribute (when AOI expands)
- Walks and cycling NEVER contribute to coverage

## Testing Checklist

- [ ] Run `bash scripts/export_tiles_blocks.sh` - verify walks.pmtiles and cycling.pmtiles created
- [ ] Deploy tiles to server: `bash scripts/deploy.sh`
- [ ] Test API endpoints:
  - [ ] `GET /api/activities` returns all 628 activities
  - [ ] `POST /api/activities/reclassify` moves activity between tables
  - [ ] `DELETE /api/activities/delete/<id>?type=run` deletes activity
- [ ] Test dashboard:
  - [ ] Table shows all activities
  - [ ] Filters work correctly
  - [ ] Reclassify moves Portland "run" to "walk"
  - [ ] Delete removes activity
  - [ ] Export CSV downloads file
- [ ] Test map:
  - [ ] All runs visible (red lines)
  - [ ] Walks visible only in "other" locations (blue lines)
  - [ ] Cycling visible only in "other" locations (green lines)

## Files Modified Summary

1. ✅ `scripts/export_tiles_blocks.sh` - Export walks/cycling from 'other'
2. ✅ `api/app.py` - Add activity endpoints
3. ⏳ `web/src/components/ActivityDashboard.tsx` - NEW component
4. ⏳ `web/src/App.tsx` - Add routing for #activities
5. ⏳ `web/src/components/ControlPanel.tsx` - Add navigation button
6. ⏳ `web/src/components/Map.tsx` - Add walks/cycling layers

## Next Steps

1. Build ActivityDashboard component
2. Test locally with `npm run dev`
3. Generate tiles: `bash scripts/export_tiles_blocks.sh`
4. Deploy: `bash scripts/deploy.sh`
5. Test on production at `https://runmap.chouinard.me/#activities`
