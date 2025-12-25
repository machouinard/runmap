import { useState, useEffect, useCallback, lazy, Suspense, useMemo } from 'react'
import { MapComponent } from './components/Map'
import { ControlPanel } from './components/ControlPanel'
import { ErrorBoundary } from './components/ErrorBoundary'
import { AuthProvider, useAuth } from './contexts/AuthContext'
import { BASE_MAPS } from './types'
import { storage } from './lib/storage'
import { exportAsGeoJSON, exportAsCSV } from './lib/centroidExport'
import { parseGPX, type PlannedRoute } from './lib/gpxParser'
import { calculateBounds } from './lib/mapUtils'
import { COLOR_SCHEMES, DEFAULT_COLORS } from './lib/colorSchemes'
import { trackOverlayView, trackMapAction, trackRouteGeneration, trackPageView } from './lib/analytics'
// import { sortBlocksForRouting, type BlockWithEndpoints } from './lib/utils'
import type { LayerVisibility, CoverageStats, DateFilterState, DistanceFilterState } from './types'
import type { CentroidPoint } from './components/UnrunSegmentPanel'

// Lazy load components that are shown conditionally to reduce initial bundle size
const ProcessingQueue = lazy(() => import('./components/ProcessingQueue').then(m => ({ default: m.ProcessingQueue })))
const ActivityDashboard = lazy(() => import('./components/ActivityDashboard').then(m => ({ default: m.ActivityDashboard })))
const AdminLogin = lazy(() => import('./components/AdminLogin').then(m => ({ default: m.AdminLogin })))
const UnrunSegmentPanel = lazy(() => import('./components/UnrunSegmentPanel').then(m => ({ default: m.UnrunSegmentPanel })))

type ViewMode = 'map' | 'admin' | 'activities'

