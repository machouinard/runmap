import { useState, useEffect } from 'react'
import { useAuth } from '../../contexts/AuthContext'
import { Activity, Filters, ActivityStats } from './types'
import { trackDashboardAction } from '../../lib/analytics'

export function useActivities() {
  const { isAdmin, getAuthHeaders } = useAuth()
  const [activities, setActivities] = useState<Activity[]>([])
  const [filteredActivities, setFilteredActivities] = useState<Activity[]>([])
  const [loading, setLoading] = useState(true)
  const [filters, setFilters] = useState<Filters>(() => {
    const saved = localStorage.getItem('runmap_dashboard_filters')
    if (saved) {
      try {
        return JSON.parse(saved)
      } catch (e) {
        console.error('Failed to parse saved filters', e)
      }
    }
    return {
      location: 'all',
      type: 'all',
      status: 'all',
      search: ''
    }
  })
  const [sortField, setSortField] = useState<keyof Activity>('start_time')
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc')
  const [deletingId, setDeletingId] = useState<string | null>(null)
  const [overlayingId, setOverlayingId] = useState<string | null>(null)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [bulkDeleting, setBulkDeleting] = useState(false)
  const [asteriskFilter, setAsteriskFilter] = useState(() => {
    const saved = localStorage.getItem('runmap_dashboard_asterisk')
    return saved ? JSON.parse(saved) : false
  })

  // Load activities
  useEffect(() => {
    loadActivities()
  }, [])

  useEffect(() => {
    localStorage.setItem('runmap_dashboard_filters', JSON.stringify(filters))
  }, [filters])

  useEffect(() => {
    localStorage.setItem('runmap_dashboard_asterisk', JSON.stringify(asteriskFilter))
  }, [asteriskFilter])

  // Apply filters and sorting
  useEffect(() => {
    let filtered = [...activities]

    if (filters.location !== 'all') {
      filtered = filtered.filter(a => a.location === filters.location)
    }

    if (filters.type !== 'all') {
      filtered = filtered.filter(a => a.activity_type === filters.type)
    }

    if (filters.status !== 'all' && filters.status) {
      filtered = filtered.filter(a => a.processing_status === filters.status)
    }

    if (filters.search) {
      const search = filters.search
      
      // Try to create regex
      let regex: RegExp | null = null
      try {
        regex = new RegExp(search, 'i')
      } catch (e) {
        // Invalid regex, ignore
      }

      const searchLower = search.toLowerCase()

      filtered = filtered.filter(a => {
        const dateStr = new Date(a.start_time).toLocaleDateString()
        const dateTimeStr = new Date(a.start_time).toLocaleString()
        
        if (regex) {
          return regex.test(dateStr) || 
                 regex.test(dateTimeStr) || 
                 regex.test(a.filename) || 
                 regex.test(a.route_name || '')
        }

        return dateStr.toLowerCase().includes(searchLower) ||
          dateTimeStr.toLowerCase().includes(searchLower) ||
          a.filename.toLowerCase().includes(searchLower) ||
          (a.route_name || '').toLowerCase().includes(searchLower)
      })
    }

    if (asteriskFilter) {
      filtered = filtered.filter(a => a.route_name && a.route_name.includes('*'))
    }

    // Sort
    filtered.sort((a, b) => {
      let aVal: any = a[sortField]
      let bVal: any = b[sortField]

      if (aVal == null) return 1
      if (bVal == null) return -1

      // Special handling for date fields
      if (sortField === 'start_time' || sortField === 'uploaded_at' || sortField === 'processing_completed_at') {
        aVal = new Date(aVal).getTime()
        bVal = new Date(bVal).getTime()
      }

      if (aVal < bVal) return sortDirection === 'asc' ? -1 : 1
      if (aVal > bVal) return sortDirection === 'asc' ? 1 : -1
      return 0
    })

    setFilteredActivities(filtered)
  }, [activities, filters, sortField, sortDirection, asteriskFilter])

  const loadActivities = async () => {
    try {
      const response = await fetch('/api/activities')
      const data = await response.json()
      if (data.status === 'ok') {
        setActivities(data.activities)
      }
    } catch (error) {
      console.error('Failed to load activities:', error)
    } finally {
      setLoading(false)
    }
  }

  const handleSort = (field: keyof Activity) => {
    if (sortField === field) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc')
    } else {
      setSortField(field)
      setSortDirection('desc')
    }
  }

  const toggleSelection = (id: string) => {
    const newSelected = new Set(selectedIds)
    if (newSelected.has(id)) {
      newSelected.delete(id)
    } else {
      newSelected.add(id)
    }
    setSelectedIds(newSelected)
  }

  const toggleAllSelection = () => {
    if (selectedIds.size === filteredActivities.length) {
      setSelectedIds(new Set())
    } else {
      setSelectedIds(new Set(filteredActivities.map(a => a.id)))
    }
  }

  const handleBulkDelete = async () => {
    if (!isAdmin) {
      alert('Admin access required')
      return
    }

    if (!confirm(`Delete ${selectedIds.size} activities? This cannot be undone.`)) {
      return
    }

    trackDashboardAction('bulk_delete', undefined, { count: selectedIds.size })

    setBulkDeleting(true)
    try {
      // 1. Delete all activities (skipping tile regen)
      const promises = Array.from(selectedIds).map(async (id) => {
        const activity = activities.find(a => a.id === id)
        if (activity) {
          await fetch(`/api/activities/delete/${id}?type=${activity.activity_type}&skip_tile_update=true`, {
            method: 'DELETE',
            headers: getAuthHeaders()
          })
        }
      })
      
      await Promise.all(promises)

      // 2. Regenerate tiles once at the end
      await fetch('/api/tiles/regenerate', {
        method: 'POST',
        headers: getAuthHeaders()
      })

      await loadActivities()
      setSelectedIds(new Set())
      alert('Activities deleted and tiles regenerated successfully!')
    } catch (error) {
      alert(`Failed to bulk delete: ${error}`)
    } finally {
      setBulkDeleting(false)
    }
  }

  const handleUpdateName = async (id: string, newName: string, type: string) => {
    if (!isAdmin) return

    try {
      const response = await fetch(`/api/activities/${id}/name`, {
        method: 'PUT',
        headers: {
          ...getAuthHeaders(),
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ name: newName, type })
      })

      const data = await response.json()
      if (data.status === 'success') {
        await loadActivities()
      } else {
        alert(`Error: ${data.error}`)
      }
    } catch (error) {
      alert(`Failed to update name: ${error}`)
    }
  }

  const handleReclassify = async (activity: Activity, newType: 'run' | 'walk' | 'cycling') => {
    if (!isAdmin) {
      alert('Admin access required to reclassify activities')
      return
    }

    if (!confirm(`Change "${activity.filename}" from ${activity.activity_type} to ${newType}?`)) {
      return
    }

    trackDashboardAction('reclassify', activity.activity_type, {
      old_type: activity.activity_type,
      new_type: newType,
      location: activity.location
    })

    try {
      const response = await fetch('/api/activities/reclassify', {
        method: 'POST',
        headers: getAuthHeaders(),
        body: JSON.stringify({
          id: activity.id,
          current_type: activity.activity_type,
          new_type: newType
        })
      })

      const data = await response.json()
      if (data.status === 'success') {
        await loadActivities()
        alert(`Activity reclassified to ${newType}`)
      } else {
        alert(`Error: ${data.error}`)
      }
    } catch (error) {
      alert(`Failed to reclassify: ${error}`)
    }
  }

  const handleDelete = async (activity: Activity) => {
    if (!isAdmin) {
      alert('Admin access required to delete activities')
      return
    }

    if (!confirm(`Delete "${activity.filename}"? This cannot be undone.\n\nThis will delete the activity, recalculate coverage, and regenerate map tiles (may take up to 2 minutes).`)) {
      return
    }

    trackDashboardAction('delete', activity.activity_type, {
      location: activity.location,
      distance_m: activity.total_distance_m
    })

    setDeletingId(activity.id)
    try {
      const response = await fetch(`/api/activities/delete/${activity.id}?type=${activity.activity_type}`, {
        method: 'DELETE',
        headers: getAuthHeaders()
      })

      const data = await response.json()
      if (data.status === 'success') {
        await loadActivities()
        alert('Activity deleted and tiles regenerated successfully!')
      } else {
        alert(`Error: ${data.error}`)
      }
    } catch (error) {
      alert(`Failed to delete: ${error}`)
    } finally {
      setDeletingId(null)
    }
  }

  const handleRetry = async (activity: Activity) => {
    if (!isAdmin) {
      alert('Admin access required to retry processing')
      return
    }

    trackDashboardAction('retry_processing', activity.activity_type, {
      location: activity.location
    })

    try {
      const response = await fetch(`/api/processing-queue/retry/${activity.id}`, {
        method: 'POST',
        headers: getAuthHeaders()
      })

      const data = await response.json()
      if (data.status === 'success') {
        await loadActivities()
        alert(data.message || 'Processing retry initiated')
      } else {
        alert(`Error: ${data.error}`)
      }
    } catch (error) {
      alert(`Failed to retry: ${error}`)
    }
  }

  // Calculate stats
  const stats: ActivityStats = {
    total: activities.length,
    runs: activities.filter(a => a.activity_type === 'run'),
    walks: activities.filter(a => a.activity_type === 'walk'),
    cycling: activities.filter(a => a.activity_type === 'cycling'),
    sacramento: activities.filter(a => a.location === 'sacramento'),
    portland: activities.filter(a => a.location === 'portland'),
    other: activities.filter(a => a.location === 'other')
  }

  return {
    // State
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

    // Setters
    setFilters,
    setOverlayingId,
    setAsteriskFilter,

    // Actions
    loadActivities,
    handleSort,
    handleReclassify,
    handleDelete,
    handleRetry,
    toggleSelection,
    toggleAllSelection,
    handleBulkDelete,
    handleUpdateName
  }
}
