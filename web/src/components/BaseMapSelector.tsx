import { BASE_MAPS } from '@/types';

interface BaseMapSelectorProps {
  selectedMap: string;
  onChange: (mapKey: string) => void;
}

export function BaseMapSelector({ selectedMap, onChange }: BaseMapSelectorProps) {
  return (
    <div className="space-y-3">
      <h3 className="text-sm font-semibold text-gray-700">Base Map</h3>
      <select
        value={selectedMap}
        onChange={(e) => onChange(e.target.value)}
        className="w-full px-3 py-2 border border-gray-300 rounded-md text-sm bg-white focus:outline-none focus:ring-2 focus:ring-blue-500"
      >
        {Object.entries(BASE_MAPS).map(([key, map]) => (
          <option key={key} value={key}>
            {map.name}
          </option>
        ))}
      </select>
    </div>
  );
}
