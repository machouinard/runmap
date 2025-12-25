# RouteGen API Deployment Guide

This guide covers deploying the RouteGen API service to your Ubuntu server.

## Overview

The RouteGen API provides two endpoints for converting GPX/KML tracks to turn-by-turn routes:

1. **POST /convert** - Upload a GPX/KML file and get back a turn-by-turn GPX
2. **POST /convert-from-path** - Convert a GPX file already on the server

## Deployment Options

### Option A: Docker Container (Recommended)

1. **Copy entire project to server:**
   ```bash
   # From your local machine, in the project root directory:
   # /Users/markchouinard/Development/GIS/routing/routegen/

   # Option 1: Copy entire directory at once
   scp -r . your-server:/var/www/routegen/

   # Option 2: Copy specific files/directories (if you want to exclude some)
   scp -r routegen/ your-server:/var/www/routegen/routegen/
   scp Dockerfile.api your-server:/var/www/routegen/
   scp docker-compose.api.yml your-server:/var/www/routegen/
   scp pyproject.toml your-server:/var/www/routegen/
   scp README.md your-server:/var/www/routegen/

   # Option 3: Use rsync (RECOMMENDED - excludes development files)
   rsync -av \
     --exclude='.git' \
     --exclude='__pycache__' \
     --exclude='*.pyc' \
     --exclude='.DS_Store' \
     --exclude='.venv' \
     --exclude='venv' \
     --exclude='*.egg-info' \
     --exclude='*.pbf' \
     --exclude='*.log' \
     --exclude='docker-compose.yml' \
     --exclude='docker-compose.ubuntu.yml' \
     --exclude='graphhopper-data/' \
     --exclude='examples/out/' \
     --exclude='examples/old_routes/' \
     --exclude='examples/GarminExports/' \
     --exclude='examples/*.png' \
     --exclude='run-cdm_docs/' \
     --exclude='ubuntu-docs/' \
     --exclude='trouble/' \
     --exclude='AGENTS.md' \
     --exclude='BUG_FIXES_SUMMARY.md' \
     --exclude='CODE_REVIEW.md' \
     --exclude='GRAPHHOPPER_SETUP.md' \
     --exclude='NOTES.md' \
     --exclude='PATH_FIX_SUMMARY.md' \
     --exclude='QUICKSTART.md' \
     --exclude='turn-by-turn-prompt.md' \
     --exclude='UTURN_FIX.md' \
     --exclude='VALIDATION_FEATURES.md' \
     --exclude='generate_test_formats.py' \
     . your-server:/var/www/routegen/
   ```

   **What to copy:**
   - `routegen/` - The Python package (your source code)
   - `pyproject.toml` - Package configuration and dependencies
   - `Dockerfile.api` - Docker build instructions
   - `docker-compose.api.yml` - Docker compose configuration
   - `examples/` - Optional, for testing

   **Directory structure on server should be:**
   ```
   /var/www/routegen/
   ├── routegen/           # The Python package
   │   ├── __init__.py
   │   ├── api.py
   │   ├── cli.py
   │   └── ...
   ├── pyproject.toml
   ├── Dockerfile.api
   └── docker-compose.api.yml
   ```

2. **Build and run on server:**
   ```bash
   ssh your-server
   cd /var/www/routegen
   docker-compose -f docker-compose.api.yml up -d
   ```

