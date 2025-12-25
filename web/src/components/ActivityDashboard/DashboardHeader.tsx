import { ArrowLeft } from 'lucide-react'

export function DashboardHeader() {
  return (
    <div className="max-w-7xl mx-auto mb-4 lg:mb-6">
      <button
        onClick={() => window.location.hash = ''}
        className="flex items-center gap-2 text-gray-600 hover:text-gray-900 mb-3 lg:mb-4 min-h-[44px] -ml-2 pl-2 pr-4 rounded-lg hover:bg-gray-100"
      >
        <ArrowLeft className="w-5 h-5" />
        <span className="text-sm lg:text-base">Back to Map</span>
      </button>

      <h1 className="text-2xl lg:text-3xl font-bold text-gray-900">Activity Dashboard</h1>
      <p className="text-sm lg:text-base text-gray-600 mt-1">View and manage all activities (runs, walks, cycling)</p>
    </div>
  )
}
