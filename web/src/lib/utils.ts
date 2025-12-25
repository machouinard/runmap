import { type ClassValue, clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
	return twMerge(clsx(inputs))
}

export function nearestNeighborSort(
	points: [number, number][]
): [number, number][] {
	if (points.length <= 1) return points

	const sorted: [number, number][] = [points[0]]
	const remaining = new Set(points.slice(1))

	while (remaining.size > 0) {
		const lastPoint = sorted[sorted.length - 1]
		let nearest: [number, number] | null = null
		let minDistance = Infinity

		for (const point of remaining) {
			const distance = haversineDistance(lastPoint, point)
			if (distance < minDistance) {
				minDistance = distance
				nearest = point
			}
		}

		if (nearest) {
			sorted.push(nearest)
			remaining.delete(nearest)
		}
	}

	return sorted
}

export function haversineDistance(
	coord1: [number, number],
	coord2: [number, number]
): number {
	const [lat1, lon1] = coord1
	const [lat2, lon2] = coord2
	const R = 6371 // Earth radius in km
	const dLat = ((lat2 - lat1) * Math.PI) / 180
	const dLon = ((lon2 - lon1) * Math.PI) / 180
	const a =
		Math.sin(dLat / 2) * Math.sin(dLat / 2) +
		Math.cos((lat1 * Math.PI) / 180) *
			Math.cos((lat2 * Math.PI) / 180) *
			Math.sin(dLon / 2) *
			Math.sin(dLon / 2)
	return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

/**
 * Sort blocks with start/end points to minimize backtracking.
 * Uses nearest-neighbor TSP on block centroids, then for each block,
 * determines which endpoint to visit first based on approach direction.
 *
 * @param blocks - Array of blocks with start_lat, start_lon, end_lat, end_lon, centroid_lat, centroid_lon
 * @returns Array of ordered waypoints [lat, lon]
 */
export interface BlockWithEndpoints {
	block_id: number
	street_name: string
	start_lat: number
	start_lon: number
	end_lat: number
	end_lon: number
	centroid_lat: number
	centroid_lon: number
	total_unvisited_length_m: number
	unvisited_segment_count: number
	coverage_pct?: number
	segment_ids?: number[]
}

export function sortBlocksForRouting(
	blocks: BlockWithEndpoints[],
	startPoint?: { lat: number; lon: number }
): Array<{ lat: number; lon: number; block_id: number; street_name: string; type: 'start' | 'end' }> {
	if (blocks.length === 0) return []

	console.log(`🎯 Using greedy nearest-neighbor routing for ${blocks.length} blocks...`)

	// Start from the provided point or the first block's start
	let currentPos: [number, number] = startPoint
		? [startPoint.lat, startPoint.lon]
		: [blocks[0].start_lat, blocks[0].start_lon]

	const unvisited = new Set(blocks)
	const waypoints: Array<{ lat: number; lon: number; block_id: number; street_name: string; type: 'start' | 'end' }> = []

	// Greedy algorithm: always go to nearest unvisited block
	while (unvisited.size > 0) {
		let nearestBlock: BlockWithEndpoints | null = null
		let nearestDistance = Infinity
		let useStartFirst = true

		// Find the nearest unvisited block
		for (const block of unvisited) {
			// Check distance to both endpoints
			const distToStart = haversineDistance(currentPos, [block.start_lat, block.start_lon])
			const distToEnd = haversineDistance(currentPos, [block.end_lat, block.end_lon])

			// Use whichever endpoint is closer
			if (distToStart < nearestDistance) {
				nearestDistance = distToStart
				nearestBlock = block
				useStartFirst = true
			}
			if (distToEnd < nearestDistance) {
				nearestDistance = distToEnd
				nearestBlock = block
				useStartFirst = false
			}
		}

		if (!nearestBlock) break

		// Add the block's waypoints in the order that makes sense
		if (useStartFirst) {
			// Enter from start, exit from end
			waypoints.push({
				lat: nearestBlock.start_lat,
				lon: nearestBlock.start_lon,
				block_id: nearestBlock.block_id,
				street_name: nearestBlock.street_name,
				type: 'start'
			})
			waypoints.push({
				lat: nearestBlock.end_lat,
				lon: nearestBlock.end_lon,
				block_id: nearestBlock.block_id,
				street_name: nearestBlock.street_name,
				type: 'end'
			})
			currentPos = [nearestBlock.end_lat, nearestBlock.end_lon]
		} else {
			// Enter from end, exit from start
			waypoints.push({
				lat: nearestBlock.end_lat,
				lon: nearestBlock.end_lon,
				block_id: nearestBlock.block_id,
				street_name: nearestBlock.street_name,
				type: 'end'
			})
			waypoints.push({
				lat: nearestBlock.start_lat,
				lon: nearestBlock.start_lon,
				block_id: nearestBlock.block_id,
				street_name: nearestBlock.street_name,
				type: 'start'
			})
			currentPos = [nearestBlock.start_lat, nearestBlock.start_lon]
		}

		unvisited.delete(nearestBlock)
	}

	console.log(`✅ Generated ${waypoints.length} waypoints for ${blocks.length} blocks`)
	return waypoints
}
