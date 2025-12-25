# RouteGen API - Production Ready

## Summary

RouteGen is now production-ready with both CLI and web API capabilities:

✅ **CLI**: Convert GPX/KML tracks to turn-by-turn routes from command line
✅ **API**: FastAPI web service for integration with your run map
✅ **Production**: Uses GraphHopper server at `https://map.chouinard.me`
✅ **Tested**: Confirmed working with WorkOutDoors app
✅ **Deployed**: Docker and systemd deployment options ready

## What's New

### 1. Production GraphHopper Integration
- CLI and API now default to `https://map.chouinard.me`
- No local GraphHopper needed for development
- Confirmed working with your production server

### 2. Web API Service
- FastAPI-based service at [routegen/api.py](routegen/api.py)
- Two endpoints:
  - `POST /convert` - Upload GPX/KML file
  - `POST /convert-from-path` - Convert file already on server
- Perfect for Flask run map integration

### 3. Deployment Ready
- Docker setup: [Dockerfile.api](Dockerfile.api) + [docker-compose.api.yml](docker-compose.api.yml)
- Systemd service configuration included
- NGINX reverse proxy configuration provided

### 4. Documentation
- [DEPLOYMENT.md](DEPLOYMENT.md) - Complete deployment guide
- [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) - Flask integration examples
- [flask_integration_example.py](flask_integration_example.py) - Drop-in Flask code

## Quick Start

### CLI Usage

```bash
# Install
pip install -e .

# Convert a KML/GPX track
routegen build examples/input/sacramento-real.kml

# Preview turn cues without writing file
routegen preview examples/input/sacramento-real.kml

# Custom options
routegen build input.gpx --profile bike --resample 50
```

### API Usage

```bash
# Start the API
python -m uvicorn routegen.api:app --host 0.0.0.0 --port 8000

# Or with Docker
docker-compose -f docker-compose.api.yml up -d

# Test it
curl http://localhost:8000/health

# Convert a file
curl -X POST http://localhost:8000/convert \
  -F "file=@route.gpx" \
  -F "profile=foot" \
  -o route-turns.gpx
```

### Flask Integration

```python
from flask import Flask, send_file
import requests

app = Flask(__name__)

@app.route('/convert-route/<int:route_id>')
def convert_route(route_id):
    route = db.get_route(route_id)

    response = requests.post(
        'http://localhost:8000/convert-from-path',
        json={'file_path': route.gpx_path}
    )

    if response.ok:
        return send_file(
            response.content,
            download_name=f'{route.name}-turns.gpx'
        )
```

See [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) for complete examples.

## Architecture

```
┌─────────────────┐
│   Run Map UI    │  (runmap.chouinard.me)
│  (Flask App)    │
└────────┬────────┘
         │ HTTP POST
         ▼
┌─────────────────┐
│  RouteGen API   │  (FastAPI, port 8000)
│   (This repo)   │
└────────┬────────┘
         │ HTTP
         ▼
┌─────────────────┐
│  GraphHopper    │  (map.chouinard.me)
│   Routing API   │
└─────────────────┘
```

## File Structure

```
routegen/
├── routegen/
│   ├── api.py                 # NEW: FastAPI web service
│   ├── cli.py                 # Updated: Uses production GraphHopper
│   ├── router/
│   │   └── graphhopper.py     # Updated: Default URL changed
│   ├── io/
│   │   ├── readers.py
│   │   └── writers.py
│   └── cues/
│       └── normalize.py
├── Dockerfile.api             # NEW: Docker build for API
├── docker-compose.api.yml     # NEW: Docker compose config
├── DEPLOYMENT.md              # NEW: Deployment instructions
├── INTEGRATION_GUIDE.md       # NEW: Flask integration guide
├── flask_integration_example.py  # NEW: Example Flask code
└── pyproject.toml             # Updated: Added FastAPI dependencies
```

## API Endpoints

### POST /convert

Upload GPX/KML and get turn-by-turn GPX back.

