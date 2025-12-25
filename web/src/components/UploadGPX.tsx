import { useState } from 'react';
import { Upload, CheckCircle, XCircle, Loader } from 'lucide-react';

interface UploadGPXProps {
  onUploadComplete?: () => void;
}

type UploadStatus = 'idle' | 'uploading' | 'success' | 'error' | 'duplicate';

interface UploadResult {
  status: 'success' | 'duplicate' | 'error';
  message: string;
  filename?: string;
  run?: {
    distance_miles?: number;
    location?: string;
  };
}

export function UploadGPX({ onUploadComplete }: UploadGPXProps) {
  const [uploadStatus, setUploadStatus] = useState<UploadStatus>('idle');
  const [message, setMessage] = useState<string>('');
  const [isDragging, setIsDragging] = useState(false);

  const handleFileUpload = async (file: File) => {
    if (!file.name.endsWith('.gpx')) {
      setUploadStatus('error');
      setMessage('Please select a .gpx file');
      return;
    }

    setUploadStatus('uploading');
    setMessage('Uploading...');

    const formData = new FormData();
    formData.append('file', file);

    try {
      const response = await fetch('/api/upload', {
        method: 'POST',
        body: formData,
      });

      const result: UploadResult = await response.json();

      if (result.status === 'success') {
        setUploadStatus('success');
        const distance = result.run?.distance_miles ? `${result.run.distance_miles} mi` : '';
        const location = result.run?.location ? ` (${result.run.location})` : '';
        setMessage(`✓ Uploaded: ${result.filename || file.name}${distance ? ' - ' + distance : ''}${location}`);

        // Trigger stats refresh after successful upload
        if (onUploadComplete) {
          setTimeout(onUploadComplete, 1000);
        }
      } else if (result.status === 'duplicate') {
        setUploadStatus('duplicate');
        setMessage(`⚠ Duplicate: ${result.message}`);
      } else {
        setUploadStatus('error');
        setMessage(`✗ Error: ${result.message || 'Upload failed'}`);
      }
    } catch (error) {
      setUploadStatus('error');
      setMessage(`✗ Error: ${error instanceof Error ? error.message : 'Upload failed'}`);
    }

    // Clear status after 5 seconds
    setTimeout(() => {
      setUploadStatus('idle');
      setMessage('');
    }, 5000);
  };

  const handleFileSelect = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) {
      handleFileUpload(file);
    }
    // Reset input so same file can be selected again
    event.target.value = '';
  };

  const handleDragOver = (event: React.DragEvent) => {
    event.preventDefault();
    setIsDragging(true);
  };

  const handleDragLeave = () => {
    setIsDragging(false);
  };

  const handleDrop = (event: React.DragEvent) => {
    event.preventDefault();
    setIsDragging(false);

    const file = event.dataTransfer.files?.[0];
    if (file) {
      handleFileUpload(file);
    }
  };

  const getStatusIcon = () => {
    switch (uploadStatus) {
      case 'uploading':
        return <Loader className="w-4 h-4 animate-spin" />;
      case 'success':
        return <CheckCircle className="w-4 h-4 text-green-600" />;
      case 'duplicate':
        return <CheckCircle className="w-4 h-4 text-yellow-600" />;
      case 'error':
        return <XCircle className="w-4 h-4 text-red-600" />;
      default:
        return <Upload className="w-4 h-4" />;
    }
  };

  const getStatusColor = () => {
    switch (uploadStatus) {
      case 'uploading':
        return 'bg-blue-50 border-blue-300 text-blue-700';
      case 'success':
        return 'bg-green-50 border-green-300 text-green-700';
      case 'duplicate':
        return 'bg-yellow-50 border-yellow-300 text-yellow-700';
      case 'error':
        return 'bg-red-50 border-red-300 text-red-700';
      default:
        return isDragging
          ? 'bg-blue-50 border-blue-400 text-blue-700'
          : 'bg-gray-50 border-gray-300 text-gray-700 hover:bg-gray-100';
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 text-sm font-semibold text-gray-700">
        <Upload className="w-4 h-4" />
        <span>Upload GPX</span>
      </div>

      <div
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        onDrop={handleDrop}
        className={`border-2 border-dashed rounded-lg p-4 text-center transition-colors ${getStatusColor()}`}
      >
        <input
          type="file"
          accept=".gpx"
          onChange={handleFileSelect}
          className="hidden"
          id="gpx-upload"
          disabled={uploadStatus === 'uploading'}
        />

        <label
          htmlFor="gpx-upload"
          className={`cursor-pointer flex flex-col items-center gap-2 ${
            uploadStatus === 'uploading' ? 'opacity-50 cursor-not-allowed' : ''
          }`}
        >
          {getStatusIcon()}

          {uploadStatus === 'idle' && (
            <>
              <span className="text-sm font-medium">
                {isDragging ? 'Drop GPX file here' : 'Click to select or drag & drop'}
              </span>
              <span className="text-xs text-gray-500">
                .gpx files only
              </span>
            </>
          )}

          {message && (
            <span className="text-sm font-medium whitespace-pre-wrap">
              {message}
            </span>
          )}
        </label>
      </div>
    </div>
  );
}
