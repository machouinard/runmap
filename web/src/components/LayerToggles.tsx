import { Checkbox } from '@radix-ui/react-checkbox';
import { Check } from 'lucide-react';
import { useState, useEffect } from 'react';
import type { LayerVisibility } from '@/types';
import type { ColorScheme } from '@/lib/colorSchemes';

interface LayerTogglesProps {
  visibility: LayerVisibility;
  onChange: (visibility: LayerVisibility) => void;
  colors: ColorScheme;
}

export function LayerToggles({ visibility, onChange, colors }: LayerTogglesProps) {
  const [completionThreshold, setCompletionThreshold] = useState<number>(85);

  useEffect(() => {
    const fetchThreshold = async () => {
      try {
        const response = await fetch('/api/stats');
        const data = await response.json();
        if (data.coverage?.completion_threshold_pct) {
          setCompletionThreshold(data.coverage.completion_threshold_pct);
        }
      } catch (error) {
        console.error('Failed to fetch completion threshold:', error);
      }
    };
    fetchThreshold();
  }, []);

  const handleToggle = (layer: keyof LayerVisibility) => {
    onChange({
      ...visibility,
      [layer]: !visibility[layer],
    });
  };

  return (
    <div className="space-y-3">
      <h3 className="text-sm font-semibold text-gray-700">Layers</h3>

      <label className="flex items-center gap-3 cursor-pointer">
        <Checkbox
          checked={visibility.runs}
          onCheckedChange={() => handleToggle('runs')}
          className="w-5 h-5 border-2 border-gray-300 rounded flex items-center justify-center data-[state=checked]:border-gray-400"
          style={{
            backgroundColor: visibility.runs ? colors.runs : 'transparent',
          }}
        >
          <Check className="w-3 h-3 text-white" />
        </Checkbox>
        <div className="flex items-center gap-2">
          <div className="w-8 h-0.5 opacity-85" style={{ backgroundColor: colors.runs }} />
          <span className="text-sm text-gray-700">My Runs</span>
        </div>
      </label>

      <label className="flex items-center gap-3 cursor-pointer">
        <Checkbox
          checked={visibility.complete}
          onCheckedChange={() => handleToggle('complete')}
          className="w-5 h-5 border-2 border-gray-300 rounded flex items-center justify-center data-[state=checked]:border-gray-400"
          style={{
            backgroundColor: visibility.complete ? colors.complete : 'transparent',
          }}
        >
          <Check className="w-3 h-3 text-white" />
        </Checkbox>
        <div className="flex items-center gap-2">
          <div className="w-8 h-1 opacity-70" style={{ backgroundColor: colors.complete }} />
          <span className="text-sm text-gray-700">Complete Streets (≥{completionThreshold}%)</span>
        </div>
      </label>

      <label className="flex items-center gap-3 cursor-pointer">
        <Checkbox
          checked={visibility.incomplete}
          onCheckedChange={() => handleToggle('incomplete')}
          className="w-5 h-5 border-2 border-gray-300 rounded flex items-center justify-center data-[state=checked]:border-gray-400"
          style={{
            backgroundColor: visibility.incomplete ? colors.incomplete : 'transparent',
          }}
        >
          <Check className="w-3 h-3 text-white" />
        </Checkbox>
        <div className="flex items-center gap-2">
          <div className="w-8 h-0.5" style={{ backgroundColor: colors.incomplete }} />
          <span className="text-sm text-gray-700">Incomplete Streets (&lt;{completionThreshold}%)</span>
        </div>
      </label>
    </div>
  );
}
