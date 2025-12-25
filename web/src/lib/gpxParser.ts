/**
 * Parse GPX file and convert to GeoJSON LineString
 */
export interface GeoJSONLineString {
	type: 'Feature'
	geometry: {
		type: 'LineString'
		coordinates: [number, number][]
	}
	properties: {
		name?: string
	}
}

/**
 * Planned route with source metadata
 */
export interface PlannedRoute {
	geojson: GeoJSONLineString
	source: {
		type: 'file' | 'activity'
		// For activity source:
		activityId?: string
		activityType?: 'run' | 'walk' | 'cycling'
		startTime?: string
		distanceM?: number
		location?: string
		duration_seconds?: number
	}
}

export function parseGPX(gpxText: string): GeoJSONLineString | null {
	try {
		const parser = new DOMParser()
		const xmlDoc = parser.parseFromString(gpxText, 'text/xml')

		// Check for parsing errors
		const parseError = xmlDoc.querySelector('parsererror')
		if (parseError) {
			console.error('GPX parsing error:', parseError.textContent)
			return null
		}

		// Extract track points (trkpt) from GPX
		const trackPoints = xmlDoc.querySelectorAll('trkpt')

		if (trackPoints.length === 0) {
			console.warn('No track points found in GPX file')
			return null
		}

		// Convert to GeoJSON coordinates [lon, lat]
		const coordinates: [number, number][] = []
		trackPoints.forEach((trkpt) => {
			const lat = parseFloat(trkpt.getAttribute('lat') || '0')
			const lon = parseFloat(trkpt.getAttribute('lon') || '0')
			if (!isNaN(lat) && !isNaN(lon)) {
				coordinates.push([lon, lat])
			}
		})

		if (coordinates.length === 0) {
			console.warn('No valid coordinates found in GPX file')
			return null
		}

		// Extract track name if available
		const trackName =
			xmlDoc.querySelector('trk > name')?.textContent || 'Planned Route'

		return {
			type: 'Feature',
			geometry: {
				type: 'LineString',
				coordinates,
			},
			properties: {
				name: trackName,
			},
		}
	} catch (error) {
		console.error('Error parsing GPX:', error)
		return null
	}
}
