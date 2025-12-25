export interface BaseMap {
  name: string;
  tiles: string[];
  attribution: string;
}

export interface LayerVisibility {
  runs: boolean;
  complete: boolean;
  incomplete: boolean;
}

export interface MapPosition {
  center: [number, number];
  zoom: number;
}

export interface CoverageStats {
  coverage_pct: number;
  block_completion_pct: number;
  complete_blocks: number;
  total_blocks: number;
  completion_threshold_pct: number;
  total_length_km: number;  // Received from API in km
  covered_length_km: number; // Received from API in km
}

export type DateFilterPreset =
  | 'all'
  | 'this-month'
  | 'last-month'
  | 'last-3-months'
  | 'last-6-months'
  | 'last-9-months'
  | 'last-12-months';

export interface DateFilterState {
  preset: DateFilterPreset;
  startDate: Date | null;
  endDate: Date | null;
}

export type DistanceFilterPreset =
  | 'all'
  | 'short'      // < 5 km (3.1 mi)
  | 'medium'     // 5-10 km (3.1-6.2 mi)
  | 'long'       // 10-15 km (6.2-9.3 mi)
  | 'very-long'; // > 15 km (9.3+ mi)

export interface DistanceFilterState {
  preset: DistanceFilterPreset;
  minDistance: number | null; // in meters
  maxDistance: number | null; // in meters
}

export interface ApiHealthResponse {
  status: string;
}

export interface ApiStatsResponse {
  total_runs: number;
  total_km: number;
  coverage: CoverageStats;
}

export const BASE_MAPS: Record<string, BaseMap> = {
  osm: {
    name: 'OpenStreetMap',
    tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
    attribution: '© OpenStreetMap contributors'
  },
  satellite: {
    name: 'Satellite',
    tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
    attribution: '© ESRI'
  },
  humanitarian: {
    name: 'Humanitarian',
    tiles: ['https://tile-a.openstreetmap.fr/hot/{z}/{x}/{y}.png'],
    attribution: '© OpenStreetMap, HOT'
  },
  voyager: {
    name: 'Voyager',
    tiles: ['https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png'],
    attribution: '© OpenStreetMap, © CARTO'
  },
  terrain: {
    name: 'Terrain',
    tiles: ['https://tile.opentopomap.org/{z}/{x}/{y}.png'],
    attribution: '© OpenStreetMap, © OpenTopoMap'
  },
  toner: {
    name: 'Toner Lite',
    tiles: ['/api/tiles/stadia/{z}/{x}/{y}.png'],
    attribution: '© Stamen Design, © OpenStreetMap'
  }
};
