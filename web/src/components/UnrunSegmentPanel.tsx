import { X, Download, MapPin, Eye, EyeOff, Navigation } from 'lucide-react';
import { useState } from 'react';

export interface CentroidPoint {
  block_id: number;
  street_name: string;
  lon: number;
  lat: number;
  total_unvisited_length_m: number;
  unvisited_segment_count: number;
  coverage_pct?: number;
  segment_ids?: number[];
}

export interface BlockData {
  block_id: number;
  street_name: string;
  start_lat: number;
  start_lon: number;
  end_lat: number;
  end_lon: number;
  centroid_lat: number;
  centroid_lon: number;
  total_unvisited_length_m: number;
  unvisited_segment_count: number;
  coverage_pct?: number;
  segment_ids?: number[];
}

interface UnrunSegmentPanelProps {
  centroids: CentroidPoint[];
  blocks?: BlockData[];
  areaKm2?: number;
  isLoading: boolean;
  onClose: () => void;
  onExportGeoJSON: () => void;
  onExportCSV: () => void;
  onGenerateRoute?: () => void;
  onExportRouteGPX?: () => void;
  coordinatesString?: string;
  routeGenerating?: boolean;
  routeInfo?: {
    distance_km: number;
    time_seconds: number;
    blocks_covered: number;
    blocks_total: number;
    coverage_pct: number;
  };
}

