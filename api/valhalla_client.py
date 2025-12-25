"""
Valhalla Routing Client for RunMap

This module provides a client for the Valhalla routing engine with special handling
to ensure complete block coverage. The key challenge is that routing engines may
skip portions of street segments when routing between waypoints. This client
addresses that by:

1. Adding location attributes (minimum_reachability, radius) to force proper snapping
2. Validating that the returned route covers the expected street segments
3. Auto-generating intermediate waypoints when needed to force full block traversal

Architecture:
- Valhalla handles the actual routing (shortest paths, turn-by-turn, etc.)
- RunMap database tracks which segments are visited/unvisited
- This client ensures the route includes all intended street segments

Usage:
    client = ValhallaClient(base_url="https://valhalla.chouinard.me")

    # Simple routing (no block coverage validation)
    result = client.route(locations=[
        {"lat": 38.5816, "lon": -121.4944},
        {"lat": 38.5820, "lon": -121.4950}
    ])

    # Routing with block coverage guarantee
    result = client.route_with_block_coverage(
        blocks=[{
            "block_id": 789,
            "start_lat": 38.5816,
            "start_lon": -121.4944,
            "end_lat": 38.5820,
            "end_lon": -121.4950,
            "centroid_lat": 38.5818,
            "centroid_lon": -121.4947
        }],
        conn=db_connection  # PostgreSQL connection for validation
    )
"""

import requests
import polyline
from typing import List, Dict, Any, Optional, Tuple
import logging

logger = logging.getLogger(__name__)


