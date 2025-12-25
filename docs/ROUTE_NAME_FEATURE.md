# Route Name Feature - Overview and Rationale

## Summary

We've added user-friendly route names to all activities in the RunMap application. Instead of seeing technical filenames like `2024-11-24_1430_run_3.2km.gpx`, users now see descriptive names like "Sunday Afternoon Run" or "Thursday Night Walk".

## Problem Statement

### Before

-   Activity tables displayed GPX filenames: `2024-11-24_1430_run_3.2km.gpx`
-   Mobile activity cards showed only date/time with no activity identifier
-   Map overlays showed generic labels like "Run Route"
-   Difficult to distinguish between activities at a glance
-   No meaningful names when browsing activity history

### After

-   Activity tables display friendly names: "Sunday Afternoon Run"
-   Mobile cards have prominent titles with route names
-   Map overlays show the specific activity name
-   Easy to scan and identify activities
-   Consistent naming across all activities

## Naming Strategy

### Goal

Create consistent, descriptive names that tell you **when** and **what type** of activity it was at a glance.

### Format

```
{DayOfWeek} {TimeOfDay} {ActivityType}
```

**Examples:**

-   "Monday Morning Run"
-   "Thursday Night Walk"
-   "Saturday Afternoon Ride"

### Time-of-Day Classification

-   **Morning:** 5:00 AM - 11:59 AM
-   **Afternoon:** 12:00 PM - 4:59 PM
-   **Evening:** 5:00 PM - 8:59 PM
-   **Night:** 9:00 PM - 4:59 AM

### Activity Type Display

-   Runs → "Run"
-   Walks → "Walk"
-   Cycling → "Ride"

## Handling Different GPX Sources

The system intelligently handles GPX files from different apps:

### WorkoutDoors (Apple Watch)

-   **Provides:** "Thursday Night Walk", "Sunday Morning Run"
-   **Action:** Preserve the name as-is (already matches our pattern)
-   **Reason:** WorkoutDoors uses the exact naming convention we want

### WorkoutGPX (iPhone export)

-   **Provides:** "Running", "Walking" (generic names)
-   **Action:** Auto-generate from timestamp
-   **Reason:** Generic names aren't descriptive enough

### GPX Export Apps (iOS Shortcuts)

-   **Provides:** No name field in GPX file
-   **Action:** Auto-generate from timestamp
-   **Reason:** No name to extract

### Health App Exports

-   **Provides:** Varies by export method
-   **Action:** Use name only if it matches our pattern, otherwise auto-generate
-   **Reason:** Ensures consistency across all sources

## Technical Implementation

### Pattern Recognition

We use regex to identify WorkoutDoors-style names:

```regex
^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) (Morning|Afternoon|Evening|Night) (Run|Walk|Ride|Cycling)$
```

**Examples:**

-   ✅ "Thursday Night Walk" → Matches (keep it)
-   ❌ "Running" → Doesn't match (auto-generate)
-   ❌ "Evening jog around the park" → Doesn't match (auto-generate)

### Name Generation Logic

```python
def get_route_name(gpx_name, timestamp, activity_type):
    """
    1. If GPX has a name AND it matches WorkoutDoors pattern → use it
    2. Otherwise → auto-generate from timestamp + activity_type
    """
    if gpx_name and matches_workoutdoors_pattern(gpx_name):
        return gpx_name  # Preserve WorkoutDoors naming
    else:
        return generate_friendly_name(timestamp, activity_type)
```

### Storage

-   Added `route_name` column (TEXT, nullable) to all three activity tables:
    -   `runmap.runs_raw`
    -   `runmap.walks_raw`
    -   `runmap.cycling_raw`
-   Names are generated at upload time and stored permanently
-   Existing activities can be backfilled using the migration script

## Benefits

### User Experience

1. **Quick Scanning:** See what the activity was without reading filenames
2. **Mobile Friendly:** Activity cards now have clear titles
3. **Context at a Glance:** Day + time + type tells the story
4. **Consistent Naming:** All activities follow the same pattern

### Technical Benefits

1. **Database-Stored:** No runtime calculation needed
2. **Source Flexibility:** Works with any GPX export method
3. **Backward Compatible:** Existing filenames still available
4. **Idempotent:** Same activity always gets same name

### Examples in Context

**Activity Table (Desktop):**

