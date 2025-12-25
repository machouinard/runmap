import { X, Calendar, MapPin, Ruler, Trash2 } from 'lucide-react'
import type { PlannedRoute } from '@/lib/gpxParser'

interface RouteInfoModalProps {
  route: PlannedRoute
  onClose: () => void
  onClearRoute?: () => void
}

function formatDuration(totalSeconds: number): string {
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  // const seconds = totalSeconds % 60;

  // Use padStart to ensure two digits with leading zeros
  const formattedHours = String(hours).padStart(2, '0');
  const formattedMinutes = String(minutes).padStart(2, '0');
  // const formattedSeconds = String(seconds).padStart(2, '0');

  return `${formattedHours}:${formattedMinutes}`;
}

export function RouteInfoModal({ route, onClose, onClearRoute }: RouteInfoModalProps) {
  // Only show for activity routes, not file uploads
  if (route.source.type !== 'activity') {
    return null
  }

  const { startTime, distanceM, location, duration_seconds, activityType } = route.source

  return (
    <div className="absolute bottom-20 left-4 right-4 md:bottom-auto md:top-4 md:left-auto md:right-4 bg-white rounded-lg shadow-lg border border-gray-200 p-3 z-10 md:min-w-[200px] md:max-w-[280px]">
      <div className="flex items-start justify-between gap-2 mb-2">
        <a
          href="#activities"
          className="text-sm font-semibold text-purple-700 hover:text-purple-900 capitalize flex items-center gap-1 transition-colors"
          title="View in Activity Dashboard"
        >
          <MapPin className="w-4 h-4" />
          {activityType} Route
        </a>
        <button
          onClick={onClose}
          className="text-gray-400 hover:text-gray-600 p-1 -m-1"
          title="Hide info"
        >
          <X className="w-5 h-5 md:w-4 md:h-4" />
        </button>
      </div>

      <div className="space-y-1.5 text-xs text-gray-700">
        {startTime && (
          <div className="flex items-center gap-1.5">
            <Calendar className="w-3.5 h-3.5 text-gray-400" />
            <span>{new Date(startTime).toLocaleDateString('en-US', {
              month: 'short',
              day: 'numeric',
              year: 'numeric'
            })} {new Date(startTime).toLocaleTimeString('en-US', {
              hour: '2-digit',
              minute: '2-digit',
              hour12: true
            })}</span>
          </div>
        )}

        {distanceM && (
          <div className="flex items-center gap-1.5">
            <Ruler className="w-3.5 h-3.5 text-gray-400" />
            <span>{(distanceM / 1609.34).toFixed(2)} miles</span>
            {duration_seconds && (
              <span>{formatDuration(duration_seconds)}</span>
            )}
          </div>
        )}

        {location && (
          <div className="text-gray-500 capitalize">
            {location}
          </div>
        )}
      </div>

      {onClearRoute && (
        <button
          onClick={onClearRoute}
          className="mt-3 w-full px-3 py-1.5 bg-red-600 hover:bg-red-700 text-white rounded text-xs font-medium transition-colors flex items-center justify-center gap-1.5"
        >
          <Trash2 className="w-3 h-3" />
          Clear Route
        </button>
      )}
    </div>
  )
}
