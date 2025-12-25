export interface ColorScheme {
	incomplete: string
	complete: string
	runs: string
}

export const COLOR_SCHEMES: Record<string, ColorScheme> = {
	// Light base maps - use current saturated, darker colors
	osm: {
		incomplete: '#BA200D',
		complete: '#059669',
		runs: '#2256a3',
	},
	humanitarian: {
		incomplete: '#ED3C26',
		complete: '#059669',
		runs: '#2256a3',
	},
	voyager: {
		incomplete: '#ED3C26',
		complete: '#059669',
		runs: '#2256a3',
	},
	terrain: {
		incomplete: '#ED3C26',
		complete: '#059669',
		runs: '#2256a3',
	},
	toner: {
		incomplete: '#ED3C26',
		complete: '#059669',
		runs: '#2256a3',
	},

	// Satellite base map - use brighter, more vibrant colors for contrast
	satellite: {
		incomplete: '#ED3C26',
		complete: '#00ff7f',
		runs: '#00bfff',
	},
}

// Default fallback colors (current colors)
export const DEFAULT_COLORS: ColorScheme = {
	incomplete: '#ff9900',
	complete: '#059669',
	runs: '#2256a3',
}
