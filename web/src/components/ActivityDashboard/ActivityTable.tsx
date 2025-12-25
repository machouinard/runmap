import React from 'react'
import { RefreshCw, Trash2, Edit3, MapPin } from 'lucide-react'
import { Activity } from './types'
import {
  formatDistance,
  formatDuration,
  formatSpeed,
  getLocationBadgeColor,
  getTypeBadgeColor,
  getStatusBadgeColor
} from './utils'

interface ActivityTableProps {
  activities: Activity[]
  sortField: keyof Activity
  sortDirection: 'asc' | 'desc'
  handleSort: (field: keyof Activity) => void
  expandedRow: string | null
  setExpandedRow: (id: string | null) => void
  reclassifyMenuOpen: string | null
  setReclassifyMenuOpen: (id: string | null) => void
  overlayingId: string | null
  deletingId: string | null
  onOverlayActivity?: (activityId: string, activityType: 'run' | 'walk' | 'cycling') => void
  setOverlayingId: (id: string | null) => void
  handleReclassify: (activity: Activity, newType: 'run' | 'walk' | 'cycling') => void
  handleDelete: (activity: Activity) => void
  handleRetry: (activity: Activity) => void
  selectedIds: Set<string>
  toggleSelection: (id: string) => void
  toggleAllSelection: () => void
  handleBulkDelete: () => void
  bulkDeleting: boolean
  handleUpdateName: (id: string, name: string, type: string) => void
  isAdmin: boolean
}

