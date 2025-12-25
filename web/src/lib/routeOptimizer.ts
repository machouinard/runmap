/**
 * Route optimization for street coverage
 *
 * Instead of pure TSP, we use a grid-aware approach that:
 * 1. Groups nearby parallel blocks
 * 2. Creates a "snake" pattern (boustrophedon) through parallel streets
 * 3. Minimizes backtracking by alternating directions
 */

import { haversineDistance } from './utils'

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

interface Waypoint {
	lat: number
	lon: number
	block_id: number
	street_name: string
	type: 'start' | 'end' | 'centroid'
}

/**
 * Calculate bearing (direction) between two points in degrees
 * 0° = North, 90° = East, 180° = South, 270° = West
 */
function calculateBearing(lat1: number, lon1: number, lat2: number, lon2: number): number {
	const dLon = (lon2 - lon1) * Math.PI / 180
	const lat1Rad = lat1 * Math.PI / 180
	const lat2Rad = lat2 * Math.PI / 180

	const y = Math.sin(dLon) * Math.cos(lat2Rad)
	const x = Math.cos(lat1Rad) * Math.sin(lat2Rad) -
	          Math.sin(lat1Rad) * Math.cos(lat2Rad) * Math.cos(dLon)

	let bearing = Math.atan2(y, x) * 180 / Math.PI
	return (bearing + 360) % 360 // Normalize to 0-360
}

/**
 * Check if two blocks are parallel (similar orientation)
 */
function areBlocksParallel(block1: BlockWithEndpoints, block2: BlockWithEndpoints, threshold = 20): boolean {
	const bearing1 = calculateBearing(block1.start_lat, block1.start_lon, block1.end_lat, block1.end_lon)
	const bearing2 = calculateBearing(block2.start_lat, block2.start_lon, block2.end_lat, block2.end_lon)

	// Check if bearings are within threshold degrees (accounting for wrap-around at 0/360)
	const diff = Math.abs(bearing1 - bearing2)
	return diff < threshold || diff > (360 - threshold) || Math.abs(diff - 180) < threshold
}

/**
 * Group blocks into parallel "lanes" based on orientation and proximity
 */
function groupParallelBlocks(blocks: BlockWithEndpoints[]): BlockWithEndpoints[][] {
	if (blocks.length === 0) return []
	if (blocks.length === 1) return [blocks]

	const groups: BlockWithEndpoints[][] = []
	const used = new Set<number>()

	for (let i = 0; i < blocks.length; i++) {
		if (used.has(i)) continue

		const group = [blocks[i]]
		used.add(i)

		// Find other blocks parallel to this one
		for (let j = i + 1; j < blocks.length; j++) {
			if (used.has(j)) continue

			if (areBlocksParallel(blocks[i], blocks[j])) {
				// Check if they're reasonably close (within 500m)
				const dist = haversineDistance(
					[blocks[i].centroid_lat, blocks[i].centroid_lon],
					[blocks[j].centroid_lat, blocks[j].centroid_lon]
				)

				if (dist < 0.5) { // Within 500m
					group.push(blocks[j])
					used.add(j)
				}
			}
		}

		groups.push(group)
	}

	return groups
}

/**
 * Create snake pattern through parallel blocks
 * Alternates direction to minimize backtracking
 */
