#!/bin/bash
# Generate a GraphHopper map URL from coordinates

# Configuration
GRAPHHOPPER_MAP_URL="https://map.chouinard.me/maps/"

# Paste the coordinates string from the UI here (space-separated lat,lon pairs)
COORDS_STRING="38.56688131140822,-121.48118226617916 38.5671589000018,-121.48106210001127 38.56758659016163,-121.48284868398159"

# Profile to use (foot, run, bike, car)
PROFILE="foot"

# Convert space-separated string to array
IFS=' ' read -ra WAYPOINTS <<< "$COORDS_STRING"

# Build URL with point parameters
URL="${GRAPHHOPPER_MAP_URL}?"

for waypoint in "${WAYPOINTS[@]}"; do
    URL="${URL}point=${waypoint}&"
done

URL="${URL}profile=${PROFILE}"

echo "GraphHopper Map URL (${#WAYPOINTS[@]} waypoints):"
echo ""
echo "$URL"
echo ""
echo "Copy this URL and paste it into your browser to see the route."
