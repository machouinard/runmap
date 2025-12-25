/**
 * Map utility functions for bounds calculations and positioning
 */

/**
 * Calculate bounding box from an array of coordinates
 * @param coordinates Array of [longitude, latitude] pairs
 * @returns Bounding box in MapLibre format: [[west, south], [east, north]]
 */
export function calculateBounds(
  coordinates: [number, number][]
): [[number, number], [number, number]] {
  if (coordinates.length === 0) {
    throw new Error('Cannot calculate bounds from empty coordinates array')
  }

  let minLng = Infinity
  let minLat = Infinity
  let maxLng = -Infinity
  let maxLat = -Infinity

  // Find min/max coordinates
  coordinates.forEach(([lng, lat]) => {
    minLng = Math.min(minLng, lng)
    minLat = Math.min(minLat, lat)
    maxLng = Math.max(maxLng, lng)
    maxLat = Math.max(maxLat, lat)
  })

  // Calculate padding (10% of span, minimum 0.005 degrees for very short routes)
  const lngSpan = maxLng - minLng
  const latSpan = maxLat - minLat
  const lngPadding = Math.max(lngSpan * 0.1, 0.005)
  const latPadding = Math.max(latSpan * 0.1, 0.005)

  // Return bounds with padding
  return [
    [minLng - lngPadding, minLat - latPadding], // Southwest corner
    [maxLng + lngPadding, maxLat + latPadding], // Northeast corner
  ]
}