3. **Configure NGINX reverse proxy:**

   **Option A: Add to existing run map site (RECOMMENDED)**

   Edit your run map NGINX config (probably `/etc/nginx/sites-available/runmap`):

   ```bash
   sudo nano /etc/nginx/sites-available/runmap
   ```

   Add this location block inside your existing `server` block:

   ```nginx
   server {
       server_name runmap.chouinard.me;

       # IMPORTANT: Place MORE SPECIFIC location blocks BEFORE less specific ones
       # /api/routegen/ must come BEFORE /api/ to match correctly

       # NEW: Add RouteGen API endpoint
       location /api/routegen/ {
           proxy_pass http://localhost:8000/;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;

           # Increase timeout for route processing
           proxy_read_timeout 300s;
           proxy_connect_timeout 300s;

           # Allow large file uploads
           client_max_body_size 50M;
       }

       # Your existing Flask API location (less specific)
       location /api/ {
           proxy_pass http://localhost:5000;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
       }

       # Your existing run map location
       location / {
           # ... existing config
       }
   }
   ```

   **How NGINX Location Matching Works:**
   - NGINX uses **longest prefix match** for location blocks
   - `/api/routegen/health` matches both `/api/routegen/` and `/api/`, but NGINX chooses the longer match: `/api/routegen/`
   - `/api/something-else` only matches `/api/`, so it goes to your Flask app
   - **Order matters**: Place more specific locations before less specific ones for clarity

   **Result:**
   - `https://runmap.chouinard.me/api/routegen/health` → RouteGen API (port 8000)
   - `https://runmap.chouinard.me/api/other-endpoint` → Flask app (port 5000)

   **Option B: Create new subdomain (if you want separation)**

   Create `/etc/nginx/sites-available/routegen`:

   ```nginx
   server {
       listen 80;
       server_name routegen.chouinard.me;

       location / {
           proxy_pass http://localhost:8000/;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;

           proxy_read_timeout 300s;
           proxy_connect_timeout 300s;
           client_max_body_size 50M;
       }
   }
   ```

   Then enable and get SSL:
   ```bash
   sudo ln -s /etc/nginx/sites-available/routegen /etc/nginx/sites-enabled/
   sudo certbot --nginx -d routegen.chouinard.me
   ```

4. **Reload NGINX:**
   ```bash
   sudo nginx -t
   sudo systemctl reload nginx
   ```

   **Testing the API:**
   - Option A: `https://runmap.chouinard.me/api/routegen/health`
   - Option B: `https://routegen.chouinard.me/health`

### Option B: Standalone Python Service

1. **Install on server:**
   ```bash
   ssh your-server
   cd /var/www/routegen
   python3 -m venv venv
   source venv/bin/activate
   pip install -e .
   ```

2. **Create systemd service (`/etc/systemd/system/routegen-api.service`):**
   ```ini
   [Unit]
   Description=RouteGen API Service
   After=network.target

   [Service]
   Type=simple
   User=www-data
   WorkingDirectory=/var/www/routegen
   Environment="PATH=/var/www/routegen/venv/bin"
   Environment="GRAPHHOPPER_URL=https://map.chouinard.me"
   ExecStart=/var/www/routegen/venv/bin/uvicorn routegen.api:app --host 0.0.0.0 --port 8000
   Restart=always

   [Install]
   WantedBy=multi-user.target
   ```

3. **Enable and start:**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable routegen-api
   sudo systemctl start routegen-api
   ```

## Integration with Flask Run Map

### Example: Add button to convert existing GPX

Add this to your run map Flask app:

```python
import requests
from flask import send_file

@app.route('/convert-to-turns/<int:route_id>')
def convert_to_turns(route_id):
    # Get the GPX file path for this route
    route = db.get_route(route_id)
    gpx_path = route.file_path

    # Call RouteGen API
    # If using NGINX Option A (same domain):
    api_url = 'http://localhost:8000/convert-from-path'
    # If using NGINX Option B (subdomain):
    # api_url = 'https://routegen.chouinard.me/convert-from-path'

    response = requests.post(
        api_url,
        json={
            'file_path': gpx_path,
            'profile': 'foot',
            'resample_distance': 30.0,
            'route_name': route.name,
        },
        timeout=120  # 2 minute timeout for long routes
    )

    if response.status_code == 200:
        # Save or return the turn-by-turn GPX
        output_path = f'/tmp/{route.name}-turns.gpx'
        with open(output_path, 'wb') as f:
            f.write(response.content)
        return send_file(output_path, as_attachment=True)
    else:
        return f"Error: {response.json()}", 500
