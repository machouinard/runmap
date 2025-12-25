export interface Activity {
  id: string
  filename: string
  start_time: string
  total_distance_m: number
  duration_seconds: number
  location: string
  activity_type: 'run' | 'walk' | 'cycling'
  processing_status?: 'pending' | 'processing' | 'processed' | 'failed'
  processing_completed_at?: string
  uploaded_at: string
  route_name?: string
}

export interface Filters {
  location: string
  type: string
  status: string
  search: string
}

export interface ActivityDashboardProps {
  onOverlayActivity?: (activityId: string, activityType: 'run' | 'walk' | 'cycling') => void
}

export interface ActivityStats {
  total: number
  runs: Activity[]
  walks: Activity[]
  cycling: Activity[]
  sacramento: Activity[]
  portland: Activity[]
  other: Activity[]
}
