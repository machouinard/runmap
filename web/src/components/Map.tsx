import { useEffect, useRef, useState, useMemo } from 'react';
import Map, { Layer, Source } from 'react-map-gl/maplibre';
import { Protocol } from 'pmtiles';
import maplibregl from 'maplibre-gl';
import type { LayerVisibility, MapPosition, DateFilterState, DistanceFilterState } from '@/types';
import type { CentroidPoint } from './UnrunSegmentPanel';
import type { PlannedRoute } from '@/lib/gpxParser';
import { storage } from '@/lib/storage';
import { PolygonSelector } from './PolygonSelector';
import { RouteInfoModal } from './RouteInfoModal';
import { COLOR_SCHEMES, DEFAULT_COLORS } from '@/lib/colorSchemes';

// Planned route color - easily changeable
const PLANNED_ROUTE_COLOR = '#DFFF00'; // Bright yellow

interface MapComponentProps {
  baseMap: string;
  baseMapTiles: string[];
  baseMapAttribution: string;
  layerVisibility: LayerVisibility;
  dateFilter: DateFilterState;
  distanceFilter: DistanceFilterState;
  onPositionChange: (center: [number, number], zoom: number) => void;
  flyTo?: { center: [number, number]; zoom: number } | { bounds: [[number, number], [number, number]] } | null;

  // Polygon selection props
  isPolygonSelectionActive?: boolean;
  onPolygonComplete?: (polygon: GeoJSON.Polygon) => void;
  onPolygonSelectionCancel?: () => void;
  centroids?: CentroidPoint[];

  // Route overlay (GPX uploads and Valhalla generated routes)
  plannedRoute?: PlannedRoute | null;
  showPlannedRoute?: boolean;
  onClearPlannedRoute?: () => void;
}

