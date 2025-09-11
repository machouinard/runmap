import React, { useEffect, useRef, useState } from 'react'
import maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { Protocol, PMTiles } from 'pmtiles'

const PM_TILES_URL_UNRUN = import.meta.env.VITE_PM_TILES_URL as string | undefined
const PM_TILES_URL_RUNS = import.meta.env.VITE_PM_TILES_URL_RUNS as string | undefined
const PM_TILES_URL_BUFFER = import.meta.env.VITE_PM_TILES_URL_BUFFER as string | undefined
const TILES_VERSION_ENV = (import.meta.env.VITE_TILES_VERSION as string | undefined) || ''
const COLOR_UNRUN = (import.meta.env.VITE_UNRUN as string) || '#B22222'
// const COLOR_RUNS = (import.meta.env.VITE_RUNS as string) || '#0e297cff'
const COLOR_RUNS = (import.meta.env.VITE_RUNS as string) || '#1A9E4C'
const COLOR_BUFFER = (import.meta.env.VITE_BUFFER as string) || '#1F9A4E'
// const COLOR_BUFFER = (import.meta.env.VITE_BUFFER as string) || '#006400'
const SUPABASE_URL = import.meta.env.VITE_PUBLIC_SUPABASE_URL as string
const ANON = import.meta.env.VITE_PUBLIC_SUPABASE_ANON_KEY as string
const MAPTILER_KEY = import.meta.env.VITE_MAPTILER_KEY as string

