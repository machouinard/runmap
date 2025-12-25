import { RefreshCw } from 'lucide-react';
import type { CoverageStats } from '@/types';

interface StatsSectionProps {
  apiStatus: 'checking' | 'connected' | 'error';
  stats: CoverageStats | null;
  totalRuns: number;
  totalMiles: number;
  onStatsRefresh: () => void;
}

export function StatsSection({
  apiStatus,
  stats,
  totalRuns,
  totalMiles,
  onStatsRefresh,
}: StatsSectionProps) {
  const completeMiles = (stats?.covered_length_km || 0) * 0.621371;
  const unrunMiles = ((stats?.total_length_km || 0) - (stats?.covered_length_km || 0)) * 0.621371;
  const totalMileage = (stats?.total_length_km || 0) * 0.621371;
  return (
    <div className="space-y-3  border-gray-200 pt-4">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-gray-700">Statistics</h3>
        <button
          onClick={onStatsRefresh}
          className="text-gray-400 hover:text-gray-600 transition-colors"
          aria-label="Refresh stats"
        >
          <RefreshCw className="w-4 h-4" />
        </button>
      </div>

      <div className="text-sm space-y-1">
        <div className="flex items-center gap-2">
          <span className="text-gray-600">API:</span>
          <span className={apiStatus === 'connected' ? 'text-green-600' : apiStatus === 'error' ? 'text-red-600' : 'text-gray-500'}>
            {apiStatus === 'checking' ? 'Checking...' : apiStatus === 'connected' ? '✓ Connected' : '✗ Error'}
          </span>
        </div>

        {stats && (
          <>
            <div className="border-t border-gray-100 pt-2 mt-2">
              <div className="flex items-center gap-2">
                <span className="text-gray-600">Coverage:</span>
                <span className="font-medium">{stats.coverage_pct.toFixed(2)}%</span>
              </div>
            </div>

            <div className="space-y-1 text-xs">
              <div className="flex items-center justify-between">
                <span className="text-gray-600">Complete:</span>
                <span className="font-medium">{completeMiles.toLocaleString('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} mi</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-gray-600">Unrun:</span>
                <span className="font-medium">{unrunMiles.toLocaleString('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} mi</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-gray-600">Total:</span>
                <span className="font-medium">{totalMileage.toLocaleString('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} mi</span>
              </div>
            </div>
          </>
        )}
        {totalRuns > 0 && (
          <div className="border-t border-gray-100 pt-2 mt-2 space-y-1">
            <div className="flex items-center justify-between">
              <span className="text-gray-600">Total runs:</span>
              <span className="font-medium">{totalRuns}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-gray-600">Total mileage:</span>
              <span className="font-medium">{totalMiles.toLocaleString('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })} mi</span>
            </div>
          </div>
        )}

      </div>
    </div>
  );
}