```
Date         Route Name              Location    Type    Distance
11/24/2024   Sunday Afternoon Run    Sacramento  Run     3.2 mi
11/21/2024   Thursday Night Walk     Sacramento  Walk    1.6 mi
11/20/2024   Wednesday Morning Run   Portland    Run     5.1 mi
```

**Activity Card (Mobile):**

```
┌─────────────────────────────────┐
│ Sunday Afternoon Run            │
│ 11/24/2024                      │
│ 2:30 PM                         │
│                                 │
│ Sacramento · Run                │
│ Distance: 3.2 mi | Time: 28:45  │
└─────────────────────────────────┘
```

**Map Overlay:**

```
┌──────────────────────────┐
│ 📍 Sunday Afternoon Run  │
│ Nov 24, 2024 2:30 PM    │
│ 3.2 miles | 28:45       │
│ Sacramento              │
└──────────────────────────┘
```

## Why This Approach?

### Alternative Considered: Always Use GPX Names

**Rejected because:**

-   Inconsistent formatting across apps
-   Generic names like "Running" aren't helpful
-   Some apps don't provide names at all
-   Different terminology (e.g., "Bike" vs "Ride")

### Alternative Considered: Always Auto-Generate

**Rejected because:**

-   WorkoutDoors already provides perfect names
-   Users who carefully name their workouts expect those names preserved
-   Loses information from native recording apps

### Chosen Approach: Hybrid with Pattern Matching

**Benefits:**

-   ✅ Preserves meaningful names from WorkoutDoors
-   ✅ Standardizes generic/missing names
-   ✅ Consistent experience across all activities
-   ✅ Works with any GPX source
-   ✅ No manual user intervention required

## Data Migration

### New Uploads

-   Automatically get route names at upload time
-   No user action required

### Existing Activities

-   Initially show filenames (graceful fallback)
-   Run backfill script to populate route names
-   One-time operation: `python3 scripts/backfill_route_names.py`
-   Script reads GPX files and applies same logic as uploads

## Edge Cases Handled

1. **No GPX File:** Generate from database timestamp + activity_type
2. **Corrupted GPX:** Generate from database timestamp + activity_type
3. **NULL start_time:** Use uploaded_at timestamp as fallback
4. **Very Long Names:** Truncated to 100 characters (with "...")
5. **Duplicate Detection:** Route names don't affect workout_hash (deduplication still works)

## Compatibility

### Backward Compatible

-   Existing code continues to work
-   Filename still available in database and on hover
-   Frontend gracefully falls back to filename if route_name is NULL
-   No breaking changes to API contracts

### Forward Compatible

-   Easy to add user-editable names in the future
-   Can add custom name field without breaking auto-generation
-   Pattern matching can be extended for other apps

## Testing Recommendations

Before deploying to production:

1. **Upload Tests:**

    - ✅ WorkoutDoors GPX → preserves name
    - ✅ iOS Shortcut GPX → generates name
    - ✅ WorkoutGPX with "Running" → generates name

2. **Display Tests:**

    - ✅ Desktop table shows route names
    - ✅ Mobile cards show route names
    - ✅ Map overlay shows route name
    - ✅ Tooltip shows filename

3. **Migration Tests:**

    - ✅ Backfill script dry-run
    - ✅ Backfill script with --limit 5
    - ✅ Full backfill
    - ✅ Verify all activities have names

4. **Edge Cases:**
    - ✅ Activity with NULL start_time
    - ✅ GPX file not found
    - ✅ Corrupted GPX file

## Performance Impact

-   **Negligible:** Name generation happens once at upload time (~0.001s)
-   **Database:** Small TEXT column, minimal storage overhead
-   **API:** No additional queries needed (route_name included in existing SELECT)
-   **Frontend:** No runtime processing, just display

## Future Enhancements

Possible improvements for later:

1. **User-Editable Names:** Allow manual override of auto-generated names
2. **Name Templates:** Let users customize naming pattern
3. **Emoji Support:** "🏃 Sunday Morning Run"
4. **Route Nicknames:** "My usual loop" for frequently run routes
5. **Activity Tagging:** "Tempo run", "Recovery walk", etc.

## Conclusion

This feature significantly improves the user experience by replacing technical filenames with human-readable activity names. The hybrid approach (preserve WorkoutDoors names, auto-generate others) ensures consistency while respecting meaningful names from native recording apps.

The implementation is backward compatible, performant, and handles all edge cases gracefully. Users benefit immediately with no manual intervention required.
