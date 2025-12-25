import { useState } from 'react';
import { Upload, MapPin, Download, Loader, X, CheckCircle, XCircle } from 'lucide-react';

interface RouteGenProps {
  onRoutePreview?: (geojson: GeoJSON.Feature, bounds: {min_lng: number, min_lat: number, max_lng: number, max_lat: number}) => void;
  onClose?: () => void;
}

type Status = 'idle' | 'uploading' | 'previewing' | 'converting' | 'success' | 'error';

interface PreviewResponse {
  status: 'success';
  temp_path: string;
  filename: string;
  geojson: GeoJSON.Feature;
  bounds: {
    min_lng: number;
    min_lat: number;
    max_lng: number;
    max_lat: number;
  };
}

export function RouteGen({ onRoutePreview, onClose }: RouteGenProps) {
  const [status, setStatus] = useState<Status>('idle');
  const [message, setMessage] = useState<string>('');
  const [isDragging, setIsDragging] = useState(false);
  const [previewData, setPreviewData] = useState<PreviewResponse | null>(null);
  const [resampleDistance, setResampleDistance] = useState(30);

  const handleFileUpload = async (file: File) => {
    if (!file.name.endsWith('.gpx')) {
      setStatus('error');
      setMessage('Please select a .gpx file');
      return;
    }

    setStatus('uploading');
    setMessage('Uploading and parsing GPX...');

    const formData = new FormData();
    formData.append('file', file);

    try {
      const response = await fetch('/api/routegen/preview', {
        method: 'POST',
        body: formData,
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Upload failed');
      }

      const result: PreviewResponse = await response.json();

      setPreviewData(result);
      setStatus('previewing');

      // Type guard to safely access coordinates
      const pointCount = result.geojson.geometry.type === 'LineString'
        ? result.geojson.geometry.coordinates.length
        : 0;
      setMessage(`Preview: ${result.filename} (${pointCount} points)`);

      // Show route on map
      if (onRoutePreview) {
        onRoutePreview(result.geojson, result.bounds);
      }

    } catch (error) {
      setStatus('error');
      setMessage(`Error: ${error instanceof Error ? error.message : 'Upload failed'}`);
      setTimeout(() => {
        setStatus('idle');
        setMessage('');
      }, 5000);
    }
  };

  const handleConvert = async () => {
    if (!previewData) return;

    setStatus('converting');
    setMessage('Generating turn-by-turn directions...');

    try {
      const response = await fetch('/api/routegen/convert', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          temp_path: previewData.temp_path,
          format: 'gpx',
          resample_distance: resampleDistance,
        }),
      });

      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Conversion failed');
      }

      // Download the GPX file
      const blob = await response.blob();
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${previewData.filename.replace('.gpx', '')}-turns.gpx`;
      document.body.appendChild(a);
      a.click();
      window.URL.revokeObjectURL(url);
      document.body.removeChild(a);

      setStatus('success');
      setMessage('Turn-by-turn GPX downloaded successfully!');

      // Reset after 3 seconds
      setTimeout(() => {
        setStatus('idle');
        setMessage('');
        setPreviewData(null);
      }, 3000);

    } catch (error) {
      setStatus('error');
      setMessage(`Error: ${error instanceof Error ? error.message : 'Conversion failed'}`);
      setTimeout(() => {
        setStatus('previewing');
        setMessage(`Preview: ${previewData.filename}`);
      }, 5000);
    }
  };

  const handleFileSelect = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) {
      handleFileUpload(file);
    }
    event.target.value = '';
  };

  const handleDragOver = (event: React.DragEvent) => {
    event.preventDefault();
    setIsDragging(true);
  };

  const handleDragLeave = () => {
    setIsDragging(false);
  };

  const handleDrop = (event: React.DragEvent) => {
    event.preventDefault();
    setIsDragging(false);

    const file = event.dataTransfer.files?.[0];
    if (file) {
      handleFileUpload(file);
    }
  };

  const handleReset = () => {
    setStatus('idle');
    setMessage('');
    setPreviewData(null);
    if (onRoutePreview) {
      // Clear the map overlay by passing null
      onRoutePreview(null as any, null as any);
    }
  };

  const getStatusIcon = () => {
    switch (status) {
      case 'uploading':
      case 'converting':
        return <Loader className="w-5 h-5 animate-spin" />;
      case 'previewing':
        return <MapPin className="w-5 h-5 text-blue-600" />;
      case 'success':
        return <CheckCircle className="w-5 h-5 text-green-600" />;
      case 'error':
        return <XCircle className="w-5 h-5 text-red-600" />;
      default:
        return <Upload className="w-5 h-5" />;
    }
  };

  const getStatusColor = () => {
    switch (status) {
      case 'uploading':
      case 'converting':
        return 'bg-blue-50 border-blue-300 text-blue-700';
      case 'previewing':
        return 'bg-blue-50 border-blue-400 text-blue-800';
      case 'success':
        return 'bg-green-50 border-green-300 text-green-700';
      case 'error':
        return 'bg-red-50 border-red-300 text-red-700';
      default:
        return isDragging
          ? 'bg-blue-50 border-blue-400 text-blue-700'
          : 'bg-gray-50 border-gray-300 text-gray-700 hover:bg-gray-100';
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2 text-sm font-semibold text-gray-700">
          <MapPin className="w-4 h-4" />
          <span>Turn-by-Turn Generator</span>
        </div>
        {onClose && (
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-gray-600"
            aria-label="Close"
          >
            <X className="w-4 h-4" />
          </button>
        )}
      </div>

      {/* Upload/Preview Area */}
      <div
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        onDrop={handleDrop}
        className={`border-2 border-dashed rounded-lg p-4 transition-colors ${getStatusColor()}`}
      >
        {status === 'idle' && (
          <>
            <input
              type="file"
              accept=".gpx"
              onChange={handleFileSelect}
              className="hidden"
              id="routegen-upload"
            />
            <label
              htmlFor="routegen-upload"
              className="cursor-pointer flex flex-col items-center gap-3"
            >
              {getStatusIcon()}
              <div className="text-center">
                <div className="text-sm font-medium">
                  {isDragging ? 'Drop GPX file here' : 'Upload GPX to preview route'}
                </div>
                <div className="text-xs text-gray-500 mt-1">
                  Click to browse or drag & drop
                </div>
              </div>
            </label>
          </>
        )}

        {(status === 'uploading' || status === 'converting') && (
          <div className="flex flex-col items-center gap-3">
            {getStatusIcon()}
            <div className="text-sm font-medium text-center">{message}</div>
          </div>
        )}

        {status === 'previewing' && previewData && (
          <div className="space-y-4">
            <div className="flex items-center gap-2">
              {getStatusIcon()}
              <div className="text-sm font-medium">{message}</div>
            </div>

            <div className="space-y-3">
              {/* Resample Distance Control */}
              <div>
                <label className="block text-xs font-medium text-gray-700 mb-1">
                  Waypoint Spacing: {resampleDistance}m
                </label>
                <input
                  type="range"
                  min="10"
                  max="100"
                  step="5"
                  value={resampleDistance}
                  onChange={(e) => setResampleDistance(Number(e.target.value))}
                  className="w-full"
                />
                <div className="text-xs text-gray-500 mt-1">
                  Lower = more waypoints & turn prompts
                </div>
              </div>

              {/* Action Buttons */}
              <div className="flex gap-2">
                <button
                  onClick={handleConvert}
                  className="flex-1 flex items-center justify-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors text-sm font-medium"
                >
                  <Download className="w-4 h-4" />
                  Generate Turn-by-Turn
                </button>
                <button
                  onClick={handleReset}
                  className="px-4 py-2 bg-gray-200 text-gray-700 rounded-lg hover:bg-gray-300 transition-colors text-sm font-medium"
                >
                  Clear
                </button>
              </div>
            </div>
          </div>
        )}

        {status === 'success' && (
          <div className="flex flex-col items-center gap-3">
            {getStatusIcon()}
            <div className="text-sm font-medium text-center">{message}</div>
          </div>
        )}

        {status === 'error' && (
          <div className="flex flex-col items-center gap-3">
            {getStatusIcon()}
            <div className="text-sm font-medium text-center">{message}</div>
            <button
              onClick={handleReset}
              className="text-xs text-red-600 hover:text-red-700 underline"
            >
              Try again
            </button>
          </div>
        )}
      </div>

      {/* Info Box */}
      <div className="bg-blue-50 border border-blue-200 rounded-lg p-3 text-xs text-blue-800">
        <div className="font-semibold mb-1">How it works:</div>
        <ol className="list-decimal list-inside space-y-1 text-blue-700">
          <li>Upload your GPX track to preview it on the map</li>
          <li>Adjust waypoint spacing (controls turn frequency)</li>
          <li>Generate turn-by-turn directions via GraphHopper</li>
          <li>Download the GPX file with navigation waypoints</li>
        </ol>
      </div>
    </div>
  );
}
