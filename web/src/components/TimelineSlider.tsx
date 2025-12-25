import { useState, useEffect } from 'react';
import { Clock } from 'lucide-react';

interface TimelineSliderProps {
  onTimelineChange: (endDate: Date | null) => void;
  dateFilterPreset?: string; // Listen for reset from parent
}

export function TimelineSlider({ onTimelineChange, dateFilterPreset }: TimelineSliderProps) {
  const [sliderValue, setSliderValue] = useState(100); // 0-100 percentage
  const [timelineStart, setTimelineStart] = useState<Date>(new Date('2024-02-01')); // First run date
  const [timelineEnd, setTimelineEnd] = useState<Date>(new Date());
  const [currentDate, setCurrentDate] = useState<Date | null>(null);

  // Reset slider when date filter is set to 'all'
  useEffect(() => {
    if (dateFilterPreset === 'all') {
      setSliderValue(100);
      setCurrentDate(null);
    }
  }, [dateFilterPreset]);

  // Fetch timeline bounds from API (or hardcode for now)
  useEffect(() => {
    // TODO: Fetch actual first run date from API
    // For now, hardcoded to Feb 2024 (from the tile metadata we saw earlier)
    setTimelineStart(new Date('2024-02-25'));
    setTimelineEnd(new Date());
  }, []);

  const handleSliderChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const value = parseInt(e.target.value);
    setSliderValue(value);

    if (value === 100) {
      // Show all runs
      setCurrentDate(null);
      onTimelineChange(null);
    } else {
      // Calculate date based on slider position
      const totalDuration = timelineEnd.getTime() - timelineStart.getTime();
      const currentTime = timelineStart.getTime() + (totalDuration * value / 100);
      const date = new Date(currentTime);
      setCurrentDate(date);
      onTimelineChange(date);
    }
  };

  const formatDate = (date: Date) => {
    return date.toLocaleDateString('en-US', { month: 'short', year: 'numeric' });
  };

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 text-sm font-semibold text-gray-700">
        <Clock className="w-4 h-4" />
        <span>Coverage Timeline</span>
      </div>

      <div className="space-y-2">
        <input
          type="range"
          min="0"
          max="100"
          value={sliderValue}
          onChange={handleSliderChange}
          className="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer accent-blue-600"
        />

        <div className="flex justify-between text-xs text-gray-500">
          <span>{formatDate(timelineStart)}</span>
          <span>{formatDate(timelineEnd)}</span>
        </div>

        {currentDate && (
          <div className="text-sm text-gray-700 text-center bg-blue-50 rounded-md py-2 px-3">
            Coverage as of <strong>{currentDate.toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })}</strong>
          </div>
        )}

        {!currentDate && (
          <div className="text-sm text-gray-500 text-center">
            Showing all runs
          </div>
        )}
      </div>

      <div className="text-xs text-gray-500 px-3">
        Drag the slider to see your coverage at any point in time
      </div>
    </div>
  );
}
