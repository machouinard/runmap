import { useState } from 'react';
import { Map, Eye, EyeOff, Trash2, Navigation, Target } from 'lucide-react';
import type { PlannedRoute } from '@/lib/gpxParser';

interface RouteOverlayProps {
  hasPlannedRoute: boolean;
  showPlannedRoute: boolean;
  plannedRoute: PlannedRoute | null;
  isAdmin: boolean;
  onGPXUpload: (event: React.ChangeEvent<HTMLInputElement>) => void;
  onTogglePlannedRoute: () => void;
  onClearPlannedRoute: () => void;
  onTogglePolygonSelection?: () => void;
  isPolygonSelectionActive?: boolean;
  onMobileClose?: () => void;
}

export function RouteOverlay({
  hasPlannedRoute,
  showPlannedRoute,
  plannedRoute,
  isAdmin,
  onGPXUpload,
  onTogglePlannedRoute,
  onClearPlannedRoute,
  onTogglePolygonSelection,
  isPolygonSelectionActive = false,
  onMobileClose,
}: RouteOverlayProps) {
  const [isGeneratingTurnByTurn, setIsGeneratingTurnByTurn] = useState(false);

  const handleGenerateTurnByTurn = async () => {
    if (!plannedRoute || !isAdmin) return;

    setIsGeneratingTurnByTurn(true);
    try {
      // Convert the GeoJSON back to GPX format
      const gpxContent = convertGeoJSONToGPX(plannedRoute.geojson);
      const blob = new Blob([gpxContent], { type: 'application/gpx+xml' });

      // Upload to preview endpoint
      const formData = new FormData();
      formData.append('file', blob, 'route.gpx');

      const previewResponse = await fetch('/api/routegen/preview', {
        method: 'POST',
        body: formData,
      });

      if (!previewResponse.ok) {
        const error = await previewResponse.json();
        throw new Error(error.error || 'Preview failed');
      }

      const previewData = await previewResponse.json();

      // Convert to turn-by-turn
      const convertResponse = await fetch('/api/routegen/convert', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          temp_path: previewData.temp_path,
          format: 'gpx',
          resample_distance: 30,
        }),
      });

      if (!convertResponse.ok) {
        const error = await convertResponse.json();
        throw new Error(error.error || 'Conversion failed');
      }

      // Download the file
      const gpxBlob = await convertResponse.blob();
      const url = window.URL.createObjectURL(gpxBlob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${plannedRoute.geojson.properties.name || 'route'}-turns.gpx`;
      document.body.appendChild(a);
      a.click();
      window.URL.revokeObjectURL(url);
      document.body.removeChild(a);

      alert('Turn-by-turn GPX downloaded successfully!');
    } catch (error) {
      console.error('Turn-by-turn generation failed:', error);
      alert(`Failed to generate turn-by-turn: ${error instanceof Error ? error.message : 'Unknown error'}`);
    } finally {
      setIsGeneratingTurnByTurn(false);
    }
  };

  // Helper function to convert GeoJSON to GPX
  const convertGeoJSONToGPX = (geojson: GeoJSON.Feature<GeoJSON.LineString>) => {
    const coords = geojson.geometry.coordinates;
    const name = geojson.properties?.name || 'Route';

    let gpx = `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="RunMap">
  <trk>
    <name>${name}</name>
    <trkseg>`;

    coords.forEach(([lon, lat]) => {
      gpx += `
      <trkpt lat="${lat}" lon="${lon}"></trkpt>`;
    });

    gpx += `
    </trkseg>
  </trk>
</gpx>`;

    return gpx;
  };

  return (
    <>
      {isAdmin && onTogglePolygonSelection && (
        <div className="border-t border-gray-200 pt-4">

          <button
            onClick={onTogglePolygonSelection}
            className={`w-full px-4 py-2 rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2 ${isPolygonSelectionActive
              ? 'bg-red-600 hover:bg-red-700 text-white'
              : 'bg-orange-600 hover:bg-orange-700 text-white'
              }`}
          >
            <Target className="w-4 h-4" />
            {isPolygonSelectionActive ? 'Cancel Selection' : 'Select Unrun Segments'}
          </button>
          {isPolygonSelectionActive && (
            <p className="text-xs text-gray-500 mt-2 text-center">
              Click to draw polygon, ESC to cancel
            </p>
          )}
        </div>
      )}

      <div className="border-t border-gray-200 pt-4">
        <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-3">
          Route Overlay
        </h3>
        <div className="space-y-2">
          {isAdmin && (
            <label className="w-full px-4 py-2 bg-purple-600 hover:bg-purple-700 text-white rounded-md text-sm font-medium transition-colors cursor-pointer flex items-center justify-center gap-2">
              <Map className="w-4 h-4" />
              Upload GPX Route
              <input
                type="file"
                accept=".gpx"
                onChange={onGPXUpload}
                className="hidden"
              />
            </label>
          )}
          {hasPlannedRoute && (
            <>
              <div className="flex gap-2">
                <button
                  onClick={onTogglePlannedRoute}
                  className="flex-1 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2"
                >
                  {showPlannedRoute ? (
                    <>
                      <EyeOff className="w-4 h-4" />
                      Hide Route
                    </>
                  ) : (
                    <>
                      <Eye className="w-4 h-4" />
                      Show Route
                    </>
                  )}
                </button>
                <button
                  onClick={() => {
                    onClearPlannedRoute();
                    onMobileClose?.();
                  }}
                  className="px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center"
                  title="Clear route and close"
                >
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
              {isAdmin && (
                <button
                  onClick={handleGenerateTurnByTurn}
                  disabled={isGeneratingTurnByTurn}
                  className="w-full px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-gray-400 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2"
                >
                  <Navigation className="w-4 h-4" />
                  {isGeneratingTurnByTurn ? 'Generating...' : 'Generate Turn-by-Turn'}
                </button>
              )}
            </>
          )}
          {hasPlannedRoute && plannedRoute ? (
            <div className="text-xs text-gray-600 bg-gray-50 p-3 rounded space-y-1">
              {plannedRoute.source.type === 'activity' ? (
                <> </>
              ) : (
                <>
                  <div className="font-semibold text-purple-700">Uploaded Route</div>
                  <div>Bright yellow overlay</div>
                </>
              )}
            </div>
          ) : (
            <p className="text-xs text-gray-500 text-center">
              Select a route to view the overlay
            </p>
          )}
        </div>
      </div>
    </>
  );
}
