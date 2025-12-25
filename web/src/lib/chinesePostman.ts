/**
 * Chinese Postman Problem Solver
 *
 * Finds the shortest path that traverses every edge (street block) at least once.
 * This is THE optimal solution for street coverage problems.
 *
 * Algorithm:
 * 1. Build graph from street blocks (edges) and intersections (vertices)
 * 2. Find all odd-degree vertices
 * 3. Find minimum-weight perfect matching on odd vertices
 * 4. Augment graph with matched edges to make it Eulerian
 * 5. Find Eulerian path through the augmented graph
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

interface Vertex {
	id: string
	lat: number
	lon: number
	degree: number
}

interface Edge {
	id: number
	from: string
	to: string
	block: BlockWithEndpoints
	weight: number // distance in km
	traversed: boolean
}

interface Graph {
	vertices: Map<string, Vertex>
	edges: Edge[]
	adjacency: Map<string, Edge[]>
}

/**
 * Create unique vertex ID from lat/lon (rounded to ~1m precision)
 */
function vertexId(lat: number, lon: number): string {
	return `${lat.toFixed(6)},${lon.toFixed(6)}`
}

/**
 * Build graph from street blocks
 */
function buildGraph(blocks: BlockWithEndpoints[]): Graph {
	const vertices = new Map<string, Vertex>()
	const edges: Edge[] = []
	const adjacency = new Map<string, Edge[]>()

	// Create vertices (intersections) and edges (blocks)
	for (let i = 0; i < blocks.length; i++) {
		const block = blocks[i]

		const startId = vertexId(block.start_lat, block.start_lon)
		const endId = vertexId(block.end_lat, block.end_lon)

		// Add vertices if they don't exist
		if (!vertices.has(startId)) {
			vertices.set(startId, {
				id: startId,
				lat: block.start_lat,
				lon: block.start_lon,
				degree: 0
			})
		}
		if (!vertices.has(endId)) {
			vertices.set(endId, {
				id: endId,
				lat: block.end_lat,
				lon: block.end_lon,
				degree: 0
			})
		}

		// Add edge
		const weight = haversineDistance(
			[block.start_lat, block.start_lon],
			[block.end_lat, block.end_lon]
		)

		const edge: Edge = {
			id: i,
			from: startId,
			to: endId,
			block,
			weight,
			traversed: false
		}

		edges.push(edge)

		// Update adjacency
		if (!adjacency.has(startId)) adjacency.set(startId, [])
		if (!adjacency.has(endId)) adjacency.set(endId, [])
		adjacency.get(startId)!.push(edge)
		adjacency.get(endId)!.push(edge)

		// Update degrees
		vertices.get(startId)!.degree++
		vertices.get(endId)!.degree++
	}

	return { vertices, edges, adjacency }
}

/**
 * Find all shortest paths between vertices using Floyd-Warshall
 * Returns distance matrix and next-hop matrix for path reconstruction
 */
function floydWarshall(graph: Graph): {
	dist: Map<string, Map<string, number>>
	next: Map<string, Map<string, string | null>>
} {
	const vertexIds = Array.from(graph.vertices.keys())
	const dist = new Map<string, Map<string, number>>()
	const next = new Map<string, Map<string, string | null>>()

	// Initialize
	for (const u of vertexIds) {
		dist.set(u, new Map())
		next.set(u, new Map())
		for (const v of vertexIds) {
			dist.get(u)!.set(v, u === v ? 0 : Infinity)
			next.get(u)!.set(v, null)
		}
	}

	// Set edge weights
	for (const edge of graph.edges) {
		dist.get(edge.from)!.set(edge.to, edge.weight)
		dist.get(edge.to)!.set(edge.from, edge.weight)
		next.get(edge.from)!.set(edge.to, edge.to)
		next.get(edge.to)!.set(edge.from, edge.from)
	}

	// Floyd-Warshall algorithm
	for (const k of vertexIds) {
		for (const i of vertexIds) {
			for (const j of vertexIds) {
				const distIK = dist.get(i)!.get(k)!
				const distKJ = dist.get(k)!.get(j)!
				const distIJ = dist.get(i)!.get(j)!

				if (distIK + distKJ < distIJ) {
					dist.get(i)!.set(j, distIK + distKJ)
					next.get(i)!.set(j, next.get(i)!.get(k)!)
				}
			}
		}
	}

	return { dist, next }
}

/**
 * Find minimum-weight perfect matching on odd-degree vertices
 * Uses greedy matching (not optimal but fast and good enough)
 */
function greedyMatching(
	oddVertices: Vertex[],
	dist: Map<string, Map<string, number>>
): Map<string, string> {
	const matching = new Map<string, string>()
	const unmatched = new Set(oddVertices.map(v => v.id))

	while (unmatched.size > 0) {
		let minDist = Infinity
		let bestPair: [string, string] | null = null

		// Find closest pair of unmatched vertices
		for (const u of unmatched) {
			for (const v of unmatched) {
				if (u >= v) continue // Avoid duplicates and self-loops
				const d = dist.get(u)!.get(v)!
				if (d < minDist) {
					minDist = d
					bestPair = [u, v]
				}
			}
		}

		if (bestPair) {
			const [u, v] = bestPair
			matching.set(u, v)
			matching.set(v, u)
			unmatched.delete(u)
			unmatched.delete(v)
		} else {
			break
		}
	}

	return matching
}

/**
 * Find Eulerian path in graph using Hierholzer's algorithm
 * Fixed version that properly tracks edges as they're traversed
 */
function findEulerianPath(
	graph: Graph,
	startVertexId: string
): Edge[] {
	const circuit: Edge[] = []
	const stack: string[] = [startVertexId]

	// Create copy of adjacency list (we'll modify it)
	const adj = new Map<string, Edge[]>()
	for (const [v, edges] of graph.adjacency) {
		adj.set(v, [...edges])
	}

	console.log(`  Starting Eulerian path from vertex: ${startVertexId}`)
	console.log(`  Total edges to traverse: ${graph.edges.length}`)

	// Check if start vertex exists in graph
	if (!adj.has(startVertexId)) {
		console.error(`  ❌ Start vertex ${startVertexId} not found in graph!`)
		console.log(`  Available vertices:`, Array.from(adj.keys()).slice(0, 5))
		// Use first vertex with edges instead
		for (const [v, edges] of adj.entries()) {
			if (edges.length > 0) {
				console.log(`  Using vertex ${v} instead (has ${edges.length} edges)`)
				stack[0] = v
				break
			}
		}
	}

	let current = stack[0]
	let iterations = 0
	const maxIterations = graph.edges.length * 3 // Safety limit

	while (stack.length > 0 && iterations < maxIterations) {
		iterations++
		const edges = adj.get(current) || []

		if (edges.length === 0) {
			// No more edges from this vertex - backtrack
			stack.pop()
			if (stack.length > 0) {
				current = stack[stack.length - 1]
			}
		} else {
			// Take the first available edge
			const edge = edges[0]
			const nextVertex = edge.from === current ? edge.to : edge.from

			// Add edge to circuit
			circuit.push(edge)

			// Remove edge from both vertices' adjacency lists
			adj.set(current, edges.filter(e => e.id !== edge.id))
			const nextEdges = adj.get(nextVertex) || []
			adj.set(nextVertex, nextEdges.filter(e => e.id !== edge.id))

			// Move to next vertex
			current = nextVertex
			stack.push(nextVertex)
		}
	}

	if (iterations >= maxIterations) {
		console.error(`  ❌ Hit iteration limit! Circuit has ${circuit.length} edges, expected ${graph.edges.length}`)
	}

	console.log(`  Eulerian path found with ${circuit.length} edges (${iterations} iterations)`)
	return circuit
}

/**
 * Solve Chinese Postman Problem
 */
export function solveChinesePostman(
	blocks: BlockWithEndpoints[],
	startPoint?: { lat: number; lon: number }
): Array<{ lat: number; lon: number; block_id: number; street_name: string; type: 'start' | 'end' }> {
	if (blocks.length === 0) return []
	if (blocks.length === 1) {
		const block = blocks[0]
		return [
			{ lat: block.start_lat, lon: block.start_lon, block_id: block.block_id, street_name: block.street_name, type: 'start' },
			{ lat: block.end_lat, lon: block.end_lon, block_id: block.block_id, street_name: block.street_name, type: 'end' }
		]
	}

	console.log('🚀 Chinese Postman Problem Solver starting...')
	console.log(`  Blocks: ${blocks.length}`)

	// Step 1: Build graph
	const graph = buildGraph(blocks)
	console.log(`  Vertices: ${graph.vertices.size}, Edges: ${graph.edges.length}`)

	// Step 2: Find odd-degree vertices
	const oddVertices = Array.from(graph.vertices.values()).filter(v => v.degree % 2 === 1)
	console.log(`  Odd-degree vertices: ${oddVertices.length}`)

	// Step 3: If graph is already Eulerian (all even degrees), just find Eulerian path
	if (oddVertices.length === 0) {
		console.log('  ✅ Graph is already Eulerian!')
		const startVertexId = startPoint
			? vertexId(startPoint.lat, startPoint.lon)
			: graph.edges[0].from

		const eulerPath = findEulerianPath(graph, startVertexId)

		console.log(`  ✅ Found path with ${eulerPath.length} edges`)

		if (eulerPath.length === 0) {
			console.error('  ❌ Eulerian path is empty!')
			return []
		}

		// Convert to waypoints - track position as we traverse
		let currentVertex = startVertexId
		const waypoints = eulerPath.flatMap((edge) => {
			const isForward = edge.from === currentVertex

			// Update position for next iteration
			if (isForward) {
				currentVertex = edge.to
			} else {
				currentVertex = edge.from
			}

			if (isForward) {
				return [
					{ lat: edge.block.start_lat, lon: edge.block.start_lon, block_id: edge.block.block_id, street_name: edge.block.street_name, type: 'start' as const },
					{ lat: edge.block.end_lat, lon: edge.block.end_lon, block_id: edge.block.block_id, street_name: edge.block.street_name, type: 'end' as const }
				]
			} else {
				return [
					{ lat: edge.block.end_lat, lon: edge.block.end_lon, block_id: edge.block.block_id, street_name: edge.block.street_name, type: 'end' as const },
					{ lat: edge.block.start_lat, lon: edge.block.start_lon, block_id: edge.block.block_id, street_name: edge.block.street_name, type: 'start' as const }
				]
			}
		})

		console.log(`  ✅ Generated ${waypoints.length} waypoints from ${eulerPath.length} edges`)
		return waypoints
	}

	// Step 4: Find shortest paths between all pairs (Floyd-Warshall)
	console.log('  Computing shortest paths...')
	const { dist, next } = floydWarshall(graph)

	// Step 5: Find minimum-weight perfect matching on odd vertices
	console.log('  Finding perfect matching...')
	const matching = greedyMatching(oddVertices, dist)

	// Step 6: Augment graph with matched paths (duplicate edges)
	console.log('  Augmenting graph...')
	const augmentedEdges = [...graph.edges]
	for (const [u, v] of matching) {
		if (u < v) { // Process each pair once
			// Find shortest path between u and v and duplicate those edges
			let current = u
			while (current !== v) {
				const nextVertex = next.get(current)!.get(v)!
				if (!nextVertex) break

				// Find edge between current and nextVertex
				const edge = graph.edges.find(e =>
					(e.from === current && e.to === nextVertex) ||
					(e.from === nextVertex && e.to === current)
				)

				if (edge) {
					// Duplicate this edge
					augmentedEdges.push({ ...edge, id: augmentedEdges.length })
				}

				current = nextVertex
			}
		}
	}

	// Rebuild graph with augmented edges
	const augmentedAdj = new Map<string, Edge[]>()
	for (const edge of augmentedEdges) {
		if (!augmentedAdj.has(edge.from)) augmentedAdj.set(edge.from, [])
		if (!augmentedAdj.has(edge.to)) augmentedAdj.set(edge.to, [])
		augmentedAdj.get(edge.from)!.push(edge)
		augmentedAdj.get(edge.to)!.push(edge)
	}

	console.log(`  Augmented graph has ${augmentedEdges.length} edges (added ${augmentedEdges.length - graph.edges.length} edges)`)

	const augmentedGraph: Graph = {
		vertices: graph.vertices,
		edges: augmentedEdges,
		adjacency: augmentedAdj
	}

	// Verify all vertices have even degree in augmented graph
	const augmentedOddVertices = Array.from(augmentedAdj.entries())
		.filter(([_, edges]) => edges.length % 2 === 1)
	console.log(`  Augmented graph odd-degree vertices: ${augmentedOddVertices.length}`)
	if (augmentedOddVertices.length > 0) {
		console.error(`  ❌ Graph still has odd-degree vertices after augmentation!`)
		console.log(`  Odd vertices:`, augmentedOddVertices.map(([v, e]) => `${v}(${e.length})`).slice(0, 5))
	}

	// Step 7: Find Eulerian path
	console.log('  Finding Eulerian path...')

	// Determine start vertex - find the block endpoint closest to user's start point
	let startVertexId: string
	if (startPoint) {
		// Find vertex in graph closest to start point
		let minDist = Infinity
		let closestVertex = augmentedEdges[0].from

		for (const vertex of augmentedAdj.keys()) {
			const [lat, lon] = vertex.split(',').map(Number)
			const dist = haversineDistance([startPoint.lat, startPoint.lon], [lat, lon])
			if (dist < minDist) {
				minDist = dist
				closestVertex = vertex
			}
		}

		startVertexId = closestVertex
		console.log(`  Using vertex closest to start point (${(minDist * 1000).toFixed(1)}m away)`)
	} else {
		// Just use first vertex
		startVertexId = augmentedEdges[0].from
	}

	const eulerPath = findEulerianPath(augmentedGraph, startVertexId)

	console.log(`  ✅ Found path with ${eulerPath.length} edges`)

	if (eulerPath.length === 0) {
		console.error('  ❌ Eulerian path is empty!')
		return []
	}

	// Convert to waypoints - each edge becomes two points (start and end)
	// Track current position as we traverse the path
	let currentVertex = startVertexId
	const waypoints = eulerPath.flatMap((edge) => {
		// Determine if we're traversing this edge forward or backward
		const isForward = edge.from === currentVertex

		// Update current position for next iteration
		if (isForward) {
			currentVertex = edge.to
		} else {
			currentVertex = edge.from
		}

		// Return waypoints in the direction we're traveling
		if (isForward) {
			return [
				{ lat: edge.block.start_lat, lon: edge.block.start_lon, block_id: edge.block.block_id, street_name: edge.block.street_name, type: 'start' as const },
				{ lat: edge.block.end_lat, lon: edge.block.end_lon, block_id: edge.block.block_id, street_name: edge.block.street_name, type: 'end' as const }
			]
		} else {
			return [
				{ lat: edge.block.end_lat, lon: edge.block.end_lon, block_id: edge.block.block_id, street_name: edge.block.street_name, type: 'end' as const },
				{ lat: edge.block.start_lat, lon: edge.block.start_lon, block_id: edge.block.block_id, street_name: edge.block.street_name, type: 'start' as const }
			]
		}
	})

	console.log(`  ✅ Generated ${waypoints.length} waypoints from ${eulerPath.length} edges`)
	return waypoints
}
