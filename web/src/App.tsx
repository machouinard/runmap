import React, { useEffect, useRef, useState } from 'react'
import maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { Protocol, PMTiles } from 'pmtiles'

const PM_TILES_URL_UNRUN = import.meta.env.VITE_PM_TILES_URL as string | undefined
const PM_TILES_URL_RUNS = import.meta.env.VITE_PM_TILES_URL_RUNS as string | undefined
const PM_TILES_URL_BUFFER = import.meta.env.VITE_PM_TILES_URL_BUFFER as string | undefined
const COLOR_UNRUN = (import.meta.env.VITE_UNRUN as string) || '#e53935'
const COLOR_RUNS = (import.meta.env.VITE_RUNS as string) || '#1e88e5'
const COLOR_BUFFER = (import.meta.env.VITE_BUFFER as string) || '#7e57c2'
const SUPABASE_URL = import.meta.env.VITE_PUBLIC_SUPABASE_URL as string
const ANON = import.meta.env.VITE_PUBLIC_SUPABASE_ANON_KEY as string

export default function App() {
  const mapRef = useRef<maplibregl.Map | null>(null)
  const [stats, setStats] = useState<{ total_m: number; covered_m: number; pct: number } | null>(null)
  const [showUnrun, setShowUnrun] = useState<boolean>(!!PM_TILES_URL_UNRUN)
  const [showRuns, setShowRuns] = useState<boolean>(!!PM_TILES_URL_RUNS)
  const [showBuffer, setShowBuffer] = useState<boolean>(!!PM_TILES_URL_BUFFER)

  useEffect(() => {
    // Fetch public stats
    const fetchStats = async () => {
      try {
        const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_public_stats`, {
          method: 'POST',
          headers: {
            apikey: ANON,
            Authorization: `Bearer ${ANON}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({}),
        })
        if (!res.ok) return
        const rows = await res.json()
        if (Array.isArray(rows) && rows.length > 0) setStats(rows[0])
      } catch { }
    }
    fetchStats()
  }, [])

  useEffect(() => {
    const protocol = new Protocol()
    maplibregl.addProtocol('pmtiles', protocol.tile)

    // Pre-register PMTiles archives (so we can read header/bounds easily)
    let pmUnrun: PMTiles | null = null
    let pmRuns: PMTiles | null = null
    let pmBuffer: PMTiles | null = null
    if (PM_TILES_URL_UNRUN) {
      pmUnrun = new PMTiles(PM_TILES_URL_UNRUN)
      protocol.add(pmUnrun)
    }
    if (PM_TILES_URL_RUNS) {
      pmRuns = new PMTiles(PM_TILES_URL_RUNS)
      protocol.add(pmRuns)
    }
    if (PM_TILES_URL_BUFFER) {
      pmBuffer = new PMTiles(PM_TILES_URL_BUFFER)
      protocol.add(pmBuffer)
    }

    const style: any = {
      version: 8,
      sources: {
        osm: {
          type: 'raster',
          tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
          tileSize: 256,
          attribution: '© OpenStreetMap contributors',
        },
      },
      layers: [{ id: 'osm', type: 'raster', source: 'osm' }],
    }

    // Add vector sources via pmtiles urls (TileJSON) if configured
    // Draw order: buffer (bottom) → unrun → runs (top)
    if (PM_TILES_URL_BUFFER) {
      style.sources.buffer = {
        type: 'vector',
        url: 'pmtiles://' + PM_TILES_URL_BUFFER,
        attribution: 'Runmap',
      }
      style.layers.push({
        id: 'buffer-fill',
        type: 'fill',
        source: 'buffer',
        'source-layer': 'coverage_buffer',
        paint: { 'fill-color': COLOR_BUFFER, 'fill-opacity': 0.35 },
      })
    }
    if (PM_TILES_URL_UNRUN) {
      style.sources.unrun = {
        type: 'vector',
        url: 'pmtiles://' + PM_TILES_URL_UNRUN,
        attribution: 'Runmap',
      }
      style.layers.push({
        id: 'unrun-line',
        type: 'line',
        source: 'unrun',
        'source-layer': 'streets_unrun',
        paint: { 'line-color': COLOR_UNRUN, 'line-width': 1.4, 'line-opacity': 1.0 },
      })
    }
    if (PM_TILES_URL_RUNS) {
      style.sources.runs = {
        type: 'vector',
        url: 'pmtiles://' + PM_TILES_URL_RUNS,
        attribution: 'Runmap',
      }
      style.layers.push({
        id: 'runs-line',
        type: 'line',
        source: 'runs',
        'source-layer': 'runs_collect',
        paint: { 'line-color': COLOR_RUNS, 'line-width': 1.4, 'line-opacity': 1.0 },
      })
    }

    const map = new maplibregl.Map({
      container: 'map',
      style,
      center: [-121.4944, 38.5816],
      zoom: 11,
    })
    mapRef.current = map

    map.on('load', () => {
      // Fit to PMTiles bounds if present (prefer unrun, else runs, else buffer)
      const pm = pmUnrun || pmRuns || pmBuffer
      if (pm) {
        pm.getHeader().then((h) => {
          const b: [[number, number], [number, number]] = [
            [h.minLon, h.minLat],
            [h.maxLon, h.maxLat],
          ]
          map.fitBounds(b, { padding: 20 })
        })
      }
      // Initialize visibility
      const setVis = (id: string, visible: boolean) => {
        if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', visible ? 'visible' : 'none')
      }
      setVis('unrun-line', showUnrun)
      setVis('runs-line', showRuns)
      setVis('buffer-fill', showBuffer)
    })

    return () => {
      map.remove()
      mapRef.current = null
      maplibregl.removeProtocol('pmtiles')
    }
  }, [])

  // React to toggle changes after map load
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    const setVis = (id: string, visible: boolean) => {
      if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', visible ? 'visible' : 'none')
    }
    setVis('unrun-line', showUnrun)
    setVis('runs-line', showRuns)
    setVis('buffer-fill', showBuffer)
  }, [showUnrun, showRuns, showBuffer])

  const prettyKm = (m?: number) => (m ? (m / 1000).toFixed(1) : '—')
   const prettyMi = (m?: number) => (m ? (m * 0.000621371).toFixed(1) : '—')
  
  return (
  <div style={{ height: '100%' }}>
  <div id="map" style={{ height: '100%' }} />
       <div
        id="panel"
        style={{
          position: 'absolute',
          top: 12,
          left: 12,
          background: 'rgba(255,255,255,0.95)',
          padding: '12px 14px',
          borderRadius: 10,
          boxShadow: '0 8px 24px rgba(0,0,0,0.12)',
          border: '1px solid rgba(0,0,0,0.08)',
          backdropFilter: 'saturate(180%) blur(8px)',
          fontFamily: 'Inter, system-ui, -apple-system, sans-serif',
          fontSize: 12,
          minWidth: 280,
        }}
      >
        <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 8 }}>Run Coverage</div>
        <div style={{ marginBottom: 6 }}>
          <strong>Layers</strong>
          <div>
            <label><input type="checkbox" checked={showUnrun} onChange={(e) => setShowUnrun(e.target.checked)} disabled={!PM_TILES_URL_UNRUN} /> Needed (red)</label>
          </div>
          <div>
            <label><input type="checkbox" checked={showRuns} onChange={(e) => setShowRuns(e.target.checked)} disabled={!PM_TILES_URL_RUNS} /> Done (blue)</label>
          </div>
          <div>
            <label><input type="checkbox" checked={showBuffer} onChange={(e) => setShowBuffer(e.target.checked)} disabled={!PM_TILES_URL_BUFFER} /> Coverage (purple)</label>
          </div>
        </div>
        <div>
          <strong>Status</strong>
          <div>
            tiles: <span>unrun: {PM_TILES_URL_UNRUN ? 'ok' : 'missing'}</span>, <span>runs: {PM_TILES_URL_RUNS ? 'ok' : 'off'}</span>, <span>buffer: {PM_TILES_URL_BUFFER ? 'ok' : 'off'}</span>
          </div>
        </div>
        {stats && (
          <div style={{ marginTop: 8 }}>
            <div style={{ fontWeight: 600, marginBottom: 4 }}>Stats</div>
            <div style={{ display: 'grid', gridTemplateColumns: 'auto auto', columnGap: 12, rowGap: 4 }}>
              <div>Coverage</div>
              <div><strong>{stats.pct.toFixed(1)}%</strong></div>
              <div>Covered</div>
              <div>{prettyMi(stats.covered_m)} mi <span style={{ opacity: 0.7 }}>({prettyKm(stats.covered_m)} km)</span></div>
              <div>Total</div>
              <div>{prettyMi(stats.total_m)} mi <span style={{ opacity: 0.7 }}>({prettyKm(stats.total_m)} km)</span></div>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}