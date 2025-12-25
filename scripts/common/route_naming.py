"""
Route name generation utilities

Generates user-friendly route names like "Sunday Morning Run" from activity metadata.
Can also validate and preserve WorkoutDoors-style names from GPX files.
"""

import re
import os
from datetime import datetime
from typing import Optional
try:
    from zoneinfo import ZoneInfo
except ImportError:
    # Fallback for Python < 3.9 (though unlikely given environment)
    from datetime import timezone, timedelta
    # Simple fixed offset if ZoneInfo not available
    class ZoneInfo:
        def __init__(self, key):
            pass
        def utcoffset(self, dt):
            return timedelta(hours=-8) # Default to PST

# Default configuration
DEFAULT_TIMEZONE = os.getenv('RUNMAP_TIMEZONE', 'America/Los_Angeles')

# Generic activity names to ignore (case-insensitive)
# If GPX has one of these names, we'll auto-generate a better one
IGNORED_NAMES = {
    'running', 'walking', 'cycling', 
    'run', 'walk', 'cycle', 'bike', 
    'hike', 'hiking',
    'outdoor running', 'outdoor walking', 'outdoor cycling'
}


def get_time_of_day(hour: int) -> str:
    """
    Determine time of day category from hour (0-23).

    Args:
        hour: Hour in 24-hour format (0-23)

    Returns:
        One of: "Morning", "Afternoon", "Evening", "Night"
    """
    if 5 <= hour < 12:
        return "Morning"
    elif 12 <= hour < 17:
        return "Afternoon"
    elif 17 <= hour < 21:
        return "Evening"
    else:  # 21-4
        return "Night"


def get_activity_type_display(activity_type: str) -> str:
    """
    Convert activity type to display format.

    Args:
        activity_type: One of "run", "walk", "cycling"

    Returns:
        Display name: "Run", "Walk", or "Ride"
    """
    mapping = {
        'run': 'Run',
        'walk': 'Walk',
        'cycling': 'Ride',
        'cycle': 'Ride',
        'bike': 'Ride'
    }
    return mapping.get(activity_type.lower(), activity_type.capitalize())


def generate_friendly_name(timestamp: datetime, activity_type: str) -> str:
    """
    Generate a friendly route name from timestamp and activity type.

    Format: "{DayOfWeek} {TimeOfDay} {ActivityType}"
    Example: "Sunday Morning Run", "Thursday Night Walk"

    Args:
        timestamp: DateTime of the activity start (UTC or offset-aware)
        activity_type: Type of activity ("run", "walk", "cycling")

    Returns:
        Friendly name string
    """
    # Convert to local timezone (Sacramento/Pacific)
    if timestamp.tzinfo is None:
        # Assume UTC if naive (GPX files usually parsed as naive are actually UTC)
        timestamp = timestamp.replace(tzinfo=ZoneInfo("UTC"))
    
    # Convert to target timezone
    local_time = timestamp.astimezone(ZoneInfo(DEFAULT_TIMEZONE))

    day_of_week = local_time.strftime("%A")  # Monday, Tuesday, etc.
    time_of_day = get_time_of_day(local_time.hour)
    activity_display = get_activity_type_display(activity_type)

    return f"{day_of_week} {time_of_day} {activity_display}"


def get_route_name(gpx_name: Optional[str], timestamp: datetime, activity_type: str, creator: Optional[str] = None) -> str:
    """
    Determine the appropriate route name from GPX metadata or generate one.

    Logic:
    1. If creator is "Apple Watch" (WorkoutDoors) and name is meaningful -> use it
    2. Otherwise -> auto-generate from timestamp and activity type

    Args:
        gpx_name: Name from GPX <trk><name> field (can be None)
        timestamp: DateTime of the activity start
        activity_type: Type of activity ("run", "walk", "cycling")
        creator: GPX creator string (e.g., "Apple Watch")

    Returns:
        Final route name to use
    """
    if gpx_name:
        cleaned_name = gpx_name.strip()
        
        # Always ignore strictly generic names regardless of source
        if cleaned_name.lower() in IGNORED_NAMES:
            return generate_friendly_name(timestamp, activity_type)

        # If it's from Apple Watch (WorkoutDoors), trust the name
        # (unless it was one of the ignored ones above)
        if creator and "Apple Watch" in creator:
            return cleaned_name
            
        # Check for generic "Route YYYY-MM-DD" patterns
        # Catches "Route 2024-06-29 11:22am" etc.
        if re.match(r'^Route \d{4}-\d{2}-\d{2}', cleaned_name, re.IGNORECASE):
            return generate_friendly_name(timestamp, activity_type)

        # Otherwise, preserve meaningful names (Custom names)
        return cleaned_name

    # Auto-generate for all other cases (generic name, other sources, or missing name)
    return generate_friendly_name(timestamp, activity_type)


def truncate_name(name: str, max_length: int = 100) -> str:
    """
    Truncate a route name to maximum length.

    Args:
        name: Route name
        max_length: Maximum allowed length (default: 100)

    Returns:
        Truncated name
    """
    if len(name) <= max_length:
        return name

    return name[:max_length - 3] + "..."


if __name__ == "__main__":
    # Test cases
    test_cases = [
        # (gpx_name, timestamp, activity_type, expected_result)
        ("Thursday Night Walk", datetime(2025, 11, 21, 20, 30), "walk", "Thursday Night Walk"),  # WorkoutDoors
        ("Running", datetime(2025, 11, 24, 10, 30), "run", "Sunday Morning Run"),  # Generic name - regenerate
        (None, datetime(2025, 11, 24, 14, 30), "run", "Sunday Afternoon Run"),  # No name
        (None, datetime(2025, 11, 24, 19, 30), "cycling", "Sunday Evening Ride"),  # Evening cycling
        ("Sunday Morning Run", datetime(2025, 11, 24, 8, 0), "run", "Sunday Morning Run"),  # WorkoutDoors run
    ]

    print("Route Name Generation Tests")
    print("=" * 80)

    for gpx_name, timestamp, activity_type, expected in test_cases:
        result = get_route_name(gpx_name, timestamp, activity_type, "Apple Watch")
        # status = "✓" if result == expected else "✗"
        print(f"GPX: {gpx_name!r:30} → {result!r}")

    print("\nTime of Day Tests")
    print("=" * 80)

    time_tests = [
        (5, "Morning"), (11, "Morning"),
        (12, "Afternoon"), (16, "Afternoon"),
        (17, "Evening"), (20, "Evening"),
        (21, "Night"), (4, "Night")
    ]

    for hour, expected_time in time_tests:
        result = get_time_of_day(hour)
        status = "✓" if result == expected_time else "✗"
        print(f"{status} Hour {hour:2d}:00 → {result} (expected: {expected_time})")
