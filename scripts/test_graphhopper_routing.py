#!/usr/bin/env python3
"""
Test script to extract unrun segment centroids and send them to GraphHopper for routing.

Usage:
    python3 scripts/test_graphhopper_routing.py --coords "lat1,lon1 lat2,lon2 ..."
    OR
    python3 scripts/test_graphhopper_routing.py --geojson polygon.geojson
"""

import requests
import json
import sys
import argparse
from typing import List, Tuple

# Configuration
API_BASE_URL = "https://runmap.chouinard.me"  # Change to http://localhost:3000 for local testing
GRAPHHOPPER_URL = "https://map.chouinard.me"


def extract_centroids_from_polygon(polygon_coords: List[Tuple[float, float]]) -> dict:
    """
    Call the RunMap API to extract centroids from a polygon.

    Args:
        polygon_coords: List of (lon, lat) tuples defining the polygon

    Returns:
        API response with centroids
    """
    # Create GeoJSON polygon
    # Note: GeoJSON polygons must close (first point = last point)
    if polygon_coords[0] != polygon_coords[-1]:
        polygon_coords.append(polygon_coords[0])

    geojson = {
        "type": "Polygon",
        "coordinates": [polygon_coords]  # Array of linear rings
    }

    print(f"Calling RunMap API to extract centroids...")
    print(f"Polygon: {len(polygon_coords)-1} vertices")

    response = requests.post(
        f"{API_BASE_URL}/api/centroids/extract",
        json={"polygon": geojson},
        headers={"Content-Type": "application/json"}
    )

    if response.status_code != 200:
        print(f"Error: API returned {response.status_code}")
        print(response.text)
        sys.exit(1)

    return response.json()


def route_with_graphhopper(waypoints: List[Tuple[float, float]], profile: str = "foot") -> dict:
    """
    Send waypoints to GraphHopper for routing.

    Args:
        waypoints: List of (lat, lon) tuples
        profile: Routing profile (foot, bike, car, etc.)

    Returns:
        GraphHopper routing response
    """
    # Build points parameter: point=lat1,lon1&point=lat2,lon2&...
    points = [f"{lat},{lon}" for lat, lon in waypoints]

    params = {
        "profile": profile,
        "points_encoded": "false",  # Get human-readable coordinates
        "instructions": "true",
        "calc_points": "true",
        "optimize": "false"  # Set to "true" to solve TSP (reorder waypoints)
    }

    # Add points as separate parameters
    url = f"{GRAPHHOPPER_URL}/route"

    print(f"\nSending {len(waypoints)} waypoints to GraphHopper...")
    print(f"Profile: {profile}")
    print(f"URL: {url}")

    # GraphHopper expects point parameters in query string
    response = requests.get(
        url,
        params=params,
        headers={"Accept": "application/json"},
        # Add points as list
        data={"point": points} if len(points) > 0 else None
    )

    # Actually, GraphHopper needs points in the URL, let me fix this
    # Build URL manually with repeated point parameters
    point_params = "&".join([f"point={p}" for p in points])
    full_url = f"{url}?profile={profile}&points_encoded=false&instructions=true&calc_points=true&{point_params}"

    print(f"Full URL length: {len(full_url)} chars")

    response = requests.get(full_url, headers={"Accept": "application/json"})

    if response.status_code != 200:
        print(f"Error: GraphHopper returned {response.status_code}")
        print(response.text)
        return None

    return response.json()


