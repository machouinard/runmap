import { useState } from 'react';
import { Menu, X } from 'lucide-react';
import { LayerToggles } from './LayerToggles';
import { BaseMapSelector } from './BaseMapSelector';
import { useAuth } from '../contexts/AuthContext';
import { StatsSection } from './ControlPanel/StatsSection';
import { LocationJumper } from './ControlPanel/LocationJumper';
import { RouteOverlay } from './ControlPanel/RouteOverlay';
import { FilterControls } from './ControlPanel/FilterControls';
import { NavigationButtons } from './ControlPanel/NavigationButtons';
import { AdminControls } from './ControlPanel/AdminControls';
import type { LayerVisibility, CoverageStats, DateFilterState, DistanceFilterState } from '@/types';
import type { PlannedRoute } from '@/lib/gpxParser';
import type { ColorScheme } from '@/lib/colorSchemes';

interface ControlPanelProps {
  selectedBaseMap: string;
  layerVisibility: LayerVisibility;
  colors: ColorScheme;
  dateFilter: DateFilterState;
  distanceFilter: DistanceFilterState;
  apiStatus: 'checking' | 'connected' | 'error';
  stats: CoverageStats | null;
  totalRuns: number;
  totalMiles: number;
  onBaseMapChange: (mapKey: string) => void;
  onLayerVisibilityChange: (visibility: LayerVisibility) => void;
  onDateFilterChange: (filter: DateFilterState) => void;
  onDistanceFilterChange: (filter: DistanceFilterState) => void;
  onStatsRefresh: () => void;
  onShowAdmin: () => void;
  onShowActivities: () => void;
  onShowLogin: () => void;
  onJumpToLocation: (location: 'sacramento' | 'portland') => void;
  onTogglePolygonSelection?: () => void;
  isPolygonSelectionActive?: boolean;
  onGPXUpload: (event: React.ChangeEvent<HTMLInputElement>) => void;
  hasPlannedRoute: boolean;
  showPlannedRoute: boolean;
  plannedRoute: PlannedRoute | null;
  onTogglePlannedRoute: () => void;
  onClearPlannedRoute: () => void;
}