export default function App() {
  const mapRef = useRef<maplibregl.Map | null>(null)
  const [stats, setStats] = useState<{ total_m: number; covered_m: number; pct: number } | null>(null)
  // Initial visibility from ?run=1&unrun=1&buffer=1 (defaults to enabled when URL is configured)
  const parseFlag = (v: string | null, def: boolean) => {
    if (v == null) return def
    const s = v.toLowerCase()
    return s === '1' || s === 'true' || s === 'on' || s === 'yes'
  }
  const computeInitialVisibility = () => {
    const defaults = {
      unrun: 0,
      run: !!PM_TILES_URL_RUNS,
      buffer: !!PM_TILES_URL_BUFFER,
    }
    try {
      const p = new URLSearchParams(window.location.search)
      return {
        unrun: !!PM_TILES_URL_UNRUN && parseFlag(p.get('unrun'), defaults.unrun),
        run: !!PM_TILES_URL_RUNS && parseFlag(p.get('run'), defaults.run),
        buffer: !!PM_TILES_URL_BUFFER && parseFlag(p.get('buffer'), defaults.buffer),
      }
    } catch {
      return defaults
    }
  }
  const initialVis = computeInitialVisibility()
  const [showUnrun, setShowUnrun] = useState<boolean>(initialVis.unrun)
  const [showRuns, setShowRuns] = useState<boolean>(initialVis.run)
  const [showBuffer, setShowBuffer] = useState<boolean>(initialVis.buffer)
  const [tilesVersion, setTilesVersion] = useState<string>(TILES_VERSION_ENV)
  const withVersion = (url?: string) => (url ? (tilesVersion ? `${url}?v=${encodeURIComponent(tilesVersion)}` : url) : undefined)

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

    // Try to read dynamic tiles version from version.json in the tiles folder
    const loadVersion = async () => {
      try {
        const pick = PM_TILES_URL_UNRUN || PM_TILES_URL_BUFFER || PM_TILES_URL_RUNS
        if (!pick) return
        const u = new URL(pick)
        // strip filename
        u.pathname = u.pathname.replace(/\/[^\/?#]+$/, '/version.json')
        u.search = ''
        const res = await fetch(u.toString(), { cache: 'no-cache' })
        if (!res.ok) return
        const j = await res.json()
        if (j && typeof j.v === 'string' && j.v.length > 0) setTilesVersion(j.v)
      } catch { }
    }
    if (!TILES_VERSION_ENV) loadVersion()

    // Pre-register PMTiles archives (so we can read header/bounds easily)
    let pmUnrun: PMTiles | null = null
    let pmRuns: PMTiles | null = null
    let pmBuffer: PMTiles | null = null
    if (PM_TILES_URL_UNRUN) {
      pmUnrun = new PMTiles(withVersion(PM_TILES_URL_UNRUN)!)
      protocol.add(pmUnrun)
    }
    if (PM_TILES_URL_RUNS) {
      pmRuns = new PMTiles(withVersion(PM_TILES_URL_RUNS)!)
      protocol.add(pmRuns)
    }
    if (PM_TILES_URL_BUFFER) {
      pmBuffer = new PMTiles(withVersion(PM_TILES_URL_BUFFER)!)
      protocol.add(pmBuffer)
    }

    const style: any = {
      version: 8,
      sources: {
        satellite: {
          type: 'raster',
          // tiles: [`https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=${MAPTILER_KEY}`],
          tiles: ['https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=JxYIXYYsMJDhbpq83ADA#1.0/0.00000/0.00000'],
          tileSize: 256,
          attribution: '© MapTiler © OpenStreetMap contributors',
        },
      },
      layers: [{ id: 'satellite', type: 'raster', source: 'satellite' }],
    }

    // Add vector sources via pmtiles urls (TileJSON) if configured
    // Draw order: buffer (bottom) → unrun → runs (top)
    if (PM_TILES_URL_BUFFER) {
      style.sources.buffer = {
        type: 'vector',
        url: 'pmtiles://' + withVersion(PM_TILES_URL_BUFFER),
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
        url: 'pmtiles://' + withVersion(PM_TILES_URL_UNRUN),
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
        url: 'pmtiles://' + withVersion(PM_TILES_URL_RUNS),
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
      // Ensure map fills current viewport after initial paint
      try { map.resize() } catch { }
      setTimeout(() => { try { map.resize() } catch { } }, 200)

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

  // Sync current visibility to URL flags (?run=1&unrun=1&buffer=1) without reload
  useEffect(() => {
    try {
      const params = new URLSearchParams(window.location.search)
      params.set('run', showRuns ? '1' : '0')
      params.set('unrun', showUnrun ? '1' : '0')
      params.set('buffer', showBuffer ? '1' : '0')
      const q = params.toString()
      const newUrl = `${window.location.pathname}${q ? `?${q}` : ''}${window.location.hash}`
      window.history.replaceState(null, '', newUrl)
    } catch { }
  }, [showUnrun, showRuns, showBuffer])

  const prettyKm = (m?: number) => (m ? (m / 1000).toFixed(1) : '—')
  const prettyMi = (m?: number) => (m ? (m * 0.000621371).toFixed(1) : '—')

  // Simple mobile detection
  const [isNarrow, setIsNarrow] = useState<boolean>(false)
  const [openLayers, setOpenLayers] = useState<boolean>(false)
  useEffect(() => {
    const onResize = () => {
      setIsNarrow(window.innerWidth <= 640)
      try {
        // Ensure MapLibre tracks container size changes (orientation, URL bar collapse)
        mapRef.current?.resize()
      } catch { }
    }
    onResize()
    window.addEventListener('resize', onResize)
    window.addEventListener('orientationchange', onResize)
    return () => {
      window.removeEventListener('resize', onResize)
      window.removeEventListener('orientationchange', onResize)
    }
  }, [])

  return (
    <div style={{ height: '100%' }}>
      <div id="map" style={{ height: '100%' }} />

      {/* Bottom stats bar */}
      {stats && false && (
        <div
          style={{
            position: 'absolute', left: 12, right: 12, top: 12,
            display: 'flex', gap: 8, alignItems: 'stretch', justifyContent: 'space-between',
            padding: '8px 10px', borderRadius: 12,
            background: 'rgba(255,255,255,0.94)', boxShadow: '0 6px 18px rgba(0,0,0,0.12)',
            border: '1px solid rgba(0,0,0,0.08)', fontFamily: 'Inter, system-ui, -apple-system, sans-serif',
            fontSize: isNarrow ? 13 : 12, backdropFilter: 'saturate(180%) blur(6px)'
          }}
        >
          <div style={{ display: 'grid', minWidth: 92 }}>
            <div style={{ opacity: 0.75 }}>Coverage</div>
            <div style={{ fontWeight: 700 }}>{stats.pct.toFixed(1)}%</div>
          </div>
          <div style={{ display: 'grid', minWidth: 120, textAlign: 'right' }}>
            <div style={{ opacity: 0.75 }}>Covered</div>
            <div>{prettyMi(stats.covered_m)} mi <span style={{ opacity: 0.6 }}>({prettyKm(stats.covered_m)} km)</span></div>
          </div>
          <div style={{ display: 'grid', minWidth: 120, textAlign: 'right' }}>
            <div style={{ opacity: 0.75 }}>Total</div>
            <div>{prettyMi(stats.total_m)} mi <span style={{ opacity: 0.6 }}>({prettyKm(stats.total_m)} km)</span></div>
          </div>
        </div>
      )}

      {/* Floating Layers button bottom-left */}
      <button
        onClick={() => setOpenLayers(true)} aria-label="Layers"
        style={{ position: 'absolute', left: 12, bottom: 12, padding: '10px 12px', borderRadius: 10, border: '1px solid rgba(0,0,0,0.12)', color: '#fff', background: '#26197aff', boxShadow: '0 4px 10px rgba(0,0,0,0.08)', fontSize: 24 }}
      >Layers</button>

      {/* Layers popover */}
      {openLayers && (
        <>
          <div onClick={() => setOpenLayers(false)} style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.25)' }} />
          <div role="dialog" aria-modal="true"
            style={{ position: 'absolute', left: '50%', top: isNarrow ? 64 : 100, transform: 'translateX(-50%)', width: 'min(92%, 360px)', background: '#fff', borderRadius: 12, boxShadow: '0 16px 32px rgba(0,0,0,0.24)', border: '1px solid rgba(0,0,0,0.08)', padding: 14, fontFamily: 'Inter, system-ui, -apple-system, sans-serif', fontSize: isNarrow ? 14 : 13 }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <div style={{ fontWeight: 700 }}>Layers</div>
              <button onClick={() => setOpenLayers(false)} aria-label="Close" style={{ background: 'transparent', border: 0, fontSize: 16 }}>✕</button>
            </div>
            <div style={{ display: 'grid', rowGap: 8 }}>
              <label style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                <input style={{ width: 18, height: 18 }} type="checkbox" checked={showUnrun} onChange={e => setShowUnrun(e.target.checked)} disabled={!PM_TILES_URL_UNRUN} />
                Needed (red)
              </label>
              <label style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                <input style={{ width: 18, height: 18 }} type="checkbox" checked={showRuns} onChange={e => setShowRuns(e.target.checked)} disabled={!PM_TILES_URL_RUNS} />
                Done (blue)
              </label>
              <label style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                <input style={{ width: 18, height: 18 }} type="checkbox" checked={showBuffer} onChange={e => setShowBuffer(e.target.checked)} disabled={!PM_TILES_URL_BUFFER} />
                Coverage (green)
              </label>
            </div>
          </div>
        </>
      )}
    </div>
  )
}