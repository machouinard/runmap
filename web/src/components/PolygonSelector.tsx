import { useEffect, useRef } from 'react';
import MapboxDraw from '@mapbox/mapbox-gl-draw';
import '@mapbox/mapbox-gl-draw/dist/mapbox-gl-draw.css';
import type { MapRef } from 'react-map-gl/maplibre';

interface PolygonSelectorProps {
  mapRef: React.RefObject<MapRef>;
  isActive: boolean;
  onPolygonComplete: (polygon: GeoJSON.Polygon) => void;
  onCancel: () => void;
}

export function PolygonSelector({
  mapRef,
  isActive,
  onPolygonComplete,
  onCancel,
}: PolygonSelectorProps) {
  const drawRef = useRef<MapboxDraw | null>(null);

  useEffect(() => {
    if (!mapRef.current) return;

    const map = mapRef.current.getMap();

    // Initialize MapboxDraw
    const draw = new MapboxDraw({
      displayControlsDefault: false,
      controls: {
        polygon: true,
        trash: true,
      },
      styles: [
        // Polygon fill
        {
          id: 'gl-draw-polygon-fill',
          type: 'fill',
          filter: ['all', ['==', '$type', 'Polygon'], ['!=', 'mode', 'static']],
          paint: {
            'fill-color': '#3b82f6',
            'fill-opacity': 0.1,
          },
        },
        // Polygon outline
        {
          id: 'gl-draw-polygon-stroke-active',
          type: 'line',
          filter: ['all', ['==', '$type', 'Polygon'], ['!=', 'mode', 'static']],
          paint: {
            'line-color': '#3b82f6',
            'line-width': 3,
          },
        },
        // Vertex points
        {
          id: 'gl-draw-polygon-and-line-vertex-active',
          type: 'circle',
          filter: ['all', ['==', 'meta', 'vertex'], ['==', '$type', 'Point']],
          paint: {
            'circle-radius': 5,
            'circle-color': '#3b82f6',
            'circle-stroke-width': 2,
            'circle-stroke-color': '#fff',
          },
        },
        // Midpoint handles
        {
          id: 'gl-draw-polygon-midpoint',
          type: 'circle',
          filter: ['all', ['==', '$type', 'Point'], ['==', 'meta', 'midpoint']],
          paint: {
            'circle-radius': 3,
            'circle-color': '#3b82f6',
            'circle-opacity': 0.5,
          },
        },
      ],
    });

    // @ts-ignore - MapboxDraw works with MapLibre but types are incompatible
    map.addControl(draw);
    drawRef.current = draw;

    // Listen for polygon creation
    const onCreate = (e: any) => {
      if (e.features && e.features.length > 0) {
        const feature = e.features[0];
        if (feature.geometry.type === 'Polygon') {
          onPolygonComplete(feature.geometry);
          // Clear the drawn polygon
          draw.deleteAll();
        }
      }
    };

    map.on('draw.create', onCreate);

    // Cleanup
    return () => {
      if (drawRef.current) {
        map.off('draw.create', onCreate);
        // @ts-ignore - MapboxDraw works with MapLibre but types are incompatible
        map.removeControl(drawRef.current);
        drawRef.current = null;
      }
    };
  }, [mapRef, onPolygonComplete]);

  // Handle active state changes
  useEffect(() => {
    if (!drawRef.current) return;

    if (isActive) {
      // Enter drawing mode
      drawRef.current.changeMode('draw_polygon');
    } else {
      // Exit drawing mode, clear any in-progress drawings
      drawRef.current.deleteAll();
      drawRef.current.changeMode('simple_select');
    }
  }, [isActive]);

  // Handle ESC key to cancel
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && isActive) {
        onCancel();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isActive, onCancel]);

  return null; // This component doesn't render anything itself
}
