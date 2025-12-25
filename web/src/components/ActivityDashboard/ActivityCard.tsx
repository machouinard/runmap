import { RefreshCw, Trash2, Edit3, MapPin, ChevronDown, MoreVertical } from 'lucide-react'
import { Activity } from './types'
import {
  formatDistance,
  formatDuration,
  formatSpeed,
  getLocationBadgeColor,
  getTypeBadgeColor,
  getStatusBadgeColor
} from './utils'
import { useAuth } from '@/contexts/AuthContext'

interface ActivityCardProps {
  activity: Activity
  expandedRow: string | null
  setExpandedRow: (id: string | null) => void
  actionMenuOpen: string | null
  setActionMenuOpen: (id: string | null) => void
  reclassifyMenuOpen: string | null
  setReclassifyMenuOpen: (id: string | null) => void
  overlayingId: string | null
  deletingId: string | null
  onOverlayActivity?: (activityId: string, activityType: 'run' | 'walk' | 'cycling') => void
  setOverlayingId: (id: string | null) => void
  handleReclassify: (activity: Activity, newType: 'run' | 'walk' | 'cycling') => void
  handleDelete: (activity: Activity) => void
  handleRetry: (activity: Activity) => void
}

export function ActivityCard({
  activity,
  expandedRow,
  setExpandedRow,
  actionMenuOpen,
  setActionMenuOpen,
  reclassifyMenuOpen,
  setReclassifyMenuOpen,
  overlayingId,
  deletingId,
  onOverlayActivity,
  setOverlayingId,
  handleReclassify,
  handleDelete,
  handleRetry
}: ActivityCardProps) {
  const { isAdmin } = useAuth();
  return (
    <div className="bg-white rounded-lg shadow overflow-hidden" data-action-menu={activity.id}>
      {/* Card Header */}
      <div className="p-4 border-b border-gray-100">
        <div className="flex items-start justify-between mb-2">
          <div className="flex-1 min-w-0">
            <div className="flex flex-col text-md font-medium text-gray-900 truncate">
              <span>{activity.route_name}</span>
              <span className="text-sm">{new Date(activity.start_time).toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })}</span>
              <span className="text-sm">{new Date(activity.start_time).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })}</span>
            </div>
          </div>
          <div className="flex items-center gap-1">
            {onOverlayActivity && (
              <button
                onClick={async () => {
                  setOverlayingId(activity.id)
                  await onOverlayActivity(activity.id, activity.activity_type)
                  setOverlayingId(null)
                }}
                disabled={overlayingId === activity.id}
                className="p-2 hover:bg-purple-100 rounded-full min-w-[44px] min-h-[44px] flex items-center justify-center disabled:opacity-50"
                title="Overlay on Map"
              >
                Map&nbsp;
                {overlayingId === activity.id ? (
                  <RefreshCw className="w-6 h-6 text-purple-600 animate-spin" />
                ) : (
                  <MapPin className="w-6 h-6 text-purple-600" />
                )}
              </button>
            )}
            {isAdmin && (
              <button
                onClick={() => setActionMenuOpen(actionMenuOpen === activity.id ? null : activity.id)}
                className="p-2 hover:bg-gray-100 rounded-full min-w-[44px] min-h-[44px] flex items-center justify-center"
              >
                <MoreVertical className="w-5 h-5 text-gray-600" />
              </button>
            )}
          </div>
        </div>

        {/* Badges */}
        <div className="flex flex-wrap gap-2">
          <span className={`px-2 py-1 text-xs font-medium rounded ${getLocationBadgeColor(activity.location)}`}>
            {activity.location}
          </span>
          <span className={`px-2 py-1 text-xs font-medium rounded ${getTypeBadgeColor(activity.activity_type)}`}>
            {activity.activity_type}
          </span>
          {activity.processing_status && (
            <span className={`px-2 py-1 text-xs font-medium rounded ${getStatusBadgeColor(activity.processing_status)}`}>
              {activity.processing_status}
            </span>
          )}
        </div>
      </div>

      {/* Card Stats */}
      <div className="grid grid-cols-3 gap-3 p-4 bg-gray-50">
        <div>
          <div className="text-xs text-gray-600">Distance</div>
          <div className="text-sm font-semibold text-gray-900">{formatDistance(activity.total_distance_m)}</div>
        </div>
        <div>
          <div className="text-xs text-gray-600">Duration</div>
          <div className="text-sm font-semibold text-gray-900">{formatDuration(activity.duration_seconds)}</div>
        </div>
        <div>
          <div className="text-xs text-gray-600">Speed</div>
          <div className="text-sm font-semibold text-gray-900">{formatSpeed(activity.total_distance_m, activity.duration_seconds)}</div>
        </div>
      </div>

      {/* Action Menu - Slide down */}
      {isAdmin && actionMenuOpen === activity.id && (
        <div className="border-t border-gray-200 bg-white">
          <div className="p-2 space-y-1">
            <button
              onClick={() => {
                setExpandedRow(expandedRow === activity.id ? null : activity.id)
                setActionMenuOpen(null)
              }}
              className="w-full text-left px-4 py-3 text-sm hover:bg-gray-100 rounded flex items-center gap-2 min-h-[44px]"
            >
              <ChevronDown className="w-4 h-4" />
              {expandedRow === activity.id ? 'Hide Details' : 'View Details'}
            </button>

            <button
              onClick={() => {
                setActionMenuOpen(null)
                setReclassifyMenuOpen(activity.id)
              }}
              className="w-full text-left px-4 py-3 text-sm hover:bg-gray-100 rounded flex items-center gap-2 min-h-[44px]"
            >
              <Edit3 className="w-4 h-4" />
              Reclassify Activity
            </button>

            {activity.processing_status === 'failed' && (
              <button
                onClick={() => {
                  handleRetry(activity)
                  setActionMenuOpen(null)
                }}
                className="w-full text-left px-4 py-3 text-sm text-green-600 hover:bg-green-50 rounded flex items-center gap-2 min-h-[44px]"
              >
                <RefreshCw className="w-4 h-4" />
                Retry Processing
              </button>
            )}

            <button
              onClick={() => {
                handleDelete(activity)
                setActionMenuOpen(null)
              }}
              disabled={deletingId === activity.id}
              className="w-full text-left px-4 py-3 text-sm text-red-600 hover:bg-red-50 rounded flex items-center gap-2 min-h-[44px] disabled:opacity-50"
            >
              {deletingId === activity.id ? (
                <RefreshCw className="w-4 h-4 animate-spin" />
              ) : (
                <Trash2 className="w-4 h-4" />
              )}
              Delete Activity
            </button>
          </div>
        </div>
      )}

      {/* Reclassify Menu */}
      {reclassifyMenuOpen === activity.id && (
        <div className="border-t border-gray-200 bg-gray-50 p-2">
          <div className="text-xs font-medium text-gray-700 px-4 py-2">Change activity type to:</div>
          <div className="space-y-1">
            {activity.activity_type !== 'run' && (
              <button
                onClick={() => handleReclassify(activity, 'run')}
                className="w-full text-left px-4 py-3 text-sm hover:bg-white rounded min-h-[44px]"
              >
                Run
              </button>
            )}
            {activity.activity_type !== 'walk' && (
              <button
                onClick={() => handleReclassify(activity, 'walk')}
                className="w-full text-left px-4 py-3 text-sm hover:bg-white rounded min-h-[44px]"
              >
                Walk
              </button>
            )}
            {activity.activity_type !== 'cycling' && (
              <button
                onClick={() => handleReclassify(activity, 'cycling')}
                className="w-full text-left px-4 py-3 text-sm hover:bg-white rounded min-h-[44px]"
              >
                Cycling
              </button>
            )}
            <button
              onClick={() => setReclassifyMenuOpen(null)}
              className="w-full text-left px-4 py-3 text-sm text-gray-600 hover:bg-white rounded min-h-[44px]"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {/* Expanded Details */}
      {expandedRow === activity.id && (
        <div className="border-t border-gray-200 bg-gray-50 p-4">
          <div className="space-y-2 text-xs">
            <div className="flex justify-between">
              <span className="text-gray-600">ID:</span>
              <span className="font-mono text-gray-900 text-right break-all ml-2">{activity.id}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-600">Start Time:</span>
              <span className="text-gray-900">{new Date(activity.start_time).toLocaleString()}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-600">Uploaded:</span>
              <span className="text-gray-900">
                {activity.processing_completed_at
                  ? new Date(activity.processing_completed_at).toLocaleString()
                  : (activity.uploaded_at ? new Date(activity.uploaded_at).toLocaleString() : 'N/A')}
              </span>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
