import { useState } from 'react';
import { Map, Lock, LogOut } from 'lucide-react';
import { UploadGPX } from '../UploadGPX';

interface AdminControlsProps {
  isAdmin: boolean;
  onShowLogin: () => void;
  onStatsRefresh: () => void;
  logout: () => void;
  getAuthHeaders: () => HeadersInit;
}

export function AdminControls({
  isAdmin,
  onShowLogin,
  onStatsRefresh,
  logout,
  getAuthHeaders,
}: AdminControlsProps) {
  const [isRegeneratingTiles, setIsRegeneratingTiles] = useState(false);

  const handleRegenerateTiles = async () => {
    if (!isAdmin) return;

    setIsRegeneratingTiles(true);
    try {
      const response = await fetch('/api/tiles/regenerate', {
        method: 'POST',
        headers: getAuthHeaders(),
      });

      const data = await response.json();

      if (response.ok) {
        alert('Tiles regenerated successfully! Refresh the page to see changes.');
        onStatsRefresh();
      } else {
        alert(`Tile regeneration failed: ${data.message || data.error}`);
      }
    } catch (error) {
      console.error('Failed to regenerate tiles:', error);
      alert('Failed to regenerate tiles. Check console for details.');
    } finally {
      setIsRegeneratingTiles(false);
    }
  };

  return (
    <>
      <div className="border-t border-gray-200 pt-4 space-y-2">
        {isAdmin && (
          <button
            onClick={handleRegenerateTiles}
            disabled={isRegeneratingTiles}
            className="w-full px-4 py-2 bg-purple-600 hover:bg-purple-700 disabled:bg-purple-400 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2"
          >
            <Map className="w-4 h-4" />
            {isRegeneratingTiles ? 'Regenerating...' : 'Regenerate Tiles'}
          </button>
        )}

        {isAdmin ? (
          <button
            onClick={logout}
            className="w-full px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2"
          >
            <LogOut className="w-4 h-4" />
            Admin Logout
          </button>
        ) : (
          <button
            onClick={onShowLogin}
            className="w-full px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-md text-sm font-medium transition-colors flex items-center justify-center gap-2"
          >
            <Lock className="w-4 h-4" />
            Admin Login
          </button>
        )}
      </div>

      {isAdmin && (
        <div className="border-t border-gray-200 pt-4">
          <UploadGPX onUploadComplete={onStatsRefresh} />
        </div>
      )}
    </>
  );
}
