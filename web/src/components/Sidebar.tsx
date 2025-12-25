import type { CoverageStats, LayerVisibility } from '@/types'

interface SidebarProps {
  apiStatus: 'checking' | 'connected' | 'error'
  stats: CoverageStats | null
  baseMap: string
  layerVisibility: LayerVisibility
  onBaseMapChange: (baseMap: string) => void
  onLayerVisibilityChange: (visibility: LayerVisibility) => void
  onStatsRefresh: () => void
}

export function Sidebar({
  apiStatus,
  stats,
  // baseMap,
  // layerVisibility,
  // onBaseMapChange,
  // onLayerVisibilityChange,
  // onStatsRefresh,
}: SidebarProps) {
  // Stub component - will build this out next
  // (Props commented out to avoid TS errors until we use them)
  return (
    <div style={{
      position: 'absolute',
      top: '10px',
      left: '10px',
      background: 'white',
      padding: '15px',
      borderRadius: '8px',
      boxShadow: '0 2px 8px rgba(0,0,0,0.2)',
      maxWidth: '300px',
      zIndex: 1,
    }}>
      <h2 style={{ margin: '0 0 10px 0', fontSize: '20px' }}>Sacramento RunMap</h2>
      <p>
        API: <span>{apiStatus === 'checking' ? 'Checking...' : apiStatus === 'connected' ? '✅ Connected' : '❌ Error'}</span>
      </p>
      {stats && (
        <p>
          Coverage: {stats.block_completion_pct.toFixed(1)}% ({stats.complete_blocks}/{stats.total_blocks} blocks)
        </p>
      )}
      <p style={{ fontSize: '12px', color: '#666', marginTop: '10px' }}>
        Sidebar UI components coming next...
      </p>
    </div>
  )
}