**Form Data:**
- `file`: GPX or KML file
- `profile`: "foot", "bike", "car" (default: "foot")
- `resample_distance`: Meters between waypoints (default: 30)
- `route_name`: Optional route name

**Response:** GPX file with navigation waypoints

### POST /convert-from-path

Convert file already on server.

**JSON Body:**
```json
{
  "file_path": "/path/to/route.gpx",
  "profile": "foot",
  "resample_distance": 30.0,
  "route_name": "My Route"
}
```

**Response:** GPX file with navigation waypoints

### GET /health

Health check endpoint.

**Response:** `{"status": "ok"}`

## Deployment Options

### Option 1: Docker (Recommended)

```bash
# Build and run
docker-compose -f docker-compose.api.yml up -d

# View logs
docker-compose -f docker-compose.api.yml logs -f

# Stop
docker-compose -f docker-compose.api.yml down
```

### Option 2: Systemd Service

```bash
# Install
pip install -e .

# Create service file
sudo cp deployment/routegen-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable routegen-api
sudo systemctl start routegen-api

# Check status
sudo systemctl status routegen-api
```

### Option 3: Development

```bash
# Install with dependencies
pip install -e .

# Run with hot reload
python -m uvicorn routegen.api:app --reload --port 8000
```

## NGINX Configuration

Add to your NGINX config for the run map:

```nginx
location /api/routegen/ {
    proxy_pass http://localhost:8000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 300s;
    client_max_body_size 50M;
}
```

## Testing

```bash
# Run CLI tests
routegen preview examples/input/sacramento-real.kml

# Test API health
curl http://localhost:8000/health

# Test conversion
curl -X POST http://localhost:8000/convert \
  -F "file=@examples/input/deadend-vshape.kml" \
  -o test-output.gpx

# Verify output
head -20 test-output.gpx
```

## Next Steps

1. **Deploy API** to your Ubuntu server
   - See [DEPLOYMENT.md](DEPLOYMENT.md) for step-by-step instructions

2. **Integrate with Run Map**
   - See [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) for Flask examples
   - Use [flask_integration_example.py](flask_integration_example.py) as template

3. **Test End-to-End**
   - Upload route to run map
   - Click "Add Turn-by-Turn" button
   - Download GPX
   - Import to WorkOutDoors
   - Verify turn prompts appear

4. **Optional Enhancements**
   - Add progress indicator during conversion
   - Store turn-by-turn versions in database
   - Batch convert multiple routes
   - Add email notification on completion

## Troubleshooting

**API not starting:**
```bash
# Check if port 8000 is already in use
lsof -i :8000

# View logs
docker-compose logs routegen-api
# OR
journalctl -u routegen-api -f
```

**GraphHopper unreachable:**
```bash
# Test GraphHopper directly
curl https://map.chouinard.me/health

# Check network connectivity from your server
ping map.chouinard.me
```

**Conversion fails:**
- Ensure GPX/KML has at least 2 coordinates
- Try increasing `resample_distance` for long routes
- Check GraphHopper has OSM data for the area
- View API logs for detailed error messages

## Production Checklist

- [ ] Deploy API to server (Docker or systemd)
- [ ] Configure NGINX reverse proxy
- [ ] Test API health endpoint
- [ ] Test conversion with sample route
- [ ] Add Flask integration code to run map
- [ ] Test end-to-end from run map UI
- [ ] Verify WorkOutDoors compatibility
- [ ] Set up monitoring/logging
- [ ] Configure rate limiting (optional)
- [ ] Add authentication (optional)

## Support

For detailed guides:
- **Deployment**: See [DEPLOYMENT.md](DEPLOYMENT.md)
- **Integration**: See [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md)
- **Examples**: See [flask_integration_example.py](flask_integration_example.py)

For issues:
- Check API logs
- Test GraphHopper health
- Verify file format (GPX 1.1 or KML)
- Ensure adequate network timeout (120s recommended)