```

**Note:** Use `http://localhost:8000` when calling from server-side code (Flask backend). The NGINX proxy is only needed for browser/external access.

### Example: Upload form

```html
<form action="http://localhost:8000/convert" method="post" enctype="multipart/form-data">
    <input type="file" name="file" accept=".gpx,.kml" required>
    <select name="profile">
        <option value="foot">Walking</option>
        <option value="bike">Cycling</option>
        <option value="car">Driving</option>
    </select>
    <input type="number" name="resample_distance" value="30" step="5" min="0">
    <button type="submit">Convert to Turn-by-Turn</button>
</form>
```

## API Endpoints

### POST /convert

Upload a GPX/KML file and convert to turn-by-turn route.

**Parameters:**
- `file` (form-data): GPX or KML file
- `profile` (optional): Routing profile - "foot", "bike", "car" (default: "foot")
- `resample_distance` (optional): Minimum distance between waypoints in meters (default: 30.0)
- `route_name` (optional): Name for the route (default: filename)
- `graphhopper_url` (optional): GraphHopper server URL (default: "https://map.chouinard.me")

**Response:** GPX file with turn-by-turn navigation waypoints

**Example:**
```bash
curl -X POST http://localhost:8000/convert \
  -F "file=@route.gpx" \
  -F "profile=foot" \
  -F "resample_distance=30" \
  -o output-turns.gpx
```

### POST /convert-from-path

Convert existing GPX file on server to turn-by-turn route.

**Parameters (JSON body):**
- `file_path` (required): Path to GPX/KML file on server
- `profile` (optional): Routing profile (default: "foot")
- `resample_distance` (optional): Minimum distance in meters (default: 30.0)
- `route_name` (optional): Name for the route (default: filename)
- `graphhopper_url` (optional): GraphHopper server URL (default: "https://map.chouinard.me")

**Response:** GPX file with turn-by-turn navigation waypoints

**Example:**
```bash
curl -X POST http://localhost:8000/convert-from-path \
  -H "Content-Type: application/json" \
  -d '{
    "file_path": "/var/www/runmap/uploads/route.gpx",
    "profile": "foot",
    "resample_distance": 30.0,
    "route_name": "My Route"
  }' \
  -o output-turns.gpx
```

### GET /health

Health check endpoint.

**Response:** `{"status": "ok"}`

## Testing

Test the API locally:

```bash
# Start the API
python -m uvicorn routegen.api:app --reload

# Test health check
curl http://localhost:8000/health

# Test conversion
curl -X POST http://localhost:8000/convert \
  -F "file=@examples/input/sacramento-real.kml" \
  -o test-output.gpx
```

## Monitoring

Check API logs:

```bash
# Docker
docker-compose -f docker-compose.api.yml logs -f routegen-api

# Systemd
sudo journalctl -u routegen-api -f
```

## Troubleshooting

**API returns 503 (GraphHopper not reachable):**
- Verify GraphHopper is running: `curl https://map.chouinard.me/health`
- Check network connectivity from API server to GraphHopper

**API returns 400 (Invalid file format):**
- Ensure file is valid GPX or KML
- Check file has at least 2 coordinates

**Timeout on long routes:**
- Increase NGINX proxy timeout
- Increase resample_distance to reduce waypoint count
- Use `--skip-validation` if enabled

## Security Considerations

1. **File Upload Validation**: API validates file extensions (.gpx, .kml only)
2. **Path Traversal**: `/convert-from-path` should validate file paths are within allowed directories
3. **Rate Limiting**: Consider adding rate limiting for production use
4. **Authentication**: Consider adding API key authentication for public deployments

## Recommended NGINX Rate Limiting

```nginx
# Define rate limit zone (10MB for ~160k IPs)
limit_req_zone $binary_remote_addr zone=routegen:10m rate=10r/m;

location /api/routegen/ {
    limit_req zone=routegen burst=5 nodelay;
    # ... rest of config
}
```
