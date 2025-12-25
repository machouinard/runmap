import type { CentroidPoint } from '@/components/UnrunSegmentPanel';

/**
 * Convert centroids to GeoJSON FeatureCollection and trigger download
 */
export function exportAsGeoJSON(centroids: CentroidPoint[], filename = 'unrun-blocks.geojson') {
  const featureCollection: GeoJSON.FeatureCollection = {
    type: 'FeatureCollection',
    features: centroids.map((centroid) => ({
      type: 'Feature',
      geometry: {
        type: 'Point',
        coordinates: [centroid.lon, centroid.lat],
      },
      properties: {
        block_id: centroid.block_id,
        street_name: centroid.street_name,
        total_unvisited_length_m: centroid.total_unvisited_length_m,
        unvisited_segment_count: centroid.unvisited_segment_count,
      },
    })),
  };

  const jsonString = JSON.stringify(featureCollection, null, 2);
  downloadFile(jsonString, filename, 'application/json');
}

/**
 * Convert centroids to CSV and trigger download
 */
export function exportAsCSV(centroids: CentroidPoint[], filename = 'unrun-blocks.csv') {
  const headers = ['block_id', 'street_name', 'lat', 'lon', 'total_unvisited_length_m', 'unvisited_segment_count'];
  const rows = centroids.map((centroid) => [
    centroid.block_id,
    `"${centroid.street_name.replace(/"/g, '""')}"`, // Escape quotes in street names
    centroid.lat.toFixed(6),
    centroid.lon.toFixed(6),
    centroid.total_unvisited_length_m.toFixed(1),
    centroid.unvisited_segment_count,
  ]);

  const csvContent = [
    headers.join(','),
    ...rows.map((row) => row.join(',')),
  ].join('\n');

  downloadFile(csvContent, filename, 'text/csv');
}

/**
 * Generic file download helper
 */
function downloadFile(content: string, filename: string, mimeType: string) {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);

  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();

  // Cleanup
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}
