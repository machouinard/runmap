import { Gauge } from 'lucide-react';
import type { DistanceFilterPreset, DistanceFilterState } from '@/types';

interface DistanceFilterProps {
  filterState: DistanceFilterState;
  onChange: (state: DistanceFilterState) => void;
}

const FILTER_OPTIONS: { value: DistanceFilterPreset; label: string }[] = [
  { value: 'all', label: 'All Distances' },
  { value: 'short', label: 'Short (< 3.1 mi)' },
  { value: 'medium', label: 'Medium (3.1-6.2 mi)' },
  { value: 'long', label: 'Long (6.2-9.3 mi)' },
  { value: 'very-long', label: 'Very Long (9.3+ mi)' },
];

function calculateDistanceRange(preset: DistanceFilterPreset): { minDistance: number | null; maxDistance: number | null } {
  switch (preset) {
    case 'all':
      return { minDistance: null, maxDistance: null };
    case 'short':
      return { minDistance: 0, maxDistance: 5000 }; // < 5km
    case 'medium':
      return { minDistance: 5000, maxDistance: 10000 }; // 5-10km
    case 'long':
      return { minDistance: 10000, maxDistance: 15000 }; // 10-15km
    case 'very-long':
      return { minDistance: 15000, maxDistance: null }; // > 15km
    default:
      return { minDistance: null, maxDistance: null };
  }
}

export function DistanceFilter({ filterState, onChange }: DistanceFilterProps) {
  const handlePresetChange = (preset: DistanceFilterPreset) => {
    const { minDistance, maxDistance } = calculateDistanceRange(preset);
    onChange({ preset, minDistance, maxDistance });
  };

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 text-sm font-semibold text-gray-700">
        <Gauge className="w-4 h-4" />
        <span>Distance Filter</span>
      </div>

      <div className="space-y-1">
        {FILTER_OPTIONS.map((option) => (
          <button
            key={option.value}
            onClick={() => handlePresetChange(option.value)}
            className={`w-full text-left px-3 py-2 rounded-md text-sm transition-colors ${
              filterState.preset === option.value
                ? 'bg-blue-100 text-blue-900 font-medium'
                : 'text-gray-700 hover:bg-gray-100'
            }`}
          >
            {option.label}
          </button>
        ))}
      </div>

      {filterState.preset !== 'all' && (
        <div className="text-xs text-gray-500 px-3">
          {filterState.minDistance !== null && filterState.maxDistance !== null && (
            <>Showing runs between {(filterState.minDistance / 1609.34).toFixed(1)} - {(filterState.maxDistance / 1609.34).toFixed(1)} miles</>
          )}
          {filterState.minDistance !== null && filterState.maxDistance === null && (
            <>Showing runs over {(filterState.minDistance / 1609.34).toFixed(1)} miles</>
          )}
          {filterState.minDistance === null && filterState.maxDistance !== null && (
            <>Showing runs under {(filterState.maxDistance / 1609.34).toFixed(1)} miles</>
          )}
        </div>
      )}
    </div>
  );
}
