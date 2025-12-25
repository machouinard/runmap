# Runmap Deployment Guide

## Server Requirements

- Ubuntu 24.04 LTS
- 4GB+ RAM (8GB recommended for PostGIS operations)
- 20GB+ storage
- Domain with DNS configured

## Prerequisites

### System Packages

```bash
sudo apt update
sudo apt install -y \
    postgresql-16 \
    postgresql-16-postgis-3 \
    python3 \
    python3-pip \
    python3-venv \
    nginx \
    gdal-bin \
    osmium-tool \
    certbot \
    python3-certbot-nginx
```

### Tippecanoe

```bash
sudo apt install -y build-essential libsqlite3-dev zlib1g-dev
git clone https://github.com/felt/tippecanoe.git
cd tippecanoe
make -j
sudo make install
```

### PMTiles CLI

```bash
wget https://github.com/protomaps/go-pmtiles/releases/download/v1.15.0/go-pmtiles_1.15.0_Linux_x86_64.tar.gz
tar xzf go-pmtiles_1.15.0_Linux_x86_64.tar.gz
sudo mv pmtiles /usr/local/bin/
```

## Database Setup

### 1. Create Database and User

```bash
sudo -u postgres psql
```

```sql
CREATE USER runmap_user WITH PASSWORD 'your_secure_password';
CREATE DATABASE runmap OWNER runmap_user;
\c runmap
CREATE EXTENSION postgis;
CREATE SCHEMA runmap AUTHORIZATION runmap_user;
GRANT ALL ON SCHEMA runmap TO runmap_user;
```

### 2. Initialize Schema

```bash
psql -U runmap_user -d runmap -h localhost -f /home/mark/runmap/db/01_create_tables.sql
psql -U runmap_user -d runmap -h localhost -f /home/mark/runmap/db/02_create_views.sql
```

### 3. Import Street Network

Download Sacramento OSM data:
```bash
wget https://download.geofabrik.de/north-america/us/california/norcal-latest.osm.pbf
```

Extract Sacramento area:
```bash
osmium extract -b -121.6,38.4,-121.3,38.7 norcal-latest.osm.pbf -o sacramento.osm.pbf
```

Import to PostgreSQL:
```bash
osm2pgsql -d runmap \
  --create \
  --slim \
  --hstore \
  --latlong \
  -H localhost \
  -U runmap_user \
  sacramento.osm.pbf
```

Copy to runmap schema:
```bash
psql -U runmap_user -d runmap -h localhost << EOF
INSERT INTO runmap.streets_reference (osm_id, name, highway, waterway, aerialway, barrier, man_made, railway, z_order, other_tags, geom, runnable)
SELECT osm_id, name, highway, waterway, aerialway, barrier, man_made, railway, z_order, tags, way,
  (highway IN ('residential', 'unclassified', 'tertiary', 'secondary', 'primary', 'footway', 'path', 'cycleway', 'service'))
FROM planet_osm_line
WHERE highway IS NOT NULL OR waterway IS NOT NULL;
EOF
```

## API Setup

### 1. Create Python Virtual Environment

```bash
cd /home/mark/runmap/api
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Configure Environment

Create `/home/mark/runmap/api/.env`:
```bash
DB_HOST=localhost
DB_NAME=runmap
DB_USER=runmap_user
DB_PASSWORD=your_secure_password
GPX_DIR=/home/mark/runmap/gpx
TILES_DIR=/home/mark/runmap/tiles
SCRIPTS_DIR=/home/mark/runmap/scripts
```

### 3. Create Systemd Service

Create `/etc/systemd/system/runmap-api.service`:
```ini
[Unit]
Description=Runmap Flask API
After=network.target postgresql.service

