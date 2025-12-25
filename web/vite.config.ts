import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'
import fs from 'fs'

// https://vitejs.dev/config/
export default defineConfig({
	plugins: [
		react(),
		{
			name: 'serve-local-tiles',
			configureServer(server) {
				server.middlewares.use((req, res, next) => {
					// Serve local PMTiles from ../tiles directory with range request support
					if (req.url?.startsWith('/tiles/') && req.url.endsWith('.pmtiles')) {
						const filename = path.basename(req.url)
						const tilePath = path.resolve(__dirname, '../tiles', filename)

						if (fs.existsSync(tilePath)) {
							const stat = fs.statSync(tilePath)
							const fileSize = stat.size
							const range = req.headers.range

							// Support HTTP Range requests (required for PMTiles)
							if (range) {
								const parts = range.replace(/bytes=/, '').split('-')
								const start = parseInt(parts[0], 10)
								const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1
								const chunkSize = end - start + 1

								// Read the chunk into a buffer first to ensure Content-Length is exact
								const buffer = Buffer.alloc(chunkSize)
								const fd = fs.openSync(tilePath, 'r')
								try {
									const bytesRead = fs.readSync(fd, buffer, 0, chunkSize, start)
									fs.closeSync(fd)

									res.statusCode = 206
									res.setHeader('Content-Range', `bytes ${start}-${end}/${fileSize}`)
									res.setHeader('Accept-Ranges', 'bytes')
									res.setHeader('Content-Length', bytesRead.toString())
									res.setHeader('Content-Type', 'application/vnd.pmtiles')
									res.setHeader('Access-Control-Allow-Origin', '*')
									res.setHeader('Cache-Control', 'no-cache')

									res.end(buffer.slice(0, bytesRead))
								} catch (err) {
									console.error('PMTiles read error:', err)
									fs.closeSync(fd)
									if (!res.headersSent) {
										res.statusCode = 500
									}
									res.end()
								}
							} else {
								// No range request, send entire file
								res.statusCode = 200
								res.setHeader('Content-Length', fileSize.toString())
								res.setHeader('Content-Type', 'application/vnd.pmtiles')
								res.setHeader('Accept-Ranges', 'bytes')
								res.setHeader('Access-Control-Allow-Origin', '*')
								res.setHeader('Cache-Control', 'no-cache')

								const buffer = fs.readFileSync(tilePath)
								res.end(buffer)
							}
							return
						}
					}
					next()
				})
			},
		},
	],
	resolve: {
		alias: {
			'@': path.resolve(__dirname, './src'),
		},
	},
	build: {
		outDir: 'build',
		emptyOutDir: true,
		rollupOptions: {
			output: {
				manualChunks: {
					// Split React and React-DOM into separate chunk
					'react-vendor': ['react', 'react-dom'],
					// Split MapLibre (largest dependency) into its own chunk
					'maplibre': ['maplibre-gl', 'react-map-gl'],
					// Split mapping utilities
					'map-utils': ['pmtiles', '@mapbox/mapbox-gl-draw'],
					// Split geospatial utilities
					'geo-utils': ['@turf/boolean-point-in-polygon', '@turf/centroid'],
					// Split UI libraries
					'ui-vendor': [
						'@radix-ui/react-checkbox',
						'@radix-ui/react-dialog',
						'@radix-ui/react-select',
						'lucide-react'
					],
				},
			},
		},
		chunkSizeWarningLimit: 900, // Increase threshold - maplibre is unavoidably large (824KB)
	},
	server: {
		port: 3000,
		proxy: {
			'/api': {
				// Local development: proxy to local Flask server on port 5001 (avoiding macOS AirPlay on 5000)
				// Production: nginx handles /api directly (no proxy needed)
				target: 'http://localhost:5001',
				changeOrigin: true,
				secure: false,
			},
			// Removed /tiles proxy - now served locally by custom middleware above
		},
	},
})