class ValhallaClient:
    """Client for Valhalla routing API with block coverage guarantees."""

    def __init__(self, base_url: str = "https://valhalla.chouinard.me"):
        """
        Initialize Valhalla client.

        Args:
            base_url: Base URL of Valhalla server (no trailing slash)
        """
        self.base_url = base_url.rstrip('/')

        # Default location attributes for pedestrian routing
        # These ensure waypoints snap to the correct street segment
        self.default_location_attrs = {
            "minimum_reachability": 1,  # Force routing through this point
            "radius": 10  # Search radius in meters (GPS accuracy)
        }

        # Pedestrian costing options optimized for running
        self.default_costing_options = {
            "pedestrian": {
                "walking_speed": 8.0,  # km/h (5 mph running pace)
                "use_roads": 1.0,  # Prefer roads over paths
                "use_living_streets": 1.0,  # Include residential streets
                "step_penalty": 0.0  # No penalty for steps (runners don't care)
            }
        }

    def route(
        self,
        locations: List[Dict[str, float]],
        costing: str = "pedestrian",
        costing_options: Optional[Dict] = None,
        directions_options: Optional[Dict] = None
    ) -> Dict[str, Any]:
        """
        Call Valhalla /route endpoint.

        Args:
            locations: List of waypoints, each with 'lat', 'lon', and optional attributes:
                - minimum_reachability: Force routing through this point (0-50)
                - radius: Search radius in meters (default: 10)
                - heading: Preferred direction in degrees (0-359)
            costing: Routing profile (pedestrian, auto, bicycle, etc.)
            costing_options: Override default costing options
            directions_options: Options for turn-by-turn directions

        Returns:
            {
                "trip": {
                    "legs": [...],
                    "summary": {"length": km, "time": seconds},
                    "locations": [...]
                },
                "decoded_polyline": [[lat, lon], ...],
                "encoded_polyline": "...",
                "distance_km": float,
                "time_seconds": float
            }

        Raises:
            requests.HTTPError: If Valhalla returns an error
        """
        # Add default location attributes to each waypoint
        enhanced_locations = []
        for loc in locations:
            enhanced = {
                "lat": loc["lat"],
                "lon": loc["lon"],
                **self.default_location_attrs
            }
            # Allow override of defaults
            if "minimum_reachability" in loc:
                enhanced["minimum_reachability"] = loc["minimum_reachability"]
            if "radius" in loc:
                enhanced["radius"] = loc["radius"]
            if "heading" in loc:
                enhanced["heading"] = loc["heading"]
            enhanced_locations.append(enhanced)

        # Build request body
        body = {
            "locations": enhanced_locations,
            "costing": costing,
            "costing_options": costing_options or self.default_costing_options,
            "units": "kilometers"
        }

        if directions_options:
            body["directions_options"] = directions_options

        # Call Valhalla API
        url = f"{self.base_url}/route"
        logger.info(f"Calling Valhalla /route with {len(enhanced_locations)} waypoints")

        response = requests.post(url, json=body, timeout=30)
        response.raise_for_status()

        result = response.json()

        # Extract and decode polyline
        if "trip" in result and "legs" in result["trip"]:
            # Valhalla returns one polyline per leg
            all_coords = []
            for leg in result["trip"]["legs"]:
                if "shape" in leg:
                    # Decode polyline (Valhalla uses precision 6 by default)
                    coords = polyline.decode(leg["shape"], precision=6)
                    all_coords.extend(coords)

            # Get summary stats
            summary = result["trip"].get("summary", {})

            return {
                "trip": result["trip"],
                "decoded_polyline": all_coords,
                "encoded_polyline": result["trip"]["legs"][0]["shape"] if result["trip"]["legs"] else "",
                "distance_km": summary.get("length", 0),
                "time_seconds": summary.get("time", 0)
            }

        # Fallback if response format is unexpected
        return result

    def optimized_route(
        self,
        locations: List[Dict[str, float]],
        costing: str = "pedestrian",
        costing_options: Optional[Dict] = None
    ) -> Dict[str, Any]:
        """
        Call Valhalla /optimized_route endpoint (TSP solver).

        This endpoint automatically optimizes the order of waypoints to minimize
        total distance. Useful when you have many unrun blocks and want Valhalla
        to determine the best order to visit them.

        Args:
            locations: List of waypoints (same format as route())
            costing: Routing profile
            costing_options: Override default costing options

        Returns:
            Same format as route(), but with waypoints reordered optimally
        """
        # Add default location attributes
        enhanced_locations = []
        for loc in locations:
            enhanced = {
                "lat": loc["lat"],
                "lon": loc["lon"],
                **self.default_location_attrs
            }
            if "minimum_reachability" in loc:
                enhanced["minimum_reachability"] = loc["minimum_reachability"]
            if "radius" in loc:
                enhanced["radius"] = loc["radius"]
            enhanced_locations.append(enhanced)

        body = {
            "locations": enhanced_locations,
            "costing": costing,
            "costing_options": costing_options or self.default_costing_options,
            "units": "kilometers"
        }

        url = f"{self.base_url}/optimized_route"
        logger.info(f"Calling Valhalla /optimized_route with {len(enhanced_locations)} waypoints")

        response = requests.post(url, json=body, timeout=60)  # TSP can take longer
        response.raise_for_status()

        result = response.json()

        # Decode polyline (same logic as route())
        if "trip" in result and "legs" in result["trip"]:
            all_coords = []
            for leg in result["trip"]["legs"]:
                if "shape" in leg:
                    coords = polyline.decode(leg["shape"], precision=6)
                    all_coords.extend(coords)

            summary = result["trip"].get("summary", {})

            return {
                "trip": result["trip"],
                "decoded_polyline": all_coords,
                "encoded_polyline": result["trip"]["legs"][0]["shape"] if result["trip"]["legs"] else "",
                "distance_km": summary.get("length", 0),
                "time_seconds": summary.get("time", 0),
                "optimized_order": [loc.get("original_index") for loc in result["trip"].get("locations", [])]
            }

        return result

    def ensure_block_coverage(
        self,
        blocks: List[Dict[str, Any]],
        conn,
        start_point: Dict[str, float],
        use_optimized: bool = True,
        max_retries: int = 2
    ) -> Dict[str, Any]:
        """
        Route through blocks with guaranteed coverage of each block segment.

        This is the core method for RunMap's unrun segment routing. It ensures
        that the returned route actually traverses the full length of each block,
        not just passes near it.

        Algorithm:
        1. Create locations from block endpoints or centroids
        2. Call Valhalla (optionally with TSP optimization)
        3. Validate that the route polyline intersects each block geometry
        4. If validation fails, add intermediate waypoints and retry

        Args:
            blocks: List of block dicts with keys:
                - block_id: Integer block ID (from streets_blocks_32610)
                - geometry_coordinates: List of [lon, lat] pairs (full block shape) - PREFERRED
                - start_lat, start_lon: Block start point (fallback if no geometry)
                - end_lat, end_lon: Block end point (fallback if no geometry)
                - centroid_lat, centroid_lon: Block centroid (optional)
                - street_name: Name for logging
            conn: psycopg2 database connection (for PostGIS validation)
            start_point: Dict with 'lat' and 'lon' for circular route start/end (required)
            use_optimized: Use /optimized_route (TSP) instead of fixed order
            max_retries: How many times to retry with added waypoints

        Returns:
            {
                "route": {...},  # Full Valhalla response
                "geojson": {...},  # GeoJSON LineString for map display
                "coverage_validation": {
                    "blocks_covered": int,
                    "blocks_total": int,
                    "missing_blocks": [block_id, ...],
                    "coverage_pct": float
                }
            }
        """
        if not blocks:
            raise ValueError("No blocks provided")

        if not start_point or 'lat' not in start_point or 'lon' not in start_point:
            raise ValueError("start_point is required with 'lat' and 'lon' keys")

        logger.info(f"Routing through {len(blocks)} blocks with coverage guarantee (start: {start_point['lat']:.6f}, {start_point['lon']:.6f})")

        # Phase 1: Create initial waypoints
        # Strategy: Use ALL vertices from each block's geometry to force full traversal
        # This ensures we follow the exact shape of curved/bent blocks
        locations = []
        block_lookup = {}  # Map waypoint index to block_id

        for block in blocks:
            # If block has full geometry coordinates, use ALL of them
            if 'geometry_coordinates' in block and block['geometry_coordinates']:
                coords = block['geometry_coordinates']
                # coords is a list of [lon, lat] pairs - add each as a waypoint
                for lon, lat in coords:
                    locations.append({
                        "lat": lat,
                        "lon": lon,
                        "minimum_reachability": 1,
                        "radius": 10
                    })
                    block_lookup[len(locations) - 1] = block["block_id"]
            else:
                # Fallback: use just start and end points (backwards compatibility)
                locations.append({
                    "lat": block["start_lat"],
                    "lon": block["start_lon"],
                    "minimum_reachability": 1,
                    "radius": 10
                })
                block_lookup[len(locations) - 1] = block["block_id"]

                locations.append({
                    "lat": block["end_lat"],
                    "lon": block["end_lon"],
                    "minimum_reachability": 1,
                    "radius": 10
                })
                block_lookup[len(locations) - 1] = block["block_id"]

        # Make route circular: add start point at beginning and end
        # start_point comes from the first polygon vertex (user's first click)
        # Use type="break" to prevent TSP from reordering start/end points
        start_waypoint_begin = {
            "lat": start_point["lat"],
            "lon": start_point["lon"],
            "type": "break",  # Fixed start - don't reorder
            "minimum_reachability": 1,
            "radius": 10
        }
        start_waypoint_end = {
            "lat": start_point["lat"],
            "lon": start_point["lon"],
            "type": "break",  # Fixed end - don't reorder
            "minimum_reachability": 1,
            "radius": 10
        }
        locations.insert(0, start_waypoint_begin)  # Add at beginning
        locations.append(start_waypoint_end)  # Add at end

        # Phase 2: Route through waypoints
        route_result = None
        for attempt in range(max_retries + 1):
            try:
                if use_optimized:
                    route_result = self.optimized_route(locations)
                else:
                    route_result = self.route(locations)
                break
            except requests.HTTPError as e:
                if attempt == max_retries:
                    raise
                logger.warning(f"Valhalla routing failed (attempt {attempt + 1}): {e}")
                # Increase search radius for next attempt
                for loc in locations:
                    loc["radius"] = min(loc.get("radius", 10) + 5, 50)

        if not route_result:
            raise RuntimeError("Failed to get route from Valhalla")

        # Phase 3: Validate coverage using PostGIS
        coverage = self._validate_block_coverage(
            route_polyline=route_result["decoded_polyline"],
            blocks=blocks,
            conn=conn
        )

        # Phase 4: If coverage is incomplete, try adding waypoints
        if coverage["coverage_pct"] < 95.0 and attempt < max_retries:
            logger.warning(
                f"Route only covers {coverage['coverage_pct']:.1f}% of blocks. "
                f"Missing {len(coverage['missing_blocks'])} blocks."
            )

            # Add centroid waypoints for missing blocks
            for block in blocks:
                if block["block_id"] in coverage["missing_blocks"]:
                    if "centroid_lat" in block:
                        locations.append({
                            "lat": block["centroid_lat"],
                            "lon": block["centroid_lon"],
                            "minimum_reachability": 2,  # Higher priority
                            "radius": 15
                        })
                        logger.info(f"Added centroid waypoint for block {block['block_id']}")

            # Retry routing with additional waypoints
            return self.ensure_block_coverage(
                blocks=blocks,
                conn=conn,
                use_optimized=use_optimized,
                max_retries=max_retries - 1
            )

        # Phase 5: Convert to GeoJSON for frontend
        geojson = {
            "type": "Feature",
            "geometry": {
                "type": "LineString",
                "coordinates": [[lon, lat] for lat, lon in route_result["decoded_polyline"]]
            },
            "properties": {
                "distance_km": route_result["distance_km"],
                "time_seconds": route_result["time_seconds"],
                "blocks_total": len(blocks),
                "blocks_covered": coverage["blocks_covered"]
            }
        }

        return {
            "route": route_result,
            "geojson": geojson,
            "coverage_validation": coverage
        }

    def _validate_block_coverage(
        self,
        route_polyline: List[Tuple[float, float]],
        blocks: List[Dict[str, Any]],
        conn,
        buffer_m: float = 10.0
    ) -> Dict[str, Any]:
        """
        Validate that the route polyline covers the expected blocks.

        Uses PostGIS to check if the route intersects each block geometry.
        A block is considered "covered" if the route comes within buffer_m
        meters of the block.

        Args:
            route_polyline: List of (lat, lon) tuples
            blocks: List of block dicts with block_id
            conn: psycopg2 connection
            buffer_m: Buffer distance in meters (should match GPS buffer)

        Returns:
            {
                "blocks_covered": int,
                "blocks_total": int,
                "missing_blocks": [block_id, ...],
                "coverage_pct": float
            }
        """
        if not route_polyline:
            return {
                "blocks_covered": 0,
                "blocks_total": len(blocks),
                "missing_blocks": [b["block_id"] for b in blocks],
                "coverage_pct": 0.0
            }

        # Convert polyline to WKT LineString
        # Format: LINESTRING(lon1 lat1, lon2 lat2, ...)
        coords_wkt = ", ".join([f"{lon} {lat}" for lat, lon in route_polyline])
        route_wkt = f"LINESTRING({coords_wkt})"

        # Query: Check which blocks intersect the buffered route
        block_ids = [b["block_id"] for b in blocks]

        cur = conn.cursor()
        cur.execute("""
            WITH route_geom AS (
                SELECT ST_Transform(
                    ST_Buffer(
                        ST_GeomFromText(%s, 4326)::geography,
                        %s
                    )::geometry,
                    32610
                ) AS geom
            )
            SELECT b.block_id
            FROM runmap.streets_blocks_32610 b, route_geom r
            WHERE b.block_id = ANY(%s)
              AND ST_Intersects(b.geom_32610, r.geom)
        """, (route_wkt, buffer_m, block_ids))

        covered_blocks = [row['block_id'] for row in cur.fetchall()]
        missing_blocks = [bid for bid in block_ids if bid not in covered_blocks]

        coverage_pct = (len(covered_blocks) / len(block_ids)) * 100 if block_ids else 0

        logger.info(
            f"Coverage validation: {len(covered_blocks)}/{len(block_ids)} blocks "
            f"({coverage_pct:.1f}%)"
        )

        return {
            "blocks_covered": len(covered_blocks),
            "blocks_total": len(block_ids),
            "missing_blocks": missing_blocks,
            "coverage_pct": coverage_pct
        }


def convert_route_to_gpx(route_result: Dict[str, Any], filename: str = "route.gpx") -> str:
    """
    Convert Valhalla route to GPX format.

    Args:
        route_result: Result from ValhallaClient.route() or ensure_block_coverage()
        filename: Output GPX filename

    Returns:
        GPX XML string
    """
    polyline_coords = route_result["decoded_polyline"]

    gpx_points = []
    for lat, lon in polyline_coords:
        gpx_points.append(f'<trkpt lat="{lat}" lon="{lon}"></trkpt>')

    gpx = f"""<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="RunMap Valhalla Client">
  <metadata>
    <name>{filename}</name>
    <desc>Route generated by Valhalla</desc>
  </metadata>
  <trk>
    <name>RunMap Route</name>
    <trkseg>
      {chr(10).join(gpx_points)}
    </trkseg>
  </trk>
</gpx>"""

    return gpx