def print_route_summary(route_data: dict):
    """Print a summary of the GraphHopper route."""
    if not route_data or "paths" not in route_data:
        print("No route found!")
        return

    path = route_data["paths"][0]
    distance_km = path["distance"] / 1000.0
    distance_mi = distance_km * 0.621371
    time_min = path["time"] / 60000.0  # milliseconds to minutes

    print(f"\n{'='*60}")
    print(f"ROUTE SUMMARY")
    print(f"{'='*60}")
    print(f"Distance: {distance_km:.2f} km ({distance_mi:.2f} miles)")
    print(f"Time: {time_min:.1f} minutes")
    print(f"Number of waypoints: {len(path['points']['coordinates'])}")

    if "instructions" in path:
        print(f"\nTurn-by-turn instructions:")
        for i, instruction in enumerate(path["instructions"][:10], 1):  # First 10 instructions
            text = instruction.get("text", "")
            dist_m = instruction.get("distance", 0)
            print(f"  {i}. {text} ({dist_m:.0f}m)")

        if len(path["instructions"]) > 10:
            print(f"  ... and {len(path['instructions']) - 10} more instructions")


def main():
    parser = argparse.ArgumentParser(description="Test GraphHopper routing with unrun segment centroids")
    parser.add_argument("--coords", help="Space-separated lat,lon pairs (e.g., '38.5,-121.5 38.51,-121.51')")
    parser.add_argument("--geojson", help="Path to GeoJSON polygon file")
    parser.add_argument("--polygon", help="Polygon as JSON string")
    parser.add_argument("--profile", default="foot", help="Routing profile (foot, bike, car)")
    parser.add_argument("--optimize", action="store_true", help="Optimize waypoint order (TSP)")

    args = parser.parse_args()

    waypoints = []

    if args.coords:
        # Parse coordinate pairs
        coord_pairs = args.coords.strip().split()
        for pair in coord_pairs:
            lat, lon = pair.split(",")
            waypoints.append((float(lat), float(lon)))
        print(f"Using {len(waypoints)} provided coordinates")

    elif args.geojson:
        # Load polygon from GeoJSON file
        with open(args.geojson, 'r') as f:
            geojson = json.load(f)

        if geojson["type"] == "Polygon":
            polygon_coords = geojson["coordinates"][0]
        elif geojson["type"] == "Feature":
            polygon_coords = geojson["geometry"]["coordinates"][0]
        else:
            print("Error: GeoJSON must be a Polygon or Feature with Polygon geometry")
            sys.exit(1)

        # Extract centroids from API
        result = extract_centroids_from_polygon(polygon_coords)

        if result["status"] != "success":
            print(f"Error: {result.get('message', 'Unknown error')}")
            sys.exit(1)

        centroids = result["data"]["centroids"]
        print(f"\nExtracted {len(centroids)} unrun block centroids:")

        for c in centroids:
            print(f"  - {c['street_name']}: ({c['lat']:.6f}, {c['lon']:.6f}) - {c['coverage_pct']:.1f}% coverage")
            waypoints.append((c["lat"], c["lon"]))

    elif args.polygon:
        # Parse polygon JSON
        polygon_coords = json.loads(args.polygon)
        result = extract_centroids_from_polygon(polygon_coords)

        if result["status"] != "success":
            print(f"Error: {result.get('message', 'Unknown error')}")
            sys.exit(1)

        centroids = result["data"]["centroids"]
        print(f"\nExtracted {len(centroids)} unrun block centroids")

        for c in centroids:
            waypoints.append((c["lat"], c["lon"]))

    else:
        print("Error: Must provide --coords, --geojson, or --polygon")
        parser.print_help()
        sys.exit(1)

    if len(waypoints) == 0:
        print("No waypoints to route!")
        sys.exit(1)

    if len(waypoints) > 50:
        print(f"\nWarning: {len(waypoints)} waypoints is a lot! This may take a while...")
        response = input("Continue? (y/n): ")
        if response.lower() != "y":
            sys.exit(0)

    # Route with GraphHopper
    route_data = route_with_graphhopper(waypoints, profile=args.profile)

    if route_data:
        print_route_summary(route_data)

        # Optionally save to file
        output_file = "/tmp/graphhopper_route.json"
        with open(output_file, "w") as f:
            json.dump(route_data, f, indent=2)
        print(f"\nFull route saved to: {output_file}")


if __name__ == "__main__":
    main()
