import { MapPin } from 'lucide-react';

interface LocationJumperProps {
  onJumpToLocation: (location: 'sacramento' | 'portland') => void;
  onMobileClose?: () => void;
  onShowActivities: () => void;
}

export function LocationJumper({ onJumpToLocation, onMobileClose, onShowActivities }: LocationJumperProps) {
  const handleJump = (location: 'sacramento' | 'portland') => {
    onJumpToLocation(location);
    onMobileClose?.();
  };
  const handleShowActivities = () => {
    onShowActivities();
    onMobileClose?.();
  };

  return (
    <div className="border-t border-gray-200 pt-4">
      <h3 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2">
        Jump to Location
      </h3>
      <div className="flex gap-2">
        <button
          onClick={() => handleJump('sacramento')}
          className="flex-1 px-3 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-1"
        >
          <MapPin className="w-4 h-4" />
          Sacramento
        </button>
        <button
          onClick={() => handleJump('portland')}
          className="flex-1 px-3 py-2 bg-green-600 hover:bg-green-700 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-1"
        >
          <MapPin className="w-4 h-4" />
          Portland
        </button>
      </div>
      <div className="flex gap-2 mt-2">
        <button
          onClick={handleShowActivities}
          className="w-full px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-md text-sm font-medium transition-colors"
        >
          View All Routes
        </button>
      </div>
    </div>
  );
}