export function ControlPanel({
  selectedBaseMap,
  layerVisibility,
  colors,
  dateFilter,
  distanceFilter,
  apiStatus,
  stats,
  totalRuns,
  totalMiles,
  onBaseMapChange,
  onLayerVisibilityChange,
  onDateFilterChange,
  onDistanceFilterChange,
  onStatsRefresh,
  onShowAdmin,
  onShowActivities,
  onShowLogin,
  onJumpToLocation,
  onTogglePolygonSelection,
  isPolygonSelectionActive = false,
  onGPXUpload,
  hasPlannedRoute,
  showPlannedRoute,
  plannedRoute,
  onTogglePlannedRoute,
  onClearPlannedRoute,
}: ControlPanelProps) {
  const [isOpen, setIsOpen] = useState(false);
  const { isAdmin, logout, getAuthHeaders } = useAuth();

  return (
    <>
      {/* Mobile: Bottom Sheet */}
      <div className="md:hidden">
        {/* Toggle Button */}
        <button
          onClick={() => setIsOpen(!isOpen)}
          className="fixed bottom-4 right-4 z-50 bg-white rounded-full p-3 shadow-lg border border-gray-200"
          aria-label="Toggle controls"
        >
          {isOpen ? <X className="w-6 h-6" /> : <Menu className="w-6 h-6" />}
        </button>

        {/* Bottom Sheet */}
        {isOpen && (
          <div className="fixed bottom-0 left-0 right-0 bg-white rounded-t-2xl shadow-2xl z-50 max-h-[50vh] flex flex-col">
            {/* Fixed Header */}
            <div className="flex items-center justify-between p-6 pb-3 border-b border-gray-200 flex-shrink-0">
              <h2 className="text-lg font-bold text-gray-900">Map Controls</h2>
              <button
                onClick={() => setIsOpen(false)}
                className="text-gray-400 hover:text-gray-600"
                aria-label="Close"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            {/* Scrollable Content */}
            <div className="overflow-y-auto flex-1 p-6 space-y-6">
              <StatsSection
                apiStatus={apiStatus}
                stats={stats}
                totalRuns={totalRuns}
                totalMiles={totalMiles}
                onStatsRefresh={onStatsRefresh}
              />

              <BaseMapSelector
                selectedMap={selectedBaseMap}
                onChange={onBaseMapChange}
              />

              <div className="border-t border-gray-200 pt-4">
                <LayerToggles
                  visibility={layerVisibility}
                  onChange={onLayerVisibilityChange}
                  colors={colors}
                />
              </div>

              <LocationJumper
                onJumpToLocation={onJumpToLocation}
                onMobileClose={() => setIsOpen(false)}
                onShowActivities={onShowActivities}
              />

              <RouteOverlay
                hasPlannedRoute={hasPlannedRoute}
                showPlannedRoute={showPlannedRoute}
                plannedRoute={plannedRoute}
                isAdmin={isAdmin}
                onGPXUpload={onGPXUpload}
                onTogglePlannedRoute={onTogglePlannedRoute}
                onClearPlannedRoute={onClearPlannedRoute}
                onTogglePolygonSelection={onTogglePolygonSelection}
                isPolygonSelectionActive={isPolygonSelectionActive}
                onMobileClose={() => setIsOpen(false)}
              />

              <FilterControls
                dateFilter={dateFilter}
                distanceFilter={distanceFilter}
                onDateFilterChange={onDateFilterChange}
                onDistanceFilterChange={onDistanceFilterChange}
              />

              <NavigationButtons
                isAdmin={isAdmin}
                onShowAdmin={onShowAdmin}
                onMobileClose={() => setIsOpen(false)}
              />

              <AdminControls
                isAdmin={isAdmin}
                onShowLogin={onShowLogin}
                onStatsRefresh={onStatsRefresh}
                logout={logout}
                getAuthHeaders={getAuthHeaders}
              />
            </div>
          </div>
        )}
      </div>

      {/* Desktop: Hamburger Menu / Sidebar */}
      <div className="hidden md:block">
        {/* Toggle Button */}
        <button
          onClick={() => setIsOpen(!isOpen)}
          className="fixed top-4 left-4 z-50 bg-white rounded-lg p-3 shadow-lg border border-gray-200"
          aria-label="Toggle controls"
        >
          {isOpen ? <X className="w-6 h-6" /> : <Menu className="w-6 h-6" />}
        </button>

        {/* Sidebar */}
        {isOpen && (
          <div className="fixed top-0 left-0 bottom-0 w-80 bg-white shadow-2xl z-50 p-6 space-y-6 overflow-y-auto">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-bold text-gray-900">Map Controls</h2>
              <button
                onClick={() => setIsOpen(false)}
                className="text-gray-400 hover:text-gray-600"
                aria-label="Close"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            <StatsSection
              apiStatus={apiStatus}
              stats={stats}
              totalRuns={totalRuns}
              totalMiles={totalMiles}
              onStatsRefresh={onStatsRefresh}
            />

            <BaseMapSelector
              selectedMap={selectedBaseMap}
              onChange={onBaseMapChange}
            />

            <div className="border-t border-gray-200 pt-4">
              <LayerToggles
                visibility={layerVisibility}
                onChange={onLayerVisibilityChange}
                colors={colors}
              />
            </div>

            <LocationJumper
              onJumpToLocation={onJumpToLocation}
              onShowActivities={onShowActivities}
            />

            <FilterControls
              dateFilter={dateFilter}
              distanceFilter={distanceFilter}
              onDateFilterChange={onDateFilterChange}
              onDistanceFilterChange={onDistanceFilterChange}
            />

            <RouteOverlay
              hasPlannedRoute={hasPlannedRoute}
              showPlannedRoute={showPlannedRoute}
              plannedRoute={plannedRoute}
              isAdmin={isAdmin}
              onGPXUpload={onGPXUpload}
              onTogglePlannedRoute={onTogglePlannedRoute}
              onClearPlannedRoute={onClearPlannedRoute}
              onTogglePolygonSelection={onTogglePolygonSelection}
              isPolygonSelectionActive={isPolygonSelectionActive}
            />

            <NavigationButtons
              isAdmin={isAdmin}
              onShowAdmin={onShowAdmin}
            />

            <AdminControls
              isAdmin={isAdmin}
              onShowLogin={onShowLogin}
              onStatsRefresh={onStatsRefresh}
              logout={logout}
              getAuthHeaders={getAuthHeaders}
            />
          </div>
        )}
      </div>
    </>
  );
}
