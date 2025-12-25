#!/bin/bash
# Simple test of GraphHopper routing with manual coordinates

# Configuration
GRAPHHOPPER_URL="https://map.chouinard.me"

# Paste the coordinates string from the UI here (space-separated lat,lon pairs)
# Example: "38.5819,-121.4944 38.5825,-121.4950 38.5831,-121.4945"
COORDS_STRING="38.56688131140822,-121.48118226617916 38.5671589000018,-121.48106210001127 38.56758659016163,-121.48284868398159"

# Convert space-separated string to array
IFS=' ' read -ra WAYPOINTS <<< "$COORDS_STRING"

echo "Testing GraphHopper routing with ${#WAYPOINTS[@]} waypoints..."
echo ""

# Build URL with point parameters
URL="${GRAPHHOPPER_URL}/route?profile=foot&points_encoded=false&instructions=true&calc_points=true"

for waypoint in "${WAYPOINTS[@]}"; do
    # Split into lat,lon
    IFS=',' read -r lat lon <<< "$waypoint"
    URL="${URL}&point=${lat},${lon}"
    echo "  - Waypoint: ${lat}, ${lon}"
done

echo ""
echo "Calling GraphHopper API..."
echo ""

# Call GraphHopper
response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" "$URL")

# Extract HTTP status
http_status=$(echo "$response" | grep "HTTP_STATUS" | cut -d':' -f2)
body=$(echo "$response" | sed '/HTTP_STATUS/d')

if [ "$http_status" != "200" ]; then
    echo "Error: HTTP $http_status"
    echo "$body"
    exit 1
fi

# Parse response and show summary
echo "$body" | python3 -c "
import sys
import json

data = json.load(sys.stdin)

if 'paths' not in data or len(data['paths']) == 0:
    print('No route found!')
    if 'message' in data:
        print(f'Error: {data[\"message\"]}')
    sys.exit(1)

path = data['paths'][0]
distance_km = path['distance'] / 1000.0
distance_mi = distance_km * 0.621371
time_min = path['time'] / 60000.0

print('=' * 60)
print('ROUTE SUMMARY')
print('=' * 60)
print(f'Distance: {distance_km:.2f} km ({distance_mi:.2f} miles)')
print(f'Time: {time_min:.1f} minutes')
print(f'Number of points: {len(path[\"points\"][\"coordinates\"])}')
print()

if 'instructions' in path:
    print('Turn-by-turn instructions:')
    for i, inst in enumerate(path['instructions'][:10], 1):
        text = inst.get('text', '')
        dist = inst.get('distance', 0)
        print(f'  {i}. {text} ({dist:.0f}m)')

    if len(path['instructions']) > 10:
        print(f'  ... and {len(path[\"instructions\"]) - 10} more instructions')
"

echo ""
echo "Full response saved to: /tmp/graphhopper_test.json"
echo "$body" | python3 -m json.tool > /tmp/graphhopper_test.json
