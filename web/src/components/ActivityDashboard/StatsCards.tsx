import { ActivityStats } from './types'

interface StatsCardsProps {
  stats: ActivityStats
}

export function StatsCards({ stats }: StatsCardsProps) {
  return (
    <div className="max-w-7xl mx-auto grid grid-cols-2 lg:grid-cols-4 gap-3 lg:gap-4 mb-4 lg:mb-6">
      <div className="bg-white rounded-lg shadow p-3 lg:p-4">
        <div className="text-xs lg:text-sm text-gray-600">Total Activities</div>
        <div className="text-xl lg:text-2xl font-bold">{(stats.total).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}</div>
      </div>
      <div className="bg-white rounded-lg shadow p-3 lg:p-4">
        <div className="text-xs lg:text-sm text-gray-600">Runs</div>
        <div className="text-xl lg:text-2xl font-bold text-red-600">{(stats.runs.length).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}</div>
        <div className="text-xs text-gray-500">
          {(stats.runs.reduce((sum, a) => sum + a.total_distance_m, 0) / 1609.34).toLocaleString('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} mi
        </div>
      </div>
      <div className="bg-white rounded-lg shadow p-3 lg:p-4">
        <div className="text-xs lg:text-sm text-gray-600">Walks</div>
        <div className="text-xl lg:text-2xl font-bold text-blue-600">{(stats.walks.length).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}</div>
        <div className="text-xs text-gray-500">
          {(stats.walks.reduce((sum, a) => sum + a.total_distance_m, 0) / 1609.34).toLocaleString('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} mi
        </div>
      </div>
      <div className="bg-white rounded-lg shadow p-3 lg:p-4">
        <div className="text-xs lg:text-sm text-gray-600">Cycling</div>
        <div className="text-xl lg:text-2xl font-bold text-green-600">{(stats.cycling.length).toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}</div>
        <div className="text-xs text-gray-500">
          {(stats.cycling.reduce((sum, a) => sum + a.total_distance_m, 0) / 1609.34).toLocaleString('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} mi
        </div>
      </div>
    </div>
  )
}
