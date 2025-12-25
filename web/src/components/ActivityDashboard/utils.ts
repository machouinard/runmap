export const formatDistance = (meters: number): string => {
	return (meters / 1609.34).toFixed(2) + ' mi'
}

export const formatDuration = (seconds: number): string => {
	const hours = Math.floor(seconds / 3600)
	const minutes = Math.floor((seconds % 3600) / 60)
	const secs = seconds % 60
	if (hours > 0) {
		return `${hours}:${minutes.toString().padStart(2, '0')}:${secs
			.toString()
			.padStart(2, '0')}`
	}
	return `${minutes}:${secs.toString().padStart(2, '0')}`
}

export const formatSpeed = (meters: number, seconds: number): string => {
	if (!seconds) return 'N/A'
	const mph = meters / 1609.34 / (seconds / 3600)
	return mph.toFixed(2) + ' mph'
}

export const getLocationBadgeColor = (location: string): string => {
	switch (location) {
		case 'sacramento':
			return 'bg-blue-100 text-blue-800'
		case 'portland':
			return 'bg-green-100 text-green-800'
		default:
			return 'bg-gray-100 text-gray-800'
	}
}

export const getTypeBadgeColor = (type: string): string => {
	switch (type) {
		case 'run':
			return 'bg-red-100 text-red-800'
		case 'walk':
			return 'bg-blue-100 text-blue-800'
		case 'cycling':
			return 'bg-green-100 text-green-800'
		default:
			return 'bg-gray-100 text-gray-800'
	}
}

export const getStatusBadgeColor = (status?: string): string => {
	switch (status) {
		case 'processed':
			return 'bg-green-100 text-green-800'
		case 'failed':
			return 'bg-red-100 text-red-800'
		case 'pending':
			return 'bg-yellow-100 text-yellow-800'
		case 'processing':
			return 'bg-blue-100 text-blue-800'
		default:
			return 'bg-gray-100 text-gray-800'
	}
}

export const exportToCSV = (
	activities: {
		start_time: string
		filename: string
		location: string
		activity_type: string
		total_distance_m: number
		duration_seconds: number
		processing_status?: string
	}[]
): void => {
	const headers = [
		'Date',
		'Filename',
		'Location',
		'Type',
		'Distance (mi)',
		'Duration (min)',
		'Avg Speed (mph)',
		'Status',
	]
	const rows = activities.map((a) => [
		new Date(a.start_time).toLocaleDateString(),
		a.filename,
		a.location,
		a.activity_type,
		(a.total_distance_m / 1609.34).toFixed(2),
		(a.duration_seconds / 60).toFixed(1),
		(a.total_distance_m / 1609.34 / (a.duration_seconds / 3600)).toFixed(2),
		a.processing_status || 'N/A',
	])

	const csv = [headers, ...rows].map((row) => row.join(',')).join('\n')
	const blob = new Blob([csv], { type: 'text/csv' })
	const url = URL.createObjectURL(blob)
	const a = document.createElement('a')
	a.href = url
	a.download = `activities_export_${
		new Date().toISOString().split('T')[0]
	}.csv`
	a.click()
}