function createSnakePattern(group: BlockWithEndpoints[], startPos: [number, number]): Waypoint[] {
	if (group.length === 0) return []
	if (group.length === 1) {
		// Single block: pick nearest endpoint to start
		const block = group[0]
		const distToStart = haversineDistance(startPos, [block.start_lat, block.start_lon])
		const distToEnd = haversineDistance(startPos, [block.end_lat, block.end_lon])

		if (distToStart <= distToEnd) {
			return [
				{ lat: block.start_lat, lon: block.start_lon, block_id: block.block_id, street_name: block.street_name, type: 'start' },
				{ lat: block.end_lat, lon: block.end_lon, block_id: block.block_id, street_name: block.street_name, type: 'end' }
			]
		} else {
			return [
				{ lat: block.end_lat, lon: block.end_lon, block_id: block.block_id, street_name: block.street_name, type: 'end' },
				{ lat: block.start_lat, lon: block.start_lon, block_id: block.block_id, street_name: block.street_name, type: 'start' }
			]
		}
	}

	// Sort blocks in the group by position perpendicular to their orientation
	// (This orders them by which "lane" they're in)
	const bearing = calculateBearing(group[0].start_lat, group[0].start_lon, group[0].end_lat, group[0].end_lon)
	const perpBearing = (bearing + 90) % 360

	const sorted = [...group].sort((a, b) => {
		// Project centroid onto perpendicular axis
		const projA = a.centroid_lat * Math.cos(perpBearing * Math.PI / 180) + a.centroid_lon * Math.sin(perpBearing * Math.PI / 180)
		const projB = b.centroid_lat * Math.cos(perpBearing * Math.PI / 180) + b.centroid_lon * Math.sin(perpBearing * Math.PI / 180)
		return projA - projB
	})

	// Create snake pattern: alternate direction for each block
	const waypoints: Waypoint[] = []
	let currentPos = startPos

	for (let i = 0; i < sorted.length; i++) {
		const block = sorted[i]
		const nextIndex = i + 1 < sorted.length ? i + 1 : -1

		if (nextIndex === -1) {
			// Last block: pick nearest endpoint
			const distToStart = haversineDistance(currentPos, [block.start_lat, block.start_lon])
			const distToEnd = haversineDistance(currentPos, [block.end_lat, block.end_lon])

			if (distToStart <= distToEnd) {
				waypoints.push({ lat: block.start_lat, lon: block.start_lon, block_id: block.block_id, street_name: block.street_name, type: 'start' })
				waypoints.push({ lat: block.end_lat, lon: block.end_lon, block_id: block.block_id, street_name: block.street_name, type: 'end' })
			} else {
				waypoints.push({ lat: block.end_lat, lon: block.end_lon, block_id: block.block_id, street_name: block.street_name, type: 'end' })
				waypoints.push({ lat: block.start_lat, lon: block.start_lon, block_id: block.block_id, street_name: block.street_name, type: 'start' })
			}
		} else {
			const nextBlock = sorted[nextIndex]

			// Choose direction that ends closest to the next block's nearest point
			const nextStart: [number, number] = [nextBlock.start_lat, nextBlock.start_lon]
			const nextEnd: [number, number] = [nextBlock.end_lat, nextBlock.end_lon]

			// Option A: current → block.start → block.end
			const distA_toNextStart = haversineDistance([block.end_lat, block.end_lon], nextStart)
			const distA_toNextEnd = haversineDistance([block.end_lat, block.end_lon], nextEnd)
			const distA = Math.min(distA_toNextStart, distA_toNextEnd)

			// Option B: current → block.end → block.start
			const distB_toNextStart = haversineDistance([block.start_lat, block.start_lon], nextStart)
			const distB_toNextEnd = haversineDistance([block.start_lat, block.start_lon], nextEnd)
			const distB = Math.min(distB_toNextStart, distB_toNextEnd)

			if (distA <= distB) {
				waypoints.push({ lat: block.start_lat, lon: block.start_lon, block_id: block.block_id, street_name: block.street_name, type: 'start' })
				waypoints.push({ lat: block.end_lat, lon: block.end_lon, block_id: block.block_id, street_name: block.street_name, type: 'end' })
				currentPos = [block.end_lat, block.end_lon]
			} else {
				waypoints.push({ lat: block.end_lat, lon: block.end_lon, block_id: block.block_id, street_name: block.street_name, type: 'end' })
				waypoints.push({ lat: block.start_lat, lon: block.start_lon, block_id: block.block_id, street_name: block.street_name, type: 'start' })
				currentPos = [block.start_lat, block.start_lon]
			}
		}
	}

	return waypoints
}

/**
 * Optimize route for street coverage using grid-aware snake patterns
 */
export function optimizeRouteForCoverage(
	blocks: BlockWithEndpoints[],
	startPoint?: { lat: number; lon: number }
): Waypoint[] {
	if (blocks.length === 0) return []

	const startPos: [number, number] = startPoint
		? [startPoint.lat, startPoint.lon]
		: [blocks[0].centroid_lat, blocks[0].centroid_lon]

	// Group blocks into parallel lanes
	const groups = groupParallelBlocks(blocks)

	// Sort groups by distance from start point
	const sortedGroups = groups.sort((a, b) => {
		const distA = haversineDistance(startPos, [a[0].centroid_lat, a[0].centroid_lon])
		const distB = haversineDistance(startPos, [b[0].centroid_lat, b[0].centroid_lon])
		return distA - distB
	})

	// Create waypoints by processing each group with snake pattern
	const allWaypoints: Waypoint[] = []
	let currentPos = startPos

	for (const group of sortedGroups) {
		const groupWaypoints = createSnakePattern(group, currentPos)
		allWaypoints.push(...groupWaypoints)

		// Update current position to end of this group
		if (groupWaypoints.length > 0) {
			const last = groupWaypoints[groupWaypoints.length - 1]
			currentPos = [last.lat, last.lon]
		}
	}

	return allWaypoints
}
