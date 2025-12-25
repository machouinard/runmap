import type { LayerVisibility, MapPosition } from '@/types';

const STORAGE_KEYS = {
  BASE_MAP: 'baseMap',
  MAP_CENTER: 'mapCenter',
  MAP_ZOOM: 'mapZoom',
  LAYER_RUNS: 'layer-runs',
  LAYER_COMPLETE: 'layer-complete',
  LAYER_INCOMPLETE: 'layer-incomplete',
} as const;

export const storage = {
  // Base map
  getBaseMap: (): string => {
    return localStorage.getItem(STORAGE_KEYS.BASE_MAP) || 'osm';
  },

  setBaseMap: (baseMap: string): void => {
    localStorage.setItem(STORAGE_KEYS.BASE_MAP, baseMap);
  },

  // Map position
  getMapPosition: (): MapPosition => {
    const savedCenter = localStorage.getItem(STORAGE_KEYS.MAP_CENTER);
    const savedZoom = localStorage.getItem(STORAGE_KEYS.MAP_ZOOM);

    return {
      center: savedCenter ? JSON.parse(savedCenter) : [-121.45, 38.55],
      zoom: savedZoom ? parseFloat(savedZoom) : 12,
    };
  },

  setMapPosition: (center: [number, number], zoom: number): void => {
    localStorage.setItem(STORAGE_KEYS.MAP_CENTER, JSON.stringify(center));
    localStorage.setItem(STORAGE_KEYS.MAP_ZOOM, zoom.toString());
  },

  // Layer visibility
  getLayerVisibility: (): LayerVisibility => {
    return {
      runs: localStorage.getItem(STORAGE_KEYS.LAYER_RUNS) !== 'false',
      complete: localStorage.getItem(STORAGE_KEYS.LAYER_COMPLETE) !== 'false',
      incomplete: localStorage.getItem(STORAGE_KEYS.LAYER_INCOMPLETE) !== 'false',
    };
  },

  setLayerVisibility: (visibility: LayerVisibility): void => {
    localStorage.setItem(STORAGE_KEYS.LAYER_RUNS, String(visibility.runs));
    localStorage.setItem(STORAGE_KEYS.LAYER_COMPLETE, String(visibility.complete));
    localStorage.setItem(STORAGE_KEYS.LAYER_INCOMPLETE, String(visibility.incomplete));
  },
};
