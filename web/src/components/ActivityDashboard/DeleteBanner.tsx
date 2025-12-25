import { RefreshCw } from 'lucide-react'

interface DeleteBannerProps {
  isDeleting: boolean
}

export function DeleteBanner({ isDeleting }: DeleteBannerProps) {
  if (!isDeleting) return null

  return (
    <div className="max-w-7xl mx-auto mb-4">
      <div className="bg-yellow-50 border-l-4 border-yellow-400 p-4 rounded-r-lg">
        <div className="flex items-center">
          <RefreshCw className="w-5 h-5 text-yellow-600 animate-spin mr-3" />
          <div>
            <p className="text-sm font-medium text-yellow-800">
              Deleting activity and regenerating tiles...
            </p>
            <p className="text-xs text-yellow-700 mt-1">
              This may take up to 2 minutes. Coverage will be recalculated and map tiles will be updated.
            </p>
          </div>
        </div>
      </div>
    </div>
  )
}