export function ActivityTable({
  activities,
  sortField,
  sortDirection,
  handleSort,
  expandedRow,
  setExpandedRow,
  reclassifyMenuOpen,
  setReclassifyMenuOpen,
  overlayingId,
  deletingId,
  onOverlayActivity,
  setOverlayingId,
  handleReclassify,
  handleDelete,
  handleRetry,
  selectedIds,
  toggleSelection,
  toggleAllSelection,
  handleBulkDelete,
  bulkDeleting,
  handleUpdateName,
  isAdmin
}: ActivityTableProps) {
  const [editingId, setEditingId] = React.useState<string | null>(null)
  const [editName, setEditName] = React.useState('')

  const startEditing = (activity: Activity) => {
    if (!isAdmin) return
    setEditingId(activity.id)
    setEditName(activity.route_name || activity.filename)
  }

  const saveEditing = (activity: Activity) => {
    if (editName.trim() && editName !== activity.route_name) {
      handleUpdateName(activity.id, editName.trim(), activity.activity_type)
    }
    setEditingId(null)
  }

  const handleKeyDown = (e: React.KeyboardEvent, activity: Activity) => {
    if (e.key === 'Enter') {
      saveEditing(activity)
    } else if (e.key === 'Escape') {
      setEditingId(null)
    }
  }

  const getSortIndicator = (field: keyof Activity) => {
    if (sortField === field) {
      return sortDirection === 'asc' ? '↑' : '↓'
    }
    return ''
  }

  return (
    <div className="max-w-7xl mx-auto bg-white rounded-lg shadow overflow-hidden hidden lg:block">
      {selectedIds.size > 0 && (
        <div className="bg-gray-50 px-6 py-2 border-b border-gray-200 flex justify-between items-center">
          <span className="text-sm text-gray-700">{selectedIds.size} selected</span>
          <button
            onClick={handleBulkDelete}
            disabled={bulkDeleting}
            className="bg-red-600 text-white px-3 py-1 rounded text-sm hover:bg-red-700 disabled:opacity-50 flex items-center gap-2"
          >
            {bulkDeleting ? <RefreshCw className="w-4 h-4 animate-spin" /> : <Trash2 className="w-4 h-4" />}
            Delete Selected
          </button>
        </div>
      )}
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-6 py-3 text-left">
                <input
                  type="checkbox"
                  checked={activities.length > 0 && selectedIds.size === activities.length}
                  onChange={toggleAllSelection}
                  className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
                />
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer" onClick={() => handleSort('start_time')}>
                Date {getSortIndicator('start_time')}
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer" onClick={() => handleSort('route_name')}>
                Route Name {getSortIndicator('route_name')}
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer" onClick={() => handleSort('location')}>
                Location {getSortIndicator('location')}
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer" onClick={() => handleSort('activity_type')}>
                Type {getSortIndicator('activity_type')}
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer" onClick={() => handleSort('total_distance_m')}>
                Distance {getSortIndicator('total_distance_m')}
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer" onClick={() => handleSort('duration_seconds')}>
                Duration {getSortIndicator('duration_seconds')}
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Status
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Actions
              </th>
            </tr>
          </thead>
          <tbody className="bg-white divide-y divide-gray-200">
            {activities.map((activity) => (
              <React.Fragment key={activity.id}>
                <tr className="hover:bg-gray-50">
                  <td className="px-6 py-4 whitespace-nowrap">
                    <input
                      type="checkbox"
                      checked={selectedIds.has(activity.id)}
                      onChange={() => toggleSelection(activity.id)}
                      className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
                    />
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                    {new Date(activity.start_time).toLocaleDateString()}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900" title={activity.filename}>
                    {editingId === activity.id ? (
                      <input
                        type="text"
                        value={editName}
                        onChange={(e) => setEditName(e.target.value)}
                        onBlur={() => saveEditing(activity)}
                        onKeyDown={(e) => handleKeyDown(e, activity)}
                        autoFocus
                        className="border rounded px-2 py-1 w-full focus:outline-none focus:ring-2 focus:ring-blue-500"
                      />
                    ) : (
                      <div className="group flex items-center gap-2 cursor-text" onClick={() => isAdmin && startEditing(activity)}>
                        <span>{activity.route_name || activity.filename}</span>
                        {isAdmin && (
                          <Edit3 className="w-3 h-3 opacity-0 group-hover:opacity-100 text-gray-400" />
                        )}
                      </div>
                    )}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <span className={`px-2 py-1 text-xs font-medium rounded ${getLocationBadgeColor(activity.location)}`}>
                      {activity.location}
                    </span>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <span className={`px-2 py-1 text-xs font-medium rounded ${getTypeBadgeColor(activity.activity_type)}`}>
                      {activity.activity_type}
                    </span>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                    {formatDistance(activity.total_distance_m)}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                    {formatDuration(activity.duration_seconds)}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    {activity.processing_status && (
                      <span className={`px-2 py-1 text-xs font-medium rounded ${getStatusBadgeColor(activity.processing_status)}`}>
                        {activity.processing_status}
                      </span>
                    )}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm">
                    <div className="flex items-center gap-2">
                      <button
                        onClick={() => setExpandedRow(expandedRow === activity.id ? null : activity.id)}
                        className="text-blue-600 hover:text-blue-800"
                        title="View Details"
                      >
                        {expandedRow === activity.id ? 'Hide' : 'Details'}
                      </button>

                      <div className="relative reclassify-menu">
                        <button
                          onClick={() => setReclassifyMenuOpen(reclassifyMenuOpen === activity.id ? null : activity.id)}
                          className="text-gray-600 hover:text-gray-800 flex items-center gap-1"
                        >
                          <Edit3 className="w-4 h-4" />
                        </button>
                        {reclassifyMenuOpen === activity.id && (
                          <div className="absolute right-0 mt-1 w-40 bg-white border rounded shadow-lg z-20">
                            {activity.activity_type !== 'run' && (
                              <button
                                onClick={() => handleReclassify(activity, 'run')}
                                className="block w-full text-left px-4 py-2 text-sm hover:bg-gray-100 rounded-t"
                              >
                                Change to Run
                              </button>
                            )}
                            {activity.activity_type !== 'walk' && (
                              <button
                                onClick={() => handleReclassify(activity, 'walk')}
                                className="block w-full text-left px-4 py-2 text-sm hover:bg-gray-100"
                              >
                                Change to Walk
                              </button>
                            )}
                            {activity.activity_type !== 'cycling' && (
                              <button
                                onClick={() => handleReclassify(activity, 'cycling')}
                                className="block w-full text-left px-4 py-2 text-sm hover:bg-gray-100 rounded-b"
                              >
                                Change to Cycling
                              </button>
                            )}
                          </div>
                        )}
                      </div>

                      {onOverlayActivity && (
                        <button
                          onClick={async () => {
                            setOverlayingId(activity.id)
                            await onOverlayActivity(activity.id, activity.activity_type)
                            setOverlayingId(null)
                          }}
                          disabled={overlayingId === activity.id}
                          className={`${overlayingId === activity.id ? 'text-gray-400' : 'text-purple-600 hover:text-purple-800'}`}
                          title={overlayingId === activity.id ? 'Loading...' : 'Overlay on Map'}
                        >
                          {overlayingId === activity.id ? (
                            <RefreshCw className="w-4 h-4 animate-spin" />
                          ) : (
                            <MapPin className="w-4 h-4" />
                          )}
                        </button>
                      )}

                      {activity.processing_status === 'failed' && (
                        <button
                          onClick={() => handleRetry(activity)}
                          className="text-green-600 hover:text-green-800"
                          title="Retry Processing"
                        >
                          <RefreshCw className="w-4 h-4" />
                        </button>
                      )}

                      <button
                        onClick={() => handleDelete(activity)}
                        disabled={deletingId === activity.id}
                        className={`${deletingId === activity.id ? 'text-gray-400' : 'text-red-600 hover:text-red-800'} relative`}
                        title={deletingId === activity.id ? 'Deleting... (this may take up to 2 minutes)' : 'Delete'}
                      >
                        {deletingId === activity.id ? (
                          <RefreshCw className="w-4 h-4 animate-spin" />
                        ) : (
                          <Trash2 className="w-4 h-4" />
                        )}
                      </button>
                    </div>
                  </td>
                </tr>
                {expandedRow === activity.id && (
                  <tr>
                    <td colSpan={8} className="px-6 py-4 bg-gray-50 border-t border-b">
                      <div className="text-xs">
                        <div className="grid grid-cols-4 gap-2">
                          <div><strong>ID:</strong> {activity.id}</div>
                          <div><strong>Start Time:</strong> {new Date(activity.start_time).toLocaleString()}</div>
                          <div><strong>Speed:</strong> {formatSpeed(activity.total_distance_m, activity.duration_seconds)}</div>
                          <div><strong>Uploaded:</strong> {activity.processing_completed_at ? new Date(activity.processing_completed_at).toLocaleString() : (activity.uploaded_at ? new Date(activity.uploaded_at).toLocaleString() : 'N/A')}</div>
                        </div>
                      </div>
                    </td>
                  </tr>
                )}
              </React.Fragment>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
