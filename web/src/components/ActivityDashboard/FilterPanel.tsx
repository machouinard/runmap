import { Download } from 'lucide-react'
import { Filters } from './types'
import { exportToCSV, formatDuration } from './utils'

interface FilterPanelProps {
  filters: Filters
  setFilters: (filters: Filters) => void
  filteredCount: number
  totalCount: number
  isAdmin: boolean
  asteriskFilter: boolean
  setAsteriskFilter: (value: boolean) => void
  activities: {
    start_time: string
    filename: string
    location: string
    activity_type: string
    total_distance_m: number
    duration_seconds: number
    processing_status?: string
  }[]
}

export function FilterPanel({
  filters,
  setFilters,
  filteredCount,
  totalCount,
  isAdmin,
  asteriskFilter,
  setAsteriskFilter,
  activities
}: FilterPanelProps) {
  return (
    <div className="max-w-7xl mx-auto mb-4 lg:mb-6 space-y-4">
      <div className="bg-white rounded-lg shadow p-4">
        {/* Type Filters */}
        <div className="mb-4">
          <label className="block text-xs font-medium text-gray-600 mb-2">TYPE</label>
          <div className="flex flex-wrap gap-2">
            {['all', 'run', 'walk'].map((type) => (
              <button
                key={type}
                onClick={() => {
                  setFilters({ ...filters, type })
                  setAsteriskFilter(false)
                }}
                className={`px-4 py-2 rounded-full text-sm font-medium transition-colors min-h-[44px] lg:min-h-0 lg:py-2 ${filters.type === type && !asteriskFilter
                  ? type === 'run' ? 'bg-red-600 text-white' :
                    type === 'walk' ? 'bg-blue-600 text-white' :
                      type === 'cycling' ? 'bg-green-600 text-white' :
                        'bg-gray-600 text-white'
                  : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                  }`}
              >
                {type === 'all' ? 'All' : type.charAt(0).toUpperCase() + type.slice(1) + 's'}
              </button>
            ))}
            <button
              onClick={() => {
                if (asteriskFilter) {
                  setAsteriskFilter(false)
                } else {
                  setAsteriskFilter(true)
                  setFilters({ ...filters, type: 'all' })
                }
              }}
              className={`px-4 py-2 rounded-full text-sm font-medium transition-colors min-h-[44px] lg:min-h-0 lg:py-2 ${asteriskFilter
                ? 'bg-purple-600 text-white'
                : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                }`}
            >
              Other
            </button>
          </div>
        </div>

        {/* Location Filters */}
        <div className="mb-4">
          <label className="block text-xs font-medium text-gray-600 mb-2">LOCATION</label>
          <div className="flex flex-wrap gap-2">
            {['all', 'sacramento', 'portland', 'other'].map((loc) => (
              <button
                key={loc}
                onClick={() => setFilters({ ...filters, location: loc })}
                className={`px-4 py-2 rounded-full text-sm font-medium transition-colors min-h-[44px] lg:min-h-0 lg:py-2 ${filters.location === loc
                  ? 'bg-blue-600 text-white'
                  : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                  }`}
              >
                {loc === 'all' ? 'All' : loc.charAt(0).toUpperCase() + loc.slice(1)}
              </button>
            ))}
          </div>
        </div>

        {/* Status Filters */}
        <div className="mb-4">
          <label className="block text-xs font-medium text-gray-600 mb-2">STATUS (RUNS ONLY)</label>
          <div className="flex flex-wrap gap-2">
            {['all', 'processed', 'failed', 'pending'].map((status) => (
              <button
                key={status}
                onClick={() => setFilters({ ...filters, status })}
                className={`px-4 py-2 rounded-full text-sm font-medium transition-colors min-h-[44px] lg:min-h-0 lg:py-2 ${filters.status === status
                  ? status === 'processed' ? 'bg-green-100 text-green-800' :
                    status === 'failed' ? 'bg-red-100 text-red-800' :
                      status === 'pending' ? 'bg-yellow-100 text-yellow-800' :
                        'bg-gray-600 text-white'
                  : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                  }`}
              >
                {status.charAt(0).toUpperCase() + status.slice(1)}
              </button>
            ))}
          </div>
        </div>

        {/* Search and Export */}
        <div className="flex flex-col sm:flex-row gap-3">
          <div className="flex-1">
            <input
              type="text"
              value={filters.search}
              onChange={(e) => setFilters({ ...filters, search: e.target.value })}
              placeholder="Search by date (e.g., 2024, Jan, 12/25)..."
              className="w-full px-4 py-2 text-sm lg:text-base border border-gray-300 rounded-lg min-h-[44px] lg:min-h-0 lg:py-2"
            />
          </div>
          {isAdmin && (
            <button
              onClick={() => exportToCSV(activities)}
              className="px-4 py-2 bg-blue-600 text-white text-sm lg:text-base rounded-lg hover:bg-blue-700 flex items-center justify-center gap-2 min-h-[44px] lg:min-h-0 lg:py-2 whitespace-nowrap"
            >
              <Download className="w-4 h-4" />
              <span>Export CSV</span>
            </button>
          )}
        </div>

        <div className="mt-3 text-xs lg:text-sm text-gray-600 flex justify-between items-end">
          <span>Showing {filteredCount} of {totalCount} activities</span>
          {asteriskFilter && (
            <div className="text-right">
              <div className="font-bold text-purple-700">
                Total Distance: {(activities.reduce((acc, curr) => acc + (curr.total_distance_m || 0), 0) / 1609.34).toFixed(2)} miles
              </div>
              <div className="font-bold text-purple-700 text-xs mt-1">
                Total Duration: {formatDuration(activities.reduce((acc, curr) => acc + (curr.duration_seconds || 0), 0))}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
