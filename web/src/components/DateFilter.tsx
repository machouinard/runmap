import { Calendar } from 'lucide-react';
import type { DateFilterPreset, DateFilterState } from '@/types';

interface DateFilterProps {
  filterState: DateFilterState;
  onChange: (state: DateFilterState) => void;
}

const FILTER_OPTIONS: { value: DateFilterPreset; label: string }[] = [
  { value: 'all', label: 'All Time' },
  { value: 'this-month', label: 'This Month' },
  { value: 'last-month', label: 'Last Month' },
  { value: 'last-3-months', label: 'Last 3 Months' },
  { value: 'last-6-months', label: 'Last 6 Months' },
  { value: 'last-9-months', label: 'Last 9 Months' },
  { value: 'last-12-months', label: 'Last 12 Months' },
];

function calculateDateRange(preset: DateFilterPreset): { startDate: Date | null; endDate: Date | null } {
  const now = new Date();
  const endDate = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59);

  if (preset === 'all') {
    return { startDate: null, endDate: null };
  }

  let startDate: Date;

  if (preset === 'this-month') {
    startDate = new Date(now.getFullYear(), now.getMonth(), 1, 0, 0, 0);
  } else if (preset === 'last-month') {
    const lastMonth = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    startDate = new Date(lastMonth.getFullYear(), lastMonth.getMonth(), 1, 0, 0, 0);
    const lastDayOfMonth = new Date(lastMonth.getFullYear(), lastMonth.getMonth() + 1, 0);
    return {
      startDate,
      endDate: new Date(lastDayOfMonth.getFullYear(), lastDayOfMonth.getMonth(), lastDayOfMonth.getDate(), 23, 59, 59),
    };
  } else {
    const months = parseInt(preset.replace('last-', '').replace('-months', ''));
    startDate = new Date(now.getFullYear(), now.getMonth() - months + 1, 1, 0, 0, 0);
  }

  return { startDate, endDate };
}

export function DateFilter({ filterState, onChange }: DateFilterProps) {
  const handlePresetChange = (preset: DateFilterPreset) => {
    const { startDate, endDate } = calculateDateRange(preset);
    onChange({ preset, startDate, endDate });
  };

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 text-sm font-semibold text-gray-700">
        <Calendar className="w-4 h-4" />
        <span>Date Filter</span>
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

      {filterState.preset !== 'all' && filterState.startDate && (
        <div className="text-xs text-gray-500 px-3">
          Showing runs from {filterState.startDate.toLocaleDateString()} to{' '}
          {filterState.endDate ? filterState.endDate.toLocaleDateString() : 'now'}
        </div>
      )}
    </div>
  );
}