[Service]
Type=simple
User=mark
WorkingDirectory=/home/mark/runmap/api
Environment="PATH=/home/mark/runmap/api/venv/bin"
Environment="FLASK_APP=app.py"
Environment="GPX_DIR=/home/mark/runmap/gpx"
Environment="TILES_DIR=/home/mark/runmap/tiles"
Environment="SCRIPTS_DIR=/home/mark/runmap/scripts"
ExecStart=/home/mark/runmap/api/venv/bin/python app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable runmap-api
sudo systemctl start runmap-api
sudo systemctl status runmap-api
```

## Nginx Setup

### 1. Configure Site

Create `/etc/nginx/sites-available/runmap`:
```nginx
server {
    listen 80;
    server_name runmap.chouinard.me;

    # Frontend
    location / {
        root /var/www/runmap;
        try_files $uri $uri/ /index.html;
    }

    # API proxy
    location /api/ {
        proxy_pass http://localhost:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Tiles
    location /tiles/ {
        alias /home/mark/runmap/tiles/;
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "public, max-age=3600";
    }
}
```

### 2. Add PMTiles MIME Type

Edit `/etc/nginx/mime.types` and add:
```
application/vnd.pmtiles                          pmtiles;
```

### 3. Enable Site

```bash
sudo ln -s /etc/nginx/sites-available/runmap /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### 4. SSL Certificate

```bash
sudo certbot --nginx -d runmap.chouinard.me
```

## Frontend Deployment

### 1. Build React App (when ready)

```bash
cd /home/mark/runmap/web
npm install
npm run build
```

### 2. Deploy to Nginx

```bash
sudo rm -rf /var/www/runmap/*
sudo cp -r /home/mark/runmap/web/build/* /var/www/runmap/
sudo chown -R www-data:www-data /var/www/runmap
```

For now, use placeholder:
```bash
sudo mkdir -p /var/www/runmap
sudo cp /home/mark/runmap/web/build/index.html /var/www/runmap/
sudo chown -R www-data:www-data /var/www/runmap
```

## Directory Structure

```bash
mkdir -p /home/mark/runmap/{gpx,tiles,scripts,api,db,web,docs}
```

Set permissions:
```bash
# GPX upload directory
sudo chown -R mark:www-data /home/mark/runmap/gpx
sudo chmod 775 /home/mark/runmap/gpx

# Tiles directory
sudo chown -R mark:mark /home/mark/runmap/tiles
sudo chmod 755 /home/mark/runmap/tiles
```

## Initial Data Processing

### 1. Create Initial Materialized Views

```bash
psql -U runmap_user -d runmap -h localhost << EOF
REFRESH MATERIALIZED VIEW runmap.runs_merged;
REFRESH MATERIALIZED VIEW runmap.coverage_buffer;
REFRESH MATERIALIZED VIEW runmap.streets_unrun;
REFRESH MATERIALIZED VIEW runmap.coverage_stats;
EOF
```

### 2. Generate Initial Tiles

Run slow path to create all tiles:
```bash
bash /home/mark/runmap/scripts/slow_path.sh
```

## Testing Deployment

### 1. Check API Health

```bash
curl https://runmap.chouinard.me/api/health
```

Expected response:
```json
{
  "database": "connected",
  "status": "healthy"
}
```

### 2. Upload Test GPX

```bash
curl -X POST https://runmap.chouinard.me/api/upload \
  -F "file=@/path/to/test.gpx"
```

### 3. Verify Tiles

```bash
curl -I https://runmap.chouinard.me/tiles/runs.pmtiles
```

Check for:
- `HTTP/2 200`
- `content-type: application/vnd.pmtiles`
- `access-control-allow-origin: *`

### 4. Check Coverage Stats

```bash
psql -U runmap_user -d runmap -c "SELECT * FROM runmap.coverage_stats;"
```

## Monitoring

### Service Status

```bash
# API
sudo systemctl status runmap-api
sudo journalctl -u runmap-api -f

# Nginx
sudo systemctl status nginx
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log

# PostgreSQL
sudo systemctl status postgresql
sudo tail -f /var/log/postgresql/postgresql-16-main.log
```

### Database Stats

```bash
# Run count
psql -U runmap_user -d runmap -c "SELECT COUNT(*) FROM runmap.runs_raw;"

# Coverage stats
psql -U runmap_user -d runmap -c "SELECT * FROM runmap.coverage_stats;"

# Unrun streets count
psql -U runmap_user -d runmap -c "SELECT COUNT(*) FROM runmap.streets_unrun;"
```

### Tile Stats

```bash
ls -lh /home/mark/runmap/tiles/*.pmtiles
pmtiles show /home/mark/runmap/tiles/runs.pmtiles
```

## Automated Tasks

### Nightly Coverage Refresh

Create `/etc/cron.d/runmap-refresh`:
```
# Refresh coverage every night at 2 AM
0 2 * * * mark /home/mark/runmap/scripts/slow_path.sh >> /var/log/runmap-slow-path.log 2>&1
```

### Database Backup

Create `/etc/cron.d/runmap-backup`:
```
# Daily backup at 3 AM
0 3 * * * postgres pg_dump -U postgres runmap | gzip > /var/backups/runmap-$(date +\%Y\%m\%d).sql.gz
```

Retention policy:
```bash
# Keep last 7 days
find /var/backups/runmap-*.sql.gz -mtime +7 -delete
```

## Troubleshooting

### API Won't Start

1. Check logs: `sudo journalctl -u runmap-api -n 50`
2. Verify Python venv: `ls /home/mark/runmap/api/venv/bin/python`
3. Check port availability: `sudo lsof -i :5000`
4. Test database connection: `psql -U runmap_user -d runmap -h localhost`

### Tiles Not Generating

1. Check script permissions: `ls -la /home/mark/runmap/scripts/*.sh`
2. Run manually: `bash -x /home/mark/runmap/scripts/fast_path.sh`
3. Check tmp directory: `ls -la /tmp/*.geojson`
4. Verify tippecanoe: `tippecanoe --version`

### Database Connection Errors

1. Check PostgreSQL status: `sudo systemctl status postgresql`
2. Verify user exists: `sudo -u postgres psql -c "\du"`
3. Check pg_hba.conf: `sudo cat /etc/postgresql/16/main/pg_hba.conf`
4. Test connection: `psql -U runmap_user -d runmap -h localhost`

### Upload Fails with Permission Denied

1. Check directory permissions: `ls -la /home/mark/runmap/gpx`
2. Fix ownership: `sudo chown -R mark:www-data /home/mark/runmap/gpx`
3. Check service user: `ps aux | grep app.py`

## Security Checklist

- [ ] PostgreSQL only listening on localhost
- [ ] Strong database password
- [ ] UFW firewall configured (ports 80, 443, 22 only)
- [ ] SSL certificate auto-renewal enabled
- [ ] API authentication implemented (TODO)
- [ ] Regular security updates: `sudo apt update && sudo apt upgrade`
- [ ] GPX directory permissions restricted
- [ ] Database backups automated

## Alternative: Cloudflare R2 for Tile Hosting

Instead of serving tiles from your server, you can host them on Cloudflare R2 for better performance and no bandwidth costs.

### Benefits
- **No egress fees** (unlike AWS S3)
- **CDN distribution** - faster global access
- **Cost**: ~$0.015/GB/month storage (essentially free for <1MB tiles)
- **Offloads bandwidth** from your server

### Setup R2

1. **Create R2 bucket:**
```bash
# Via Cloudflare dashboard
# Create bucket: runmap-tiles
# Enable public access or use custom domain
```

2. **Install rclone:**
```bash
curl https://rclone.org/install.sh | sudo bash
rclone config  # Configure R2 endpoint
```

3. **Update scripts to upload to R2:**

Edit `/home/mark/runmap/scripts/fast_path.sh`:
```bash
# After pmtiles convert, upload to R2
rclone copy "$TILES_DIR/runs.pmtiles" r2:runmap-tiles/
```

Edit `/home/mark/runmap/scripts/slow_path_minimal.sh`:
```bash
# After pmtiles convert, upload to R2
rclone copy "$TILES_DIR/runs.pmtiles" r2:runmap-tiles/
```

4. **Update map to use R2 URL:**

Edit `/var/www/runmap/index.html`:
```javascript
'runs': {
    type: 'vector',
    url: 'pmtiles://https://pub-YOUR-ID.r2.dev/runs.pmtiles'
}
```

5. **Optional: Custom domain**
```
# In Cloudflare R2 settings, add custom domain
# tiles.runmap.chouinard.me → runmap-tiles bucket
```

## Maintenance

### Update System

```bash
sudo apt update && sudo apt upgrade -y
sudo systemctl restart runmap-api
sudo systemctl reload nginx
```

### Clean Up Old Data

```bash
# Remove old GPX files (optional)
find /home/mark/runmap/gpx -name "*.gpx" -mtime +90 -delete

# Vacuum database
psql -U runmap_user -d runmap -c "VACUUM ANALYZE;"
```

### Regenerate All Tiles

```bash
# Minimal (runs only - safe for 20GB RAM server)
bash /home/mark/runmap/scripts/slow_path_minimal.sh

# Full coverage (requires 32GB+ RAM or run on Mac Studio)
bash /home/mark/runmap/scripts/slow_path.sh
```
