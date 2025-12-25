# Google Analytics Tracking

This document describes all the custom events being tracked in the RunMap application.

## Setup

Google Analytics is configured in `/web/index.html` with measurement ID: `G-0CS1JLH9BD`

## Utility Functions

All tracking functions are defined in `/web/src/lib/analytics.ts`:

- `trackEvent(eventName, params)` - Generic event tracking
- `trackPageView(path, title)` - Page view tracking
- `trackOverlayView(overlayName, metadata)` - Overlay/modal views
- `trackDashboardAction(action, activityType, metadata)` - Activity dashboard interactions
- `trackMapAction(action, metadata)` - Map interactions
- `trackRouteGeneration(method, metadata)` - Route generation events

## Tracked Events

### Page Views

**Event:** `page_view`

Tracks navigation between main views:
- `/` - Map View (default)
- `/activities` - Activity Dashboard
- `/admin` - Admin Panel

### Map Interactions

**Event:** `map_action`

Tracks user interactions with the map:

- **Action:** `jump_location`
  - **Metadata:** `{ location: 'sacramento' | 'portland' }`
  - Triggered when user jumps to a city location

- **Action:** `start_polygon_selection`
  - Triggered when user starts drawing a polygon to select unrun blocks

- **Action:** `complete_polygon_selection`
  - **Metadata:** `{ block_count: number, area_km2: number }`
  - Triggered when polygon selection completes and blocks are extracted

### Route Generation

**Event:** `generate_route`

Tracks route generation activities:

- **Method:** `valhalla`
  - **Metadata:**
    - `distance_km` - Total route distance
    - `time_seconds` - Estimated route duration
    - `blocks_covered` - Number of blocks covered by route
    - `blocks_total` - Total blocks in selection
    - `coverage_pct` - Percentage of blocks covered
  - Triggered when Valhalla route is successfully generated

- **Method:** `gpx_upload`
  - **Metadata:**
    - `route_name` - Name of the uploaded GPX route
    - `point_count` - Number of GPS points in the route
  - Triggered when user uploads a GPX file for route overlay

### Activity Overlay Views

**Event:** `view_overlay`

Tracks when users view activity overlays on the map:

- **Overlay Name:** `activity_overlay`
  - **Metadata:**
    - `activity_id` - UUID of the activity
    - `activity_type` - 'run' | 'walk' | 'cycling'
    - `location` - 'sacramento' | 'portland' | 'other'
    - `distance_m` - Distance in meters
  - Triggered when user clicks "View on Map" from the Activity Dashboard

### Activity Dashboard Actions

**Event:** `dashboard_action`

Tracks user actions in the Activity Dashboard:

- **Action:** `delete`
  - **Activity Type:** 'run' | 'walk' | 'cycling'
  - **Metadata:**
    - `location` - Activity location
    - `distance_m` - Total distance in meters
  - Triggered when admin deletes a single activity

- **Action:** `bulk_delete`
  - **Metadata:**
    - `count` - Number of activities deleted
  - Triggered when admin bulk deletes multiple activities

- **Action:** `reclassify`
  - **Activity Type:** Original type before reclassification
  - **Metadata:**
    - `old_type` - Original activity type
    - `new_type` - New activity type after reclassification
    - `location` - Activity location
  - Triggered when admin reclassifies an activity (e.g., run → walk)

- **Action:** `retry_processing`
  - **Activity Type:** 'run' | 'walk' | 'cycling'
  - **Metadata:**
    - `location` - Activity location
  - Triggered when admin retries processing a failed activity

## Viewing Analytics

1. Go to [Google Analytics](https://analytics.google.com/)
2. Select your RunMap property
3. Navigate to **Reports** → **Engagement** → **Events**
4. You'll see all custom events:
   - `page_view`
   - `map_action`
   - `generate_route`
   - `view_overlay`
   - `dashboard_action`

## Custom Reports

You can create custom reports in GA4 to analyze:

1. **Most Popular Map Actions**
   - Event name: `map_action`
   - Breakdown by: `action` parameter

2. **Route Generation Success Rate**
   - Event name: `generate_route`
   - Breakdown by: `method` parameter

3. **Activity Dashboard Usage**
   - Event name: `dashboard_action`
   - Breakdown by: `action` and `activity_type`

4. **Activity Overlay Views**
   - Event name: `view_overlay`
   - Breakdown by: `activity_type` and `location`

## Console Logging

All events are logged to the browser console in development for debugging:
```
[GA Event] map_action { action: 'jump_location', location: 'sacramento' }
[GA PageView] /activities Activity Dashboard
```

## Privacy

No personally identifiable information (PII) is tracked. All events contain only:
- Interaction types (clicks, views)
- Technical metadata (distances, counts, locations)
- No user names, emails, or IP addresses beyond GA's automatic collection