function AppContent() {
  const [currentView, setCurrentView] = useState<ViewMode>('map')
  const [baseMap, setBaseMap] = useState(storage.getBaseMap())
  const [layerVisibility, setLayerVisibility] = useState(storage.getLayerVisibility())
  const [dateFilter, setDateFilter] = useState<DateFilterState>({
    preset: 'all',
    startDate: null,
    endDate: null,
  })
  const [distanceFilter, setDistanceFilter] = useState<DistanceFilterState>({
    preset: 'all',
    minDistance: null,
    maxDistance: null,
  })
  const [stats, setStats] = useState<CoverageStats | null>(null)
  const [totalRuns, setTotalRuns] = useState<number>(0)
  const [totalMiles, setTotalMiles] = useState<number>(0)
  const [apiStatus, setApiStatus] = useState<'checking' | 'connected' | 'error'>('checking')
  const [showLoginModal, setShowLoginModal] = useState(false)
  const [flyToPosition, setFlyToPosition] = useState<{ center: [number, number]; zoom: number } | { bounds: [[number, number], [number, number]] } | null>(null)
  const [locationBounds, setLocationBounds] = useState<Record<string, any> | null>(null)

  // Polygon selection state
  const [isPolygonSelectionActive, setIsPolygonSelectionActive] = useState(false)
  const [centroids, setCentroids] = useState<CentroidPoint[]>([])
  const [blocks, setBlocks] = useState<any[]>([])
  const [centroidsAreaKm2, setCentroidsAreaKm2] = useState<number | undefined>(undefined)
  const [coordinatesString, setCoordinatesString] = useState<string>('')
  const [isLoadingCentroids, setIsLoadingCentroids] = useState(false)
  const [showCentroidsPanel, setShowCentroidsPanel] = useState(false)

  // Route overlay state (shared by GPX uploads and Valhalla routes)
  const [plannedRoute, setPlannedRoute] = useState<PlannedRoute | null>(null)
  const [showPlannedRoute, setShowPlannedRoute] = useState(true)

  // Valhalla route generation state
  const [isGeneratingRoute, setIsGeneratingRoute] = useState(false)
  const [routeInfo, setRouteInfo] = useState<any>(null)
  const [routeStartPoint, setRouteStartPoint] = useState<{ lat: number; lon: number } | null>(null)

  const { getAuthHeaders } = useAuth()

  // Check API health and load stats
  useEffect(() => {
    fetch('/api/health')
      .then(r => r.json())
      .then(data => {
        if (data.status === 'healthy') {
          setApiStatus('connected')
          loadStats()
          loadLocationBounds()
        } else {
          setApiStatus('error')
        }
      })
      .catch(() => setApiStatus('error'))
  }, [])

  const loadStats = () => {
    fetch('/api/stats')
      .then(r => r.json())
      .then(data => {
        setStats(data.coverage)
        setTotalRuns(data.total_runs || 0)
        // Convert km to miles immediately when storing
        setTotalMiles((data.total_km || 0) * 0.621371)
      })
      .catch(err => console.error('Failed to load stats:', err))
  }

  const loadLocationBounds = () => {
    fetch('/api/locations/bounds')
      .then(r => r.json())
      .then(data => setLocationBounds(data.bounds))
      .catch(err => console.error('Failed to load location bounds:', err))
  }

  // Handle base map change
  const handleBaseMapChange = (newMap: string) => {
    setBaseMap(newMap)
    storage.setBaseMap(newMap)
  }

  // Handle layer visibility change
  const handleLayerVisibilityChange = (newVisibility: LayerVisibility) => {
    setLayerVisibility(newVisibility)
    storage.setLayerVisibility(newVisibility)
  }

  // Handle map position change (save to localStorage)
  const handleMapPositionChange = (center: [number, number], zoom: number) => {
    storage.setMapPosition(center, zoom)
  }

  // Handle location jump
  const handleJumpToLocation = (location: 'sacramento' | 'portland') => {
    if (!locationBounds || !locationBounds[location]) {
      console.error('Location bounds not loaded')
      return
    }

    trackMapAction('jump_location', { location })

    const bounds = locationBounds[location]
    // MapLibre expects bounds as [[west, south], [east, north]]
    const mapBounds: [[number, number], [number, number]] = [
      [bounds.min_lng, bounds.min_lat],
      [bounds.max_lng, bounds.max_lat]
    ]

    setFlyToPosition({ bounds: mapBounds })
    // Reset after animation to allow future jumps to same location
    setTimeout(() => setFlyToPosition(null), 2000)
  }

  // Handle polygon selection toggle
  const handleTogglePolygonSelection = () => {
    if (isPolygonSelectionActive) {
      // Cancel: clear everything
      setIsPolygonSelectionActive(false)
      setCentroids([])
      setShowCentroidsPanel(false)
    } else {
      // Activate: start drawing mode
      trackMapAction('start_polygon_selection')
      setIsPolygonSelectionActive(true)
      setCentroids([])
      setShowCentroidsPanel(false)
    }
  }

  // Handle polygon completion (user finished drawing)
  const handlePolygonComplete = async (polygon: GeoJSON.Polygon) => {
    console.log('Polygon completed:', polygon)

    // Extract the first vertex as the start/end point for round-trip routing
    const firstVertex = polygon.coordinates[0][0] // [lon, lat]
    const startPoint = { lat: firstVertex[1], lon: firstVertex[0] }
    console.log('Round-trip start/end point:', startPoint)

    // Exit drawing mode
    setIsPolygonSelectionActive(false)
    setIsLoadingCentroids(true)
    setShowCentroidsPanel(true)

    try {
      console.log('Sending polygon to API:', polygon)
      console.log('Auth headers:', getAuthHeaders())

      const response = await fetch('/api/centroids/extract', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...getAuthHeaders(),
        },
        body: JSON.stringify({ polygon }),
      })

      console.log('API response status:', response.status)

      // Read response as text first, then parse
      const responseText = await response.text()
      console.log('Response text (first 500 chars):', responseText.substring(0, 500))

      let data
      try {
        data = JSON.parse(responseText)
        console.log('API response data:', data)
      } catch (jsonError) {
        console.error('Failed to parse JSON response:', jsonError)
        console.error('Full response text:', responseText)
        alert(`API Error: ${response.status} ${response.statusText}\n\nResponse:\n${responseText.substring(0, 200)}\n\nCheck console for full details.`)
        setShowCentroidsPanel(false)
        return
      }

      if (!response.ok) {
        const errorMsg = data.message || data.error || 'Unknown error'
        console.error('API returned error:', errorMsg)
        alert(`Error: ${errorMsg}`)
        setShowCentroidsPanel(false)
        return
      }

      console.log(`Extracted ${data.count} blocks (${data.waypoint_count} waypoints from API)`)

      // Track polygon completion
      trackMapAction('complete_polygon_selection', {
        block_count: data.count,
        area_km2: data.area_km2
      })

      // Sort blocks intelligently using nearest-neighbor TSP to minimize backtracking
      // For pgRouting, use only centroids (one waypoint per block) to avoid backtracking mess
      const blocks = data.blocks || []

      // Simple nearest-neighbor algorithm using centroids only
      const sortedBlocks: typeof blocks = []
      const remaining = [...blocks]
      let current = { lat: startPoint.lat, lon: startPoint.lon }

      while (remaining.length > 0) {
        let nearestIdx = 0
        let nearestDist = Infinity

        for (let i = 0; i < remaining.length; i++) {
          const block = remaining[i]
          const dist = Math.sqrt(
            Math.pow(block.centroid_lat - current.lat, 2) +
            Math.pow(block.centroid_lon - current.lon, 2)
          )
          if (dist < nearestDist) {
            nearestDist = dist
            nearestIdx = i
          }
        }

        const nearest = remaining.splice(nearestIdx, 1)[0]
        sortedBlocks.push(nearest)
        current = { lat: nearest.centroid_lat, lon: nearest.centroid_lon }
      }

      const sortedWaypoints = sortedBlocks.map((block: any) => ({
        lat: block.centroid_lat,
        lon: block.centroid_lon,
        block_id: block.block_id,
        street_name: block.street_name
      }))

      console.log(`Sorted ${sortedWaypoints.length} blocks (centroids only) using nearest-neighbor TSP`)

      // Add start point at the beginning and end for round-trip routing
      const roundTripWaypoints = [
        { lat: startPoint.lat, lon: startPoint.lon, block_id: 0, street_name: 'Start/End' },
        ...sortedWaypoints,
        { lat: startPoint.lat, lon: startPoint.lon, block_id: 0, street_name: 'Start/End' }
      ]

      // Generate sorted coordinate string for debugging
      const sortedCoordinatesString = roundTripWaypoints.map(w => `${w.lat},${w.lon}`).join(' ')

      // Convert blocks to centroid format for display (using centroid lat/lon)
      const centroidsForDisplay = blocks.map((block: any) => ({
        block_id: block.block_id,
        street_name: block.street_name,
        lat: block.centroid_lat,
        lon: block.centroid_lon,
        total_unvisited_length_m: block.total_unvisited_length_m,
        unvisited_segment_count: block.unvisited_segment_count,
        coverage_pct: block.coverage_pct,
        segment_ids: block.segment_ids
      }))
      setCentroids(centroidsForDisplay)
      setBlocks(blocks)
      setCentroidsAreaKm2(data.area_km2)
      setCoordinatesString(sortedCoordinatesString)
      setRouteStartPoint(startPoint) // Save for circular route generation

      // Reset route state when new polygon is selected
      setPlannedRoute(null)
      setRouteInfo(null)
    } catch (error) {
      console.error('Failed to extract centroids:', error)
      alert(`Failed to extract centroids: ${error instanceof Error ? error.message : String(error)}\n\nCheck console for details.`)
      setShowCentroidsPanel(false)
    } finally {
      setIsLoadingCentroids(false)
    }
  }

  // Handle polygon selection cancel
  const handlePolygonSelectionCancel = () => {
    setIsPolygonSelectionActive(false)
    setCentroids([])
    setBlocks([])
    setShowCentroidsPanel(false)
    setPlannedRoute(null)
    setRouteInfo(null)
  }

  // Handle Valhalla route generation
  const handleGenerateValhallaRoute = async () => {
    if (blocks.length === 0) {
      alert('No blocks available for routing')
      return
    }

    setIsGeneratingRoute(true)

    try {
      console.log('Generating Valhalla route for', blocks.length, 'blocks')

      const response = await fetch('/api/route/valhalla', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...getAuthHeaders(),
        },
        body: JSON.stringify({
          blocks: blocks,
          start_point: routeStartPoint, // First polygon click becomes route start/end
          use_optimized: true,
          max_retries: 2
        }),
      })

      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.message || 'Failed to generate route')
      }

      console.log('Valhalla route generated:', data)

      // Track route generation
      trackRouteGeneration('valhalla', {
        distance_km: data.route.properties.distance_km,
        time_seconds: data.route.properties.time_seconds,
        blocks_covered: data.coverage_validation.blocks_covered,
        blocks_total: data.coverage_validation.blocks_total,
        coverage_pct: data.coverage_validation.coverage_pct
      })

      // Convert to PlannedRoute format for the route overlay system
      const plannedRouteObj: PlannedRoute = {
        geojson: {
          type: 'Feature',
          geometry: data.route.geometry,
          properties: {
            name: 'Valhalla Route'
          }
        },
        source: {
          type: 'file', // Mark as 'file' type since it's a generated route
          distanceM: data.route.properties.distance_km * 1000,
          duration_seconds: data.route.properties.time_seconds
        }
      }

      // Store the route using the existing plannedRoute state
      setPlannedRoute(plannedRouteObj)
      setShowPlannedRoute(true) // Ensure route is visible

      // Store route info for panel display
      setRouteInfo({
        distance_km: data.route.properties.distance_km,
        time_seconds: data.route.properties.time_seconds,
        blocks_covered: data.coverage_validation.blocks_covered,
        blocks_total: data.coverage_validation.blocks_total,
        coverage_pct: data.coverage_validation.coverage_pct
      })

      console.log('Route coverage:', data.coverage_validation)

    } catch (error) {
      console.error('Failed to generate Valhalla route:', error)
      alert(`Failed to generate route: ${error instanceof Error ? error.message : String(error)}`)
    } finally {
      setIsGeneratingRoute(false)
    }
  }

  // Handle export actions
  const handleExportGeoJSON = () => {
    exportAsGeoJSON(centroids)
  }

  const handleExportCSV = () => {
    exportAsCSV(centroids)
  }

  const handleExportRouteGPX = async () => {
    if (!plannedRoute) {
      alert('No route generated yet')
      return
    }

    try {
      const response = await fetch('/api/route/valhalla/gpx', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...getAuthHeaders(),
        },
        body: JSON.stringify({
          route: plannedRoute.geojson
        }),
      })

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }

      // Download the GPX file
      const blob = await response.blob()
      const url = window.URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `valhalla-route-${new Date().toISOString().split('T')[0]}.gpx`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      window.URL.revokeObjectURL(url)
    } catch (error) {
      console.error('Failed to export route GPX:', error)
      alert(`Failed to export GPX: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  // Handle GPX upload for planned route overlay
  const handleGPXUpload = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]
    if (!file) return

    const reader = new FileReader()
    reader.onload = (e) => {
      const gpxText = e.target?.result as string
      if (!gpxText) return

      const geojson = parseGPX(gpxText)
      if (geojson) {
        trackRouteGeneration('gpx_upload', {
          route_name: geojson.properties.name,
          point_count: geojson.geometry.coordinates.length
        })
        setPlannedRoute({
          geojson,
          source: { type: 'file' }
        })
        setShowPlannedRoute(true)
        console.log(`Loaded planned route: ${geojson.properties.name} (${geojson.geometry.coordinates.length} points)`)
      } else {
        alert('Failed to parse GPX file. Please ensure it contains valid track data.')
      }
    }
    reader.readAsText(file)

    // Reset input so same file can be uploaded again
    event.target.value = ''
  }

  // Handle loading activity GPX from dashboard
  const handleLoadActivityOverlay = useCallback(async (activityId: string, activityType: 'run' | 'walk' | 'cycling') => {
    try {
      const response = await fetch(`/api/activities/${activityId}/gpx?type=${activityType}`)
      const data = await response.json()

      if (!response.ok || data.status !== 'success') {
        alert(data.error || 'Failed to load activity GPX')
        return
      }

      const geojson = parseGPX(data.gpx_content)
      if (geojson) {
        // Track activity overlay view
        trackOverlayView('activity_overlay', {
          activity_id: data.metadata.id,
          activity_type: data.metadata.type,
          location: data.metadata.location,
          distance_m: data.metadata.distance_m
        })

        setPlannedRoute({
          geojson,
          source: {
            type: 'activity',
            activityId: data.metadata.id,
            activityType: data.metadata.type,
            startTime: data.metadata.start_time,
            distanceM: data.metadata.distance_m,
            location: data.metadata.location,
            duration_seconds: data.metadata.duration_seconds
          }
        })
        setShowPlannedRoute(true)

        // Switch to map view and update URL with shareable link
        setCurrentView('map')
        const url = new URL(window.location.href)
        url.hash = ''
        url.searchParams.set('overlay', activityId)
        url.searchParams.set('type', activityType)
        window.history.pushState({}, '', url.toString())

        // Calculate bounds and zoom map to route
        // Delay slightly to ensure map component is mounted and ready
        const bounds = calculateBounds(geojson.geometry.coordinates)
        setTimeout(() => {
          setFlyToPosition({ bounds })
          setTimeout(() => setFlyToPosition(null), 2000)
        }, 100)

        console.log(`Loaded activity overlay: ${activityId} (${activityType})`)
      } else {
        alert('Failed to parse activity GPX data')
      }
    } catch (error) {
      console.error('Error loading activity overlay:', error)
      alert('Failed to load activity overlay')
    }
  }, [setPlannedRoute, setShowPlannedRoute, setCurrentView])

  // Handle clearing planned route overlay
  const handleClearPlannedRoute = useCallback(() => {
    setPlannedRoute(null)
    // Clear URL params when route is cleared
    const url = new URL(window.location.href)
    url.searchParams.delete('overlay')
    url.searchParams.delete('type')
    window.history.pushState({}, '', url.toString())
  }, [])

  // Check for URL query params to auto-load activity overlay
  useEffect(() => {
    const params = new URLSearchParams(window.location.search)
    const overlayId = params.get('overlay')
    const overlayType = params.get('type')

    if (overlayId && overlayType && (overlayType === 'run' || overlayType === 'walk' || overlayType === 'cycling')) {
      // Load the activity overlay
      handleLoadActivityOverlay(overlayId, overlayType)
    }
  }, [handleLoadActivityOverlay])

  const selectedBaseMapConfig = BASE_MAPS[baseMap]

  // Compute colors based on selected base map
  const colors = useMemo(() => COLOR_SCHEMES[baseMap] || DEFAULT_COLORS, [baseMap])

  // Check for URL hash and set view mode
  useEffect(() => {
    const handleHashChange = () => {
      const hash = window.location.hash
      if (hash === '#admin') {
        setCurrentView('admin')
        trackPageView('/admin', 'Admin Panel')
      } else if (hash === '#activities') {
        setCurrentView('activities')
        trackPageView('/activities', 'Activity Dashboard')
      } else {
        setCurrentView('map')
        trackPageView('/', 'Map View')
      }
    }

    // Set initial view
    handleHashChange()

    // Listen for hash changes
    window.addEventListener('hashchange', handleHashChange)

    return () => {
      window.removeEventListener('hashchange', handleHashChange)
    }
  }, [])

  // Render Activity Dashboard
  if (currentView === 'activities') {
    return (
      <Suspense fallback={<div className="flex items-center justify-center h-screen">Loading...</div>}>
        <ActivityDashboard onOverlayActivity={handleLoadActivityOverlay} />
      </Suspense>
    )
  }

  // Render Admin/Processing Queue
  if (currentView === 'admin') {
    return (
      <div style={{ width: '100%', minHeight: '100vh', backgroundColor: '#f9fafb' }}>
        <div className="bg-white border-b border-gray-200 px-6 py-4">
          <button
            onClick={() => {
              setCurrentView('map')
              window.location.hash = ''
            }}
            className="text-sm text-blue-600 hover:text-blue-800"
          >
            ← Back to Map
          </button>
        </div>
        <Suspense fallback={<div className="flex items-center justify-center p-8">Loading...</div>}>
          <ProcessingQueue />
        </Suspense>
      </div>
    )
  }

  return (
    <div style={{ width: '100%', height: '100vh', position: 'relative' }}>
      <MapComponent
        baseMap={baseMap}
        baseMapTiles={selectedBaseMapConfig.tiles}
        baseMapAttribution={selectedBaseMapConfig.attribution}
        layerVisibility={layerVisibility}
        dateFilter={dateFilter}
        distanceFilter={distanceFilter}
        onPositionChange={handleMapPositionChange}
        flyTo={flyToPosition}
        isPolygonSelectionActive={isPolygonSelectionActive}
        onPolygonComplete={handlePolygonComplete}
        onPolygonSelectionCancel={handlePolygonSelectionCancel}
        centroids={centroids}
        plannedRoute={plannedRoute}
        showPlannedRoute={showPlannedRoute}
        onClearPlannedRoute={handleClearPlannedRoute}
      />
      <ControlPanel
        selectedBaseMap={baseMap}
        layerVisibility={layerVisibility}
        colors={colors}
        dateFilter={dateFilter}
        distanceFilter={distanceFilter}
        apiStatus={apiStatus}
        stats={stats}
        totalRuns={totalRuns}
        totalMiles={totalMiles}
        onBaseMapChange={handleBaseMapChange}
        onLayerVisibilityChange={handleLayerVisibilityChange}
        onDateFilterChange={setDateFilter}
        onDistanceFilterChange={setDistanceFilter}
        onStatsRefresh={loadStats}
        onShowAdmin={() => {
          setCurrentView('admin')
          window.location.hash = 'admin'
        }}
        onShowActivities={() => {
          setCurrentView('activities')
          window.location.hash = 'activities'
        }}
        onShowLogin={() => setShowLoginModal(true)}
        onJumpToLocation={handleJumpToLocation}
        onTogglePolygonSelection={handleTogglePolygonSelection}
        isPolygonSelectionActive={isPolygonSelectionActive}
        onGPXUpload={handleGPXUpload}
        hasPlannedRoute={plannedRoute !== null}
        showPlannedRoute={showPlannedRoute}
        plannedRoute={plannedRoute}
        onTogglePlannedRoute={() => setShowPlannedRoute(!showPlannedRoute)}
        onClearPlannedRoute={handleClearPlannedRoute}
      />
      {showCentroidsPanel && (
        <ErrorBoundary>
          <Suspense fallback={null}>
            <UnrunSegmentPanel
              centroids={centroids}
              blocks={blocks}
              areaKm2={centroidsAreaKm2}
              isLoading={isLoadingCentroids}
              onClose={() => setShowCentroidsPanel(false)}
              onExportGeoJSON={handleExportGeoJSON}
              onExportCSV={handleExportCSV}
              onGenerateRoute={handleGenerateValhallaRoute}
              onExportRouteGPX={handleExportRouteGPX}
              coordinatesString={coordinatesString}
              routeGenerating={isGeneratingRoute}
              routeInfo={routeInfo}
            />
          </Suspense>
        </ErrorBoundary>
      )}
      <Suspense fallback={null}>
        <AdminLogin isOpen={showLoginModal} onClose={() => setShowLoginModal(false)} />
      </Suspense>
    </div>
  )
}

export default function App() {
  return (
    <AuthProvider>
      <AppContent />
    </AuthProvider>
  )
}