export function UnrunSegmentPanel({
  centroids,
  areaKm2,
  isLoading,
  onClose,
  onExportGeoJSON,
  onExportCSV,
  onGenerateRoute,
  onExportRouteGPX,
  coordinatesString,
  routeGenerating,
  routeInfo,
}: UnrunSegmentPanelProps) {
  const [showSegmentIds, setShowSegmentIds] = useState(false);

  // Group centroids by street name
  const groupedByStreet = centroids.reduce((acc, centroid) => {
    const street = centroid.street_name;
    if (!acc[street]) {
      acc[street] = [];
    }
    acc[street].push(centroid);
    return acc;
  }, {} as Record<string, CentroidPoint[]>);

  const streetNames = Object.keys(groupedByStreet).sort();

  return (
    <div className="absolute right-4 top-4 bottom-4 w-96 bg-white dark:bg-gray-800 rounded-lg shadow-xl border border-gray-200 dark:border-gray-700 flex flex-col overflow-hidden z-50">
      {/* Header */}
      <div className="p-4 border-b border-gray-200 dark:border-gray-700">
        <div className="flex items-center justify-between mb-2">
          <h2 className="text-lg font-semibold text-gray-900 dark:text-white">
            Unrun Segments
          </h2>
          <div className="flex items-center gap-2">
            <button
              onClick={() => setShowSegmentIds(!showSegmentIds)}
              className="h-8 px-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded transition-colors flex items-center gap-1 text-xs text-gray-600 dark:text-gray-400"
              title={showSegmentIds ? "Hide segment IDs" : "Show segment IDs"}
            >
              {showSegmentIds ? <EyeOff className="h-3 w-3" /> : <Eye className="h-3 w-3" />}
              IDs
            </button>
            <button
              onClick={onClose}
              className="h-8 w-8 p-0 hover:bg-gray-100 dark:hover:bg-gray-700 rounded transition-colors flex items-center justify-center text-gray-700 dark:text-gray-300"
              title="Close panel"
            >
              <X className="h-5 w-5" />
            </button>
          </div>
        </div>
        {!isLoading && (
          <p className="text-sm text-gray-500 dark:text-gray-400">
            {centroids.length > 0 ? (
              <>
                Found <span className="font-medium text-blue-600">{centroids.length}</span> unrun blocks
                <span className="text-gray-400"> ({centroids.length} waypoints)</span>
                {areaKm2 && (
                  <span className="ml-1">
                    in <span className="font-medium">{areaKm2.toFixed(2)} km²</span>
                  </span>
                )}
              </>
            ) : (
              'No unrun segments found'
            )}
          </p>
        )}
      </div>

      {/* Content */}
      {isLoading ? (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center">
            <div className="inline-block animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
            <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">
              Extracting unrun segments...
            </p>
          </div>
        </div>
      ) : centroids.length === 0 ? (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center px-4">
            <MapPin className="h-12 w-12 mx-auto text-gray-400 mb-3" />
            <p className="text-gray-600 dark:text-gray-400">
              This area is fully covered!
            </p>
            <p className="text-sm text-gray-500 dark:text-gray-500 mt-1">
              All segments in the selected area have been run.
            </p>
          </div>
        </div>
      ) : (
        <>
          {/* Scrollable list */}
          <div className="flex-1 overflow-y-auto p-4 space-y-3">
            {streetNames.map((streetName) => {
              const segments = groupedByStreet[streetName];
              return (
                <div key={streetName} className="space-y-1">
                  <h3 className="font-medium text-gray-900 dark:text-white text-sm">
                    {streetName}
                    <span className="ml-2 text-xs text-gray-500 dark:text-gray-400">
                      ({segments.length} {segments.length === 1 ? 'segment' : 'segments'})
                    </span>
                  </h3>
                  <div className="space-y-1">
                    {segments.map((centroid) => (
                      <div
                        key={centroid.block_id}
                        className="text-xs text-gray-600 dark:text-gray-400 pl-3 py-1 hover:bg-gray-50 dark:hover:bg-gray-700 rounded"
                      >
                        <span className="font-mono">
                          {centroid.lat.toFixed(6)}, {centroid.lon.toFixed(6)}
                        </span>
                        <span className="ml-2 text-gray-500">
                          ({centroid.total_unvisited_length_m.toFixed(0)}m unrun, {centroid.unvisited_segment_count} segs
                          {centroid.coverage_pct !== undefined && `, ${centroid.coverage_pct.toFixed(1)}% incomplete`})
                        </span>
                        {showSegmentIds && centroid.segment_ids && centroid.segment_ids.length > 0 && (
                          <div className="text-xs text-gray-400 pl-3 mt-1">
                            Segment IDs: {centroid.segment_ids.join(', ')}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              );
            })}
          </div>

          {/* Route Generation */}
          {onGenerateRoute && (
            <div className="px-4 pt-3 border-t border-gray-200 dark:border-gray-700">
              <button
                onClick={onGenerateRoute}
                disabled={routeGenerating || centroids.length === 0}
                className={`w-full px-4 py-2 rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2 ${routeGenerating
                    ? 'bg-gray-300 dark:bg-gray-600 cursor-not-allowed'
                    : 'bg-green-600 hover:bg-green-700 text-white'
                  }`}
              >
                <Navigation className="h-4 w-4" />
                {routeGenerating ? 'Generating Route...' : 'Generate Valhalla Route'}
              </button>

              {routeInfo && (
                <div className="mt-3 p-3 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-md space-y-1">
                  <div className="text-xs font-medium text-green-900 dark:text-green-300">
                    Route Generated
                  </div>
                  <div className="text-xs text-green-700 dark:text-green-400 space-y-0.5">
                    <div>
                      Distance: <span className="font-mono font-medium">{routeInfo.distance_km.toFixed(2)} km</span>
                      {' '}({(routeInfo.distance_km * 0.621371).toFixed(2)} mi)
                    </div>
                    <div>
                      Time: <span className="font-mono font-medium">
                        {Math.floor(routeInfo.time_seconds / 60)} min {routeInfo.time_seconds % 60} sec
                      </span>
                    </div>
                    <div>
                      Coverage: <span className="font-mono font-medium">
                        {routeInfo.blocks_covered}/{routeInfo.blocks_total} blocks
                      </span>
                      {' '}({routeInfo.coverage_pct.toFixed(1)}%)
                    </div>
                  </div>
                  {routeInfo.coverage_pct < 100 && (
                    <div className="mt-2 text-xs text-yellow-700 dark:text-yellow-400">
                      ⚠ Some blocks may not be fully covered. Consider adjusting your route.
                    </div>
                  )}
                  {onExportRouteGPX && (
                    <button
                      onClick={onExportRouteGPX}
                      className="mt-2 w-full px-3 py-2 bg-green-600 hover:bg-green-700 text-white rounded text-xs font-medium transition-colors flex items-center justify-center gap-2"
                    >
                      <Download className="h-3 w-3" />
                      Download Route GPX
                    </button>
                  )}
                </div>
              )}
            </div>
          )}

          {/* Coordinates for testing */}
          {coordinatesString && (
            <div className="px-4 pt-3 border-t border-gray-200 dark:border-gray-700">
              <label className="block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1">
                Raw coordinates (for scripts):
              </label>
              <div className="relative">
                <input
                  type="text"
                  value={coordinatesString}
                  readOnly
                  className="w-full px-2 py-1.5 text-xs font-mono bg-gray-50 dark:bg-gray-900 border border-gray-300 dark:border-gray-600 rounded text-gray-900 dark:text-gray-100"
                  onClick={(e) => {
                    e.currentTarget.select();
                    navigator.clipboard.writeText(coordinatesString);
                  }}
                />
              </div>
              <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                Click to copy • Space-separated lat,lon pairs
              </p>
            </div>
          )}

          {/* Action buttons */}
          <div className="p-4 border-t border-gray-200 dark:border-gray-700 space-y-2">
            <button
              onClick={onExportGeoJSON}
              className="w-full px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2"
            >
              <Download className="h-4 w-4" />
              Download GeoJSON
            </button>
            <button
              onClick={onExportCSV}
              className="w-full px-4 py-2 bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-900 dark:text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2 border border-gray-300 dark:border-gray-600"
            >
              <Download className="h-4 w-4" />
              Download CSV
            </button>
          </div>
        </>
      )}
    </div>
  );
}
