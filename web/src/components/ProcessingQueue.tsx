import { useState, useEffect } from 'react';
import { AlertCircle, RefreshCw, CheckCircle, Lock } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';

interface FailedRun {
  id: string;
  filename: string;
  start_time: string;
  total_distance_m: number;
  location: string;
  uploaded_at: string;
  processing_status: string;
  error_message?: string;
  error_type?: string;
  retry_count?: number;
}

interface ProcessingStats {
  processed_count: number;
  failed_count: number;
  pending_count: number;
  processing_count: number;
  total_count: number;
}

export function ProcessingQueue() {
  const { isAdmin, getAuthHeaders } = useAuth();
  const [failedRuns, setFailedRuns] = useState<FailedRun[]>([]);
  const [stats, setStats] = useState<ProcessingStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [retrying, setRetrying] = useState<Set<string>>(new Set());

  const loadData = async () => {
    if (!isAdmin) {
      setError('Authentication required to view processing queue');
      setLoading(false);
      return;
    }

    setLoading(true);
    setError(null);
    try {
      const [failedResponse, statsResponse] = await Promise.all([
        fetch('/api/processing-queue/failed', {
          headers: getAuthHeaders()
        }),
        fetch('/api/processing-queue/stats', {
          headers: getAuthHeaders()
        }),
      ]);

      if (failedResponse.status === 401 || statsResponse.status === 401) {
        setError('Unauthorized - Please login as admin');
        setLoading(false);
        return;
      }

      const failedData = await failedResponse.json();
      const statsData = await statsResponse.json();

      if (failedData.status === 'ok') {
        setFailedRuns(failedData.runs);
      }

      if (statsData.status === 'ok') {
        setStats(statsData.stats);
      }
    } catch (error) {
      console.error('Error loading processing queue:', error);
      setError('Failed to load processing queue data');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadData();
  }, [isAdmin]);

  const handleRetry = async (runId: string) => {
    setRetrying(prev => new Set(prev).add(runId));

    try {
      const response = await fetch(`/api/processing-queue/retry/${runId}`, {
        method: 'POST',
        headers: getAuthHeaders()
      });

      const result = await response.json();

      if (result.status === 'success') {
        // Reload data after successful retry
        setTimeout(() => loadData(), 1000);
      } else {
        alert(`Retry failed: ${result.message}`);
      }
    } catch (error) {
      alert(`Error retrying run: ${error}`);
    } finally {
      setRetrying(prev => {
        const newSet = new Set(prev);
        newSet.delete(runId);
        return newSet;
      });
    }
  };

  const formatDate = (dateStr: string) => {
    return new Date(dateStr).toLocaleString();
  };

  const formatDistance = (meters: number) => {
    return `${(meters / 1609.34).toFixed(2)} mi`;
  };

  if (!isAdmin && !loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <div className="text-center max-w-md">
          <Lock className="w-16 h-16 mx-auto mb-4 text-gray-400" />
          <h2 className="text-xl font-semibold text-gray-900 mb-2">Admin Access Required</h2>
          <p className="text-gray-600 mb-4">
            You need to be logged in as an administrator to view the processing queue.
          </p>
          <p className="text-sm text-gray-500">
            Please use the "Admin Login" button in the control panel to authenticate.
          </p>
        </div>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <RefreshCw className="w-6 h-6 animate-spin text-gray-400" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex items-center justify-center p-8">
        <div className="text-center max-w-md">
          <AlertCircle className="w-16 h-16 mx-auto mb-4 text-red-400" />
          <h2 className="text-xl font-semibold text-gray-900 mb-2">Error</h2>
          <p className="text-gray-600 mb-4">{error}</p>
          <button
            onClick={loadData}
            className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700"
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="p-6 max-w-7xl mx-auto">
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-gray-900 mb-2">Processing Queue</h1>
        <p className="text-gray-600">Monitor and retry failed run processing</p>
      </div>

      {/* Stats Cards */}
      {stats && (
        <div className="grid grid-cols-2 md:grid-cols-5 gap-4 mb-6">
          <div className="bg-white p-4 rounded-lg border border-gray-200">
            <div className="text-sm text-gray-600">Total</div>
            <div className="text-2xl font-bold text-gray-900">{stats.total_count}</div>
          </div>
          <div className="bg-white p-4 rounded-lg border border-green-200">
            <div className="text-sm text-green-600">Processed</div>
            <div className="text-2xl font-bold text-green-700">{stats.processed_count}</div>
          </div>
          <div className="bg-white p-4 rounded-lg border border-red-200">
            <div className="text-sm text-red-600">Failed</div>
            <div className="text-2xl font-bold text-red-700">{stats.failed_count}</div>
          </div>
          <div className="bg-white p-4 rounded-lg border border-yellow-200">
            <div className="text-sm text-yellow-600">Pending</div>
            <div className="text-2xl font-bold text-yellow-700">{stats.pending_count}</div>
          </div>
          <div className="bg-white p-4 rounded-lg border border-blue-200">
            <div className="text-sm text-blue-600">Processing</div>
            <div className="text-2xl font-bold text-blue-700">{stats.processing_count}</div>
          </div>
        </div>
      )}

      {/* Failed Runs Table */}
      <div className="bg-white rounded-lg border border-gray-200 overflow-hidden">
        <div className="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-gray-900">Failed Runs</h2>
          <button
            onClick={loadData}
            className="flex items-center gap-2 px-3 py-2 text-sm text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-md transition-colors"
          >
            <RefreshCw className="w-4 h-4" />
            Refresh
          </button>
        </div>

        {failedRuns.length === 0 ? (
          <div className="p-8 text-center text-gray-500">
            <CheckCircle className="w-12 h-12 mx-auto mb-3 text-green-500" />
            <p className="text-lg font-medium">No failed runs!</p>
            <p className="text-sm">All runs have been processed successfully.</p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Filename
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Date
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Distance
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Location
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Error
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody className="bg-white divide-y divide-gray-200">
                {failedRuns.map((run) => (
                  <tr key={run.id} className="hover:bg-gray-50">
                    <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">
                      {run.filename}
                    </td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                      {formatDate(run.start_time)}
                    </td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                      {formatDistance(run.total_distance_m)}
                    </td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                      <span className="px-2 py-1 text-xs rounded-full bg-gray-100 text-gray-700">
                        {run.location}
                      </span>
                    </td>
                    <td className="px-6 py-4 text-sm text-gray-500">
                      {run.error_message ? (
                        <div className="flex items-start gap-2">
                          <AlertCircle className="w-4 h-4 text-red-500 flex-shrink-0 mt-0.5" />
                          <span className="text-xs">{run.error_message}</span>
                        </div>
                      ) : (
                        <span className="text-xs text-gray-400">No error details</span>
                      )}
                    </td>
                    <td className="px-6 py-4 whitespace-nowrap text-sm">
                      <button
                        onClick={() => handleRetry(run.id)}
                        disabled={retrying.has(run.id)}
                        className="flex items-center gap-2 px-3 py-2 text-sm bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white rounded-md transition-colors"
                      >
                        {retrying.has(run.id) ? (
                          <>
                            <RefreshCw className="w-4 h-4 animate-spin" />
                            Retrying...
                          </>
                        ) : (
                          <>
                            <RefreshCw className="w-4 h-4" />
                            Retry
                          </>
                        )}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