export function MapComponent({
  baseMap,
  baseMapTiles,
  baseMapAttribution,
  layerVisibility,
  dateFilter,
  distanceFilter,
  onPositionChange,
  flyTo,
  isPolygonSelectionActive = false,
  onPolygonComplete,
  onPolygonSelectionCancel,
  centroids = [],
  plannedRoute = null,
  showPlannedRoute = true,
  onClearPlannedRoute,
}: MapComponentProps) {
  const [viewState, setViewState] = useState<MapPosition>(() => storage.getMapPosition());
  const protocolInitialized = useRef(false);
  const mapRef = useRef<any>(null);
  const [showRouteInfo, setShowRouteInfo] = useState(true);
  const [isMapReady, setIsMapReady] = useState(false);

  // Compute colors based on selected base map
  const colors = useMemo(() => COLOR_SCHEMES[baseMap] || DEFAULT_COLORS, [baseMap]);

  // Reset route info modal visibility when route changes
  useEffect(() => {
    if (plannedRoute) {
      setShowRouteInfo(true);
    }
  }, [plannedRoute]);

  // Initialize PMTiles protocol once
  useEffect(() => {
    if (!protocolInitialized.current) {
      const protocol = new Protocol();
      maplibregl.addProtocol('pmtiles', protocol.tile);
      protocolInitialized.current = true;
    }

    return () => {
      if (protocolInitialized.current) {
        maplibregl.removeProtocol('pmtiles');
        protocolInitialized.current = false;
      }
    };
  }, []);

  // Handle external flyTo commands
  useEffect(() => {
    if (flyTo && mapRef.current && isMapReady) {
      if ('bounds' in flyTo) {
        // Fit to bounds
        mapRef.current.fitBounds(flyTo.bounds, {
          padding: 50,
          duration: 1500,
        });
      } else {
        // Fly to center/zoom
        mapRef.current.flyTo({
          center: flyTo.center,
          zoom: flyTo.zoom,
          duration: 1500,
        });
      }
    }
  }, [flyTo, isMapReady]);

  const handleMove = (evt: any) => {
    setViewState({
      center: [evt.viewState.longitude, evt.viewState.latitude],
      zoom: evt.viewState.zoom,
    });
    onPositionChange([evt.viewState.longitude, evt.viewState.latitude], evt.viewState.zoom);
  };

  // Create paint properties for runs layer based on date and distance filters
  const runsPaint = useMemo(() => {
    const noDateFilter = dateFilter.preset === 'all' || !dateFilter.startDate;
    const noDistanceFilter = distanceFilter.preset === 'all';

    // If no filters active, show all runs at normal opacity
    if (noDateFilter && noDistanceFilter) {
      return {
        'line-color': colors.runs,
        'line-width': 3,
        'line-opacity': 0.65,
      };
    }

    // Build filter conditions
    const conditions: any[] = [];

    // Date filter condition
    if (!noDateFilter) {
      const startTimeISO = dateFilter.startDate!.toISOString();
      const endTimeISO = dateFilter.endDate ? dateFilter.endDate.toISOString() : new Date().toISOString();
      conditions.push(['>=', ['get', 'start_time'], startTimeISO]);
      conditions.push(['<=', ['get', 'start_time'], endTimeISO]);
    }

    // Distance filter condition
    if (!noDistanceFilter) {
      if (distanceFilter.minDistance !== null) {
        conditions.push(['>=', ['get', 'total_distance_m'], distanceFilter.minDistance]);
      }
      if (distanceFilter.maxDistance !== null) {
        conditions.push(['<=', ['get', 'total_distance_m'], distanceFilter.maxDistance]);
      }
    }

    return {
      'line-color': colors.runs,
      'line-width': 3,
      'line-opacity': [
        'case',
        ['all', ...conditions],
        0.65, // Matching runs: full opacity
        0.0   // Non-matching runs: completely hidden
      ] as any,
    };
  }, [dateFilter, distanceFilter, colors.runs]);

  // Memoize mapStyle to prevent unnecessary re-renders
  const mapStyle = useMemo(() => ({
    version: 8 as const,
    sources: {
      basemap: {
        type: 'raster' as const,
        tiles: baseMapTiles,
        tileSize: 256,
        attribution: baseMapAttribution,
      },
      runs: {
        type: 'vector' as const,
        url: 'pmtiles:///tiles/runs.pmtiles',
      },
      streets_incomplete: {
        type: 'vector' as const,
        url: 'pmtiles:///tiles/streets_incomplete.pmtiles',
      },
      streets_complete: {
        type: 'vector' as const,
        url: 'pmtiles:///tiles/streets_complete.pmtiles',
      },
    },
    layers: [
      {
        id: 'basemap',
        type: 'raster' as const,
        source: 'basemap',
      },
    ],
  }), [baseMapTiles, baseMapAttribution]);

  // Convert centroids to GeoJSON for map layer
  const centroidsGeoJSON = useMemo<GeoJSON.FeatureCollection>(() => {
    if (centroids.length === 0) {
      return {
        type: 'FeatureCollection',
        features: [],
      };
    }

    return {
      type: 'FeatureCollection',
      features: centroids.map((centroid) => ({
        type: 'Feature',
        geometry: {
          type: 'Point',
          coordinates: [centroid.lon, centroid.lat],
        },
        properties: {
          block_id: centroid.block_id,
          street_name: centroid.street_name,
        },
      })),
    };
  }, [centroids]);

  // Convert planned route to GeoJSON FeatureCollection
  const plannedRouteGeoJSON = useMemo<GeoJSON.FeatureCollection>(() => {
    if (!plannedRoute) {
      return {
        type: 'FeatureCollection',
        features: [],
      };
    }

    return {
      type: 'FeatureCollection',
      features: [plannedRoute.geojson],
    };
  }, [plannedRoute]);

  return (
    <Map
      ref={mapRef}
      {...viewState}
      longitude={viewState.center[0]}
      latitude={viewState.center[1]}
      onMove={handleMove}
      style={{ width: '100%', height: '100%' }}
      mapStyle={mapStyle}
      onLoad={(evt) => {
        // Mark map as ready for flyTo commands
        setIsMapReady(true);

        // Force attribution control to compact mode
        const map = evt.target;
        if (map._controls) {
          map._controls.forEach((control: any) => {
            if (control._compact !== undefined) {
              control._compact = true;
              control._updateCompact();
            }
          });
        }
      }}
    >
      {/* Incomplete streets layer */}
      <Source id="streets_incomplete" type="vector" url="pmtiles:///tiles/streets_incomplete.pmtiles">
        <Layer
          id="streets-incomplete"
          type="line"
          source-layer="streets_incomplete"
          paint={{
            'line-color': colors.incomplete,
            'line-width': 3,
          }}
          minzoom={10}
          layout={{
            visibility: layerVisibility.incomplete ? 'visible' : 'none',
          }}
        />
      </Source>

      {/* Complete streets layer */}
      <Source id="streets_complete" type="vector" url="pmtiles:///tiles/streets_complete.pmtiles">
        <Layer
          id="streets-complete"
          type="line"
          source-layer="streets_complete"
          paint={{
            'line-color': colors.complete,
            'line-width': 5,
            'line-opacity': 0.9,
          }}
          minzoom={10}
          layout={{
            visibility: layerVisibility.complete ? 'visible' : 'none',
          }}
        />
      </Source>

      {/* Runs layer */}
      <Source id="runs" type="vector" url="pmtiles:///tiles/runs.pmtiles">
        <Layer
          id="runs"
          type="line"
          source-layer="runs"
          paint={runsPaint}
          layout={{
            visibility: layerVisibility.runs ? 'visible' : 'none',
          }}
        />
      </Source>

      {/* Centroid points layer */}
      {centroids.length > 0 && (
        <Source id="centroids" type="geojson" data={centroidsGeoJSON}>
          <Layer
            id="centroids-circles"
            type="circle"
            paint={{
              'circle-radius': 6,
              'circle-color': '#ef4444',
              'circle-stroke-width': 2,
              'circle-stroke-color': '#fff',
            }}
          />
        </Source>
      )}

      {/* Planned route overlay layer (GPX) */}
      {plannedRoute && showPlannedRoute && (
        <Source id="planned-route" type="geojson" data={plannedRouteGeoJSON}>
          {/* Black border (casing) */}
          <Layer
            id="planned-route-border"
            type="line"
            paint={{
              'line-color': '#000000',
              'line-width': 8,
              'line-opacity': 1.0,
            }}
          />
          {/* Yellow dashed line */}
          <Layer
            id="planned-route-line"
            type="line"
            paint={{
              'line-color': PLANNED_ROUTE_COLOR,
              'line-width': 6,
              'line-opacity': 1.0,
            }}
          />
        </Source>
      )}

      {/* Polygon selector (only renders when active) */}
      {isPolygonSelectionActive && onPolygonComplete && onPolygonSelectionCancel && (
        <PolygonSelector
          mapRef={mapRef}
          isActive={isPolygonSelectionActive}
          onPolygonComplete={onPolygonComplete}
          onCancel={onPolygonSelectionCancel}
        />
      )}

      {/* Route info modal for activity overlays */}
      {plannedRoute && showPlannedRoute && showRouteInfo && (
        <RouteInfoModal
          route={plannedRoute}
          onClose={() => setShowRouteInfo(false)}
          onClearRoute={onClearPlannedRoute}
        />
      )}
    </Map>
  );
}
