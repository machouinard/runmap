import { useState, useEffect } from 'react'
import { RefreshCw } from 'lucide-react'
import { ActivityDashboardProps } from './types'
import { useActivities } from './useActivities'
import { DashboardHeader } from './DashboardHeader'
import { DeleteBanner } from './DeleteBanner'
import { StatsCards } from './StatsCards'
import { FilterPanel } from './FilterPanel'
import { ActivityCard } from './ActivityCard'
import { ActivityTable } from './ActivityTable'

export function ActivityDashboard({ onOverlayActivity }: ActivityDashboardProps = {}) {
  const {
    activities,
    filteredActivities,
    loading,
    filters,
    sortField,
    sortDirection,
    deletingId,
    overlayingId,
    selectedIds,
    bulkDeleting,
    asteriskFilter,
    stats,
    isAdmin,
    setFilters,
    setOverlayingId,
    setAsteriskFilter,
    handleSort,
    handleReclassify,
    handleDelete,
    handleRetry,
    toggleSelection,
    toggleAllSelection,
    handleBulkDelete,
    handleUpdateName
  } = useActivities()

  const [expandedRow, setExpandedRow] = useState<string | null>(null)
  const [reclassifyMenuOpen, setReclassifyMenuOpen] = useState<string | null>(null)
  const [actionMenuOpen, setActionMenuOpen] = useState<string | null>(null)

  // Close menus when clicking outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      const target = event.target as HTMLElement

      if (reclassifyMenuOpen && !target.closest('.reclassify-menu')) {
        setReclassifyMenuOpen(null)
      }

      if (actionMenuOpen && !target.closest(`[data-action-menu="${actionMenuOpen}"]`)) {
        setActionMenuOpen(null)
      }
    }

    document.addEventListener('click', handleClickOutside)
    return () => document.removeEventListener('click', handleClickOutside)
  }, [reclassifyMenuOpen, actionMenuOpen])

  if (loading) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center">
        <div className="text-center">
          <RefreshCw className="w-8 h-8 animate-spin mx-auto mb-2" />
          <p>Loading activities...</p>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-screen bg-gray-50 p-3 lg:p-6">
      <DashboardHeader />

      <DeleteBanner isDeleting={!!deletingId} />

      <StatsCards stats={stats} />

      <FilterPanel
        filters={filters}
        setFilters={setFilters}
        filteredCount={filteredActivities.length}
        totalCount={activities.length}
        isAdmin={isAdmin}
        activities={filteredActivities}
        asteriskFilter={asteriskFilter}
        setAsteriskFilter={setAsteriskFilter}
      />

      {/* Mobile/Tablet Card View */}
      <div className="max-w-7xl mx-auto lg:hidden space-y-3">
        {filteredActivities.map((activity) => (
          <ActivityCard
            key={activity.id}
            activity={activity}
            expandedRow={expandedRow}
            setExpandedRow={setExpandedRow}
            actionMenuOpen={actionMenuOpen}
            setActionMenuOpen={setActionMenuOpen}
            reclassifyMenuOpen={reclassifyMenuOpen}
            setReclassifyMenuOpen={setReclassifyMenuOpen}
            overlayingId={overlayingId}
            deletingId={deletingId}
            onOverlayActivity={onOverlayActivity}
            setOverlayingId={setOverlayingId}
            handleReclassify={handleReclassify}
            handleDelete={handleDelete}
            handleRetry={handleRetry}
          />
        ))}
      </div>

      {/* Desktop Table View */}
      <ActivityTable
        activities={filteredActivities}
        sortField={sortField}
        sortDirection={sortDirection}
        handleSort={handleSort}
        expandedRow={expandedRow}
        setExpandedRow={setExpandedRow}
        reclassifyMenuOpen={reclassifyMenuOpen}
        setReclassifyMenuOpen={setReclassifyMenuOpen}
        overlayingId={overlayingId}
        deletingId={deletingId}
        onOverlayActivity={onOverlayActivity}
        setOverlayingId={setOverlayingId}
        handleReclassify={handleReclassify}
        handleDelete={handleDelete}
        handleRetry={handleRetry}
        selectedIds={selectedIds}
        toggleSelection={toggleSelection}
        toggleAllSelection={toggleAllSelection}
        handleBulkDelete={handleBulkDelete}
        bulkDeleting={bulkDeleting}
        handleUpdateName={handleUpdateName}
        isAdmin={isAdmin}
      />
    </div>
  )
}
