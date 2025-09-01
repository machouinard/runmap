import React, { useEffect, useRef, useState } from 'react'
import maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import { Protocol, PMTiles } from 'pmtiles'

const PM_TILES_URL = import.meta.env.VITE_PM_TILES_URL as string | undefined
const SUPABASE_URL = import.meta.env.VITE_PUBLIC_SUPABASE_URL as string
const ANON = import.meta.env.VITE_PUBLIC_SUPABASE_ANON_KEY as string

export default function App() {
  const mapRef = useRef<maplibregl.Map | null>(null)
  const [stats, setStats] = useState<{ total_m: number; covered_m: number; pct: number } | null>(null)

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

    // Pre-register PMTiles archive (so we can read header/bounds easily)
    let pm: PMTiles | null = null
    if (PM_TILES_URL) {
      pm = new PMTiles(PM_TILES_URL)
      protocol.add(pm)
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

    // Add vector source via pmtiles url (TileJSON) if configured
    if (PM_TILES_URL) {
      style.sources.unrun = {
        type: 'vector',
        url: 'pmtiles://' + PM_TILES_URL,
        attribution: 'Runmap',
      }
      style.layers.push({
        id: 'unrun-line',
        type: 'line',
        source: 'unrun',
        'source-layer': 'streets_unrun', // If you see nothing, try 'layer0'
        paint: { 'line-color': '#e53935', 'line-width': 1.2 },
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
      // Fit to PMTiles bounds if present
      if (pm) {
        pm.getHeader().then((h) => {
          const b: [[number, number], [number, number]] = [
            [h.minLon, h.minLat],
            [h.maxLon, h.maxLat],
          ]
          map.fitBounds(b, { padding: 20 })
        })
      }
    })

    return () => {
      map.remove()
      mapRef.current = null
      maplibregl.removeProtocol('pmtiles')
    }
  }, [])

  const prettyKm = (m?: number) => (m ? (m / 1000).toFixed(1) : '—')

  return (
    <div style={{ height: '100%' }}>
      <div id="map" style={{ height: '100%' }} />
      <div
        id="panel"
        style={{
          position: 'absolute',
          top: 12,
          left: 12,
          background: 'rgba(255,255,255,0.9)',
          padding: '10px 12px',
          borderRadius: 6,
          fontFamily: 'Inter, system-ui, -apple-system, sans-serif',
          fontSize: 12,
        }}
      >
        <div><strong>Tiles:</strong> {PM_TILES_URL ? 'loaded' : 'missing VITE_PM_TILES_URL'}</div>
        {stats && (
          <div>
            <strong>Coverage:</strong> {stats.pct.toFixed(1)}% ({prettyKm(stats.covered_m)} / {prettyKm(stats.total_m)} km)
          </div>
        )}
      </div>
    </div>
  )
}