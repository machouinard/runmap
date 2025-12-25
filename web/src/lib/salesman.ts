/**
 * salesman.ts - TypeScript port of salesman.js
 *
 * Good heuristic for the traveling salesman problem using simulated annealing.
 * Original: https://github.com/lovasoa/salesman.js
 * @author Ophir LOJKINE (original), converted to TypeScript
 */

export interface Point {
  x: number;
  y: number;
  [key: string]: any; // Allow additional properties
}

type DistanceFunction = (p: Point, q: Point) => number;
type ProgressCallback = (order: number[]) => void;

/**
 * Represents a path between points.
 * Includes an internal order for those points,
 * along with an array which maintains a record of distances between points.
 */
class Path {
  points: Point[];
  distanceFunc: DistanceFunction;
  keepEnd: boolean;
  order: number[];
  distances: number[][];

  constructor(points: Point[], distanceFunc: DistanceFunction, keepEnd: boolean) {
    this.points = points;
    this.distanceFunc = distanceFunc;
    this.keepEnd = keepEnd;
    this.order = [];
    this.distances = [];
    this.initializeOrder();
    this.initializeDistances();
  }

  /**
   * Creates the default order for the points.
   */
  initializeOrder(): void {
    this.order = [];
    for (let i = 0; i < this.points.length; i++) {
      this.order.push(i);
    }
  }

  /**
   * Creates a distances matrix for the points.
   */
  initializeDistances(): void {
    this.distances = [];
    for (let i = 0; i < this.points.length; i++) {
      const distancesFromI: number[] = [];
      for (let j = 0; j < this.points.length; j++) {
        distancesFromI.push(
          this.distanceFunc(this.points[i], this.points[j])
        );
      }
      this.distances.push(distancesFromI);
    }
  }

  /**
   * Accesses a point by index in the current order.
   */
  access(i: number): Point {
    return this.points[this.order[i]];
  }

  /**
   * Gets the distance between two points in the current order.
   */
  distance(i: number, j: number): number {
    return this.distances[this.order[i]][this.order[j]];
  }

  /**
   * Performs a single mutation on the path.
   * Changes the path to a neighboring solution.
   */
  change(temperature: number): void {
    const i = this.randomPos();
    const j = this.randomPos();
    const delta = this.delta_distance(i, j);

    if (delta < 0 || Math.random() < Math.exp(-delta / temperature)) {
      this.swap(i, j);
    }
  }

  /**
   * Swaps two positions in the order.
   */
  swap(i: number, j: number): void {
    const ipos = 1 + i;
    const jpos = 1 + j;
    const tmp = this.order[jpos];
    this.order[jpos] = this.order[ipos];
    this.order[ipos] = tmp;
  }

  /**
   * Calculates the change in path distance if two positions were swapped.
   */
  delta_distance(i: number, j: number): number {
    const jpos = 1 + j;
    const ipos = 1 + i;
    const iposplus = ipos + 1;
    const jposplus = jpos + 1;

    let d =
      // Distance from before i to after i
      (this.distance(ipos - 1, iposplus) - this.distance(ipos - 1, ipos)) +
      // Distance from before i to after j
      (this.distance(ipos - 1, jpos) - this.distance(ipos - 1, jposplus)) +
      // Distance from after j to before i
      (this.distance(jpos, iposplus) - this.distance(ipos, iposplus));

    if (jposplus < this.points.length) {
      d += this.distance(ipos, jposplus) - this.distance(jpos, jposplus);
    }

    return d;
  }

  /**
   * Returns a random position in the path (excluding start and possibly end).
   */
  randomPos(): number {
    const exclude = this.keepEnd ? 2 : 1;
    return Math.floor(Math.random() * (this.points.length - exclude));
  }

  /**
   * Calculates the total distance of the current path.
   */
  getPathDistance(): number {
    let distance = 0;
    for (let i = 0; i < this.points.length - 1; i++) {
      distance += this.distance(i, i + 1);
    }
    return distance;
  }
}

/**
 * Solves the TSP using simulated annealing.
 *
 * @param points Array of points with x, y coordinates
 * @param temp_coeff Temperature coefficient (0.99-0.9999). Higher = better but slower. Default: 0.999
 * @param callback Optional progress callback
 * @param distanceFunc Custom distance function. Default: Euclidean distance
 * @param keepEnd If true, keeps the last point fixed (for round-trip from first to last). Default: false
 * @returns Array of indices representing the optimal order to visit points
 */
export function solve(
  points: Point[],
  temp_coeff: number = 0.999,
  callback?: ProgressCallback,
  distanceFunc?: DistanceFunction,
  keepEnd: boolean = false
): number[] {
  const hasCallback = typeof callback === "function";
  const dist = distanceFunc || euclidean;

  const path = new Path(points, dist, keepEnd);

  if (points.length < 2) return path.order; // No optimization needed

  // Calculate initial temperature based on first two points
  let temperature = 100 * dist(path.access(0), path.access(1));

  // Simulated annealing loop
  while (temperature > 1e-6) {
    path.change(temperature);
    if (hasCallback) callback!(path.order);
    temperature *= temp_coeff;
  }

  return path.order;
}

/**
 * A simple Euclidean distance function.
 */
function euclidean(p: Point, q: Point): number {
  const dx = p.x - q.x;
  const dy = p.y - q.y;
  return Math.sqrt(dx * dx + dy * dy);
}

export default { solve };
