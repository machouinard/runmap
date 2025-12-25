import { DistanceFilter } from '../DistanceFilter';
import { TimelineSlider } from '../TimelineSlider';
import type { DateFilterState, DistanceFilterState } from '@/types';

interface FilterControlsProps {
  dateFilter: DateFilterState;
  distanceFilter: DistanceFilterState;
  onDateFilterChange: (filter: DateFilterState) => void;
  onDistanceFilterChange: (filter: DistanceFilterState) => void;
}

export function FilterControls({
  dateFilter,
  distanceFilter,
  onDateFilterChange,
  onDistanceFilterChange,
}: FilterControlsProps) {
  const handleResetFilters = () => {
    onDateFilterChange({ preset: 'all', startDate: null, endDate: null });
    onDistanceFilterChange({ preset: 'all', minDistance: null, maxDistance: null });
  };

  const handleTimelineChange = (endDate: Date | null) => {
    if (endDate === null) {
      // Reset to "All Time"
      onDateFilterChange({ preset: 'all', startDate: null, endDate: null });
    } else {
      // Set custom range from first run to timeline date
      // Use 'this-month' as placeholder preset to ensure filtering activates
      onDateFilterChange({
        preset: 'this-month', // Any non-'all' value to activate filtering
        startDate: new Date('2024-02-25'), // First run
        endDate: endDate,
      });
    }
  };

  return (
    <>
      <div className="border-t border-gray-200 pt-4">
        <DistanceFilter
          filterState={distanceFilter}
          onChange={onDistanceFilterChange}
        />
      </div>

      <div className="border-t border-gray-200 pt-4">
        <TimelineSlider
          dateFilterPreset={dateFilter.preset}
          onTimelineChange={handleTimelineChange}
        />
      </div>

      <div className="border-t border-gray-200 pt-4">
        <button
          onClick={handleResetFilters}
          className="w-full px-4 py-2 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded-md text-sm font-medium transition-colors"
        >
          Reset All Filters
        </button>
      </div>

    </>
  );
}
