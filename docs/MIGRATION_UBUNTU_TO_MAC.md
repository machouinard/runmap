# Migration Strategy: Ubuntu Server → Mac Studio Primary Development

## Overview

**Goal:** Make Mac Studio the primary development environment, with Ubuntu server only for production hosting.

**Current State:**
- Development happening over SMB mount (`/Volumes/RunMap` → `/home/mark/runmap`)
- PostgreSQL + PostGIS on Ubuntu server (192.168.68.25)
- Nginx serving production app on Ubuntu
- Slow development (SMB latency, npm over network)

**Target State:**
- Full local development on Mac Studio
- PostgreSQL + PostGIS running locally on Mac
- Fast React dev server, instant HMR
- Ubuntu server only receives production builds

---

## Architecture Comparison

### Current (Hybrid - Problematic)
```
Mac Studio
  └─ SMB mount → /home/mark/runmap (Ubuntu)
      ├─ npm run dev (slow over network)
      ├─ Database on Ubuntu (network calls)
      └─ Files on Ubuntu disk
```

### Proposed (Mac-Primary with Shared Database)
```
Mac Studio
  ├─ Local code (~/Projects/runmap)
  ├─ Local development server (fast)
  ├─ Local scripts, fast processing
  ├─ Connect to Ubuntu PostgreSQL (LAN) ─────┐
  └─ Deploy → rsync build → Ubuntu          │
                                             │
Ubuntu Server (Production + Database)       │
  ├─ Nginx (reverse proxy)                  │
  ├─ PostgreSQL (shared database) ←─────────┘
  ├─ Flask API (production)
  └─ Static React build (from Mac)
```

**Key Point:** PostgreSQL stays on Ubuntu. Mac connects remotely over LAN.

---

## Migration Steps

### Phase 1: Set Up Mac Development Environment

#### 1.1 Install PostgreSQL Client Tools (NOT the server)

**You DON'T need to install PostgreSQL server on Mac!** Just the client tools for `psql`, `pg_dump`, etc.

```bash
# Install just the PostgreSQL client (libpq)
brew install libpq

# Add to PATH (add to ~/.zshrc)
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Verify installation
psql --version  # Should show PostgreSQL client version

# Test connection to server
psql -U runmap_user -d runmap -h 192.168.68.25
# Should connect to Ubuntu database
```

**Note:** PostgreSQL stays on Ubuntu server. Mac just connects to it remotely.

#### 1.2 Update `.env` for Mac Development

```bash
# Create .env file at /Users/markchouinard/Development/GIS/runs-cdm/.env
DB_HOST=192.168.68.25  # Ubuntu server IP (NOT localhost!)
DB_NAME=runmap
DB_USER=runmap_user
PGPASSWORD=fucker

PROJECT_ROOT=/Users/markchouinard/Development/GIS/runs-cdm
TILES_DIR=/Users/markchouinard/Development/GIS/runs-cdm/tiles
TMP_DIR=/tmp/runmap
```

**Important:** `DB_HOST=192.168.68.25` means Mac connects to Ubuntu PostgreSQL over LAN.

---

### Phase 2: Move Project to Mac Local Disk

#### 2.1 Clone Repository to Mac

```bash
# Create directory structure
mkdir -p /Users/markchouinard/Development/GIS
cd /Users/markchouinard/Development/GIS

# Clone from GitHub (recommended)
git clone <your-repo-url> runs-cdm
cd runs-cdm

# OR: Copy from SMB mount
cp -R /Volumes/RunMap runs-cdm
cd runs-cdm
```

#### 2.2 Install Dependencies

```bash
# Install Node.js if needed
brew install node

# Install Python dependencies
cd /Users/markchouinard/Development/GIS/runs-cdm/api
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Install frontend dependencies
cd /Users/markchouinard/Development/GIS/runs-cdm/web
npm install
```

#### 2.3 Install GDAL/Tippecanoe Tools

```bash
# Install geospatial tools
brew install gdal tippecanoe pmtiles

# Verify
ogr2ogr --version
tippecanoe --version
pmtiles --version
```

---

### Phase 3: Test Local Development Workflow

#### 3.1 Test Database Connection

```bash
cd /Users/markchouinard/Development/GIS/runs-cdm

# Test scripts work locally
bash scripts/export_tiles_blocks.sh

# Should connect to 192.168.68.25 PostgreSQL
```

#### 3.2 Test React Dev Server

```bash
cd /Users/markchouinard/Development/GIS/runs-cdm/web

# Update vite.config.ts to point to local API
# (Change target from https://runmap.chouinard.me to http://localhost:5000)

npm run dev
# Should start instantly, HMR should be fast
```

#### 3.3 Test API Server

```bash
cd /Users/markchouinard/Development/GIS/runs-cdm/api
source venv/bin/activate

# .env should point to server database
# DB_HOST=192.168.68.25

python app.py
# API should run on localhost:5000
```

#### 3.4 Import Test GPX Files

```bash
# Import a few GPX files locally
bash scripts/bulk_import.sh ~/Downloads/test-gpx-files/

# Should process quickly (no SMB lag)
```

---

### Phase 4: Update Production Deployment Workflow

#### 4.1 Nginx Configuration - **NO CHANGES NEEDED!**

Your current nginx config is already perfect:
```nginx
# React static files
location / {
    root /home/mark/runmap/web/build;
    index index.html;
    try_files $uri $uri/ /index.html;
}
```

This serves from `web/build/` which is where `npm run build` outputs files. **No need to move to /var/www**.

#### 4.2 Set Up SSH Key Authentication (Security Best Practice)

**IMPORTANT:** Never hardcode passwords in scripts! Use SSH keys instead.

```bash
# Check if you have an existing SSH key
ls -la ~/.ssh/id_*.pub

# If you already have ~/.ssh/id_rsa.pub, use that!
# Otherwise, generate a new one:
# ssh-keygen -t ed25519 -C "mark@mac-studio"

# Copy your public key to Ubuntu server (uses your existing key by default)
ssh-copy-id -p 2222 mark@192.168.68.25

# Test passwordless SSH
ssh -p 2222 mark@192.168.68.25 "echo 'SSH key authentication works!'"
```

**Configure passwordless sudo for nginx reload (optional but recommended):**

On the Ubuntu server, allow your user to reload nginx without password:

```bash
# On Ubuntu server
sudo visudo

# Add this line at the end:
mark ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx, /usr/bin/systemctl restart nginx
```

This allows `sudo systemctl reload nginx` without prompting for a password, but ONLY for that specific command.

#### 4.3 Deployment Script (New)

Create `/Users/markchouinard/Development/GIS/runs-cdm/scripts/deploy.sh`:

```bash
#!/bin/bash
# Deploy to production server

set -e

# Load environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Server configuration
SERVER_USER="mark"
SERVER_HOST="192.168.68.25"
SERVER_PORT="2222"
SERVER_PATH="/home/mark/runmap"

echo "Building React app..."
cd "$PROJECT_ROOT/web"
npm run build

echo "Deploying to server..."
rsync -avz --delete -e "ssh -p $SERVER_PORT" \
  "$PROJECT_ROOT/web/build/" \
  "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/web/build/"

echo "Reloading nginx..."
ssh -p $SERVER_PORT "$SERVER_USER@$SERVER_HOST" "sudo systemctl reload nginx"

echo ""
echo "✓ Deployment complete!"
echo "Live at: https://runmap.chouinard.me"
```

Make it executable:
```bash
chmod +x /Users/markchouinard/Development/GIS/runs-cdm/scripts/deploy.sh
```

**Security Notes:**
- ✅ No passwords in scripts
- ✅ SSH key authentication only
- ✅ Passwordless sudo limited to specific nginx commands only
- ✅ Safe to commit to version control

#### 4.4 Deployment Process

```bash
# 1. Develop locally on Mac
cd /Users/markchouinard/Development/GIS/runs-cdm/web
npm run dev  # Fast development

# 2. Make changes, test locally

# 3. Commit changes
git add .
git commit -m "Add new feature"
git push

# 4. Deploy to production
bash scripts/deploy.sh
```

---

## Concerns & Solutions

### Concern 1: Database Performance

**Issue:** Will remote database be too slow?

**Answer:** No! LAN database access is fast enough:
- **Network speed:** 1Gbps+ Ethernet on Mac Studio
- **Latency:** ~1ms on local network
- **Query speed:** Indistinguishable from localhost for typical queries
- **Bulk operations:** Still fast (PostGIS calculations happen on server)

**When you WOULD need local PostgreSQL:**
- Offline development (no server access)
- Testing database migrations (don't want to touch production)
- Developing on airplane/without network

**For your use case:** Shared database is perfect. Keep it simple.

**Alternative (if you really want local database):**
- Install PostgreSQL on Mac: `brew install postgresql@16 postgis`
- Periodic dumps from Ubuntu: `pg_dump` → `pg_restore`
- **Not recommended** - adds complexity with no real benefit

### Concern 2: GPX Files Location

**Issue:** Where to store GPX files?

**Current:** `/home/mark/runmap/gpx/` on Ubuntu

**Options:**

**A) Keep on Ubuntu, sync as needed**
```bash
# Download specific files when needed
scp -P 2222 mark@192.168.68.25:/home/mark/runmap/gpx/route-*.gpx ~/Downloads/
```

**B) Mirror to Mac**
```bash
# One-time sync
rsync -avz -e "ssh -p 2222" mark@192.168.68.25:/home/mark/runmap/gpx/ ~/Projects/runmap/gpx/
```

**C) Use git-lfs for large files**
- Track GPX files in Git with Git LFS
- Sync via GitHub
- **Best for:** Sharing files across machines

**Recommendation:** **Option B** (mirror to Mac) for development, keep originals on Ubuntu.

### Concern 3: PMTiles Generation Performance

**Issue:** Does Mac Studio have enough power for tippecanoe?

**Answer:** YES! Mac Studio (M1/M2) is **much faster** than the Ubuntu server for:
- Tippecanoe processing (CPU-bound)
- Node.js builds (disk I/O)
- npm install (network + disk)

You'll actually see **better performance** on Mac.

### Concern 4: Production Data Safety

**Issue:** What if I accidentally overwrite production database?

**Solutions:**

1. **Always use different database names:**
   ```bash
   # Mac .env
   DB_NAME=runmap_dev

   # Ubuntu .env (production)
   DB_NAME=runmap
   ```

2. **Read-only production access (optional):**
   ```sql
   -- On Ubuntu
   CREATE USER runmap_readonly WITH PASSWORD 'readonly';
   GRANT CONNECT ON DATABASE runmap TO runmap_readonly;
   GRANT SELECT ON ALL TABLES IN SCHEMA runmap TO runmap_readonly;
   ```

3. **Regular backups:**
   ```bash
   # Cron job on Ubuntu (already should exist)
   0 2 * * * pg_dump -U runmap_user runmap | gzip > /backups/runmap_$(date +\%Y\%m\%d).sql.gz
   ```

### Concern 5: File Paths in Code

**Issue:** Hardcoded paths like `/home/mark/runmap`?

**Solution:** Already using `PROJECT_ROOT` from `.env`! Just update `.env` on Mac:
```bash
PROJECT_ROOT=/Users/markchouinard/runmap
```

All scripts use `$PROJECT_ROOT`, so they'll work on both machines.

---

## Migration Checklist

### Pre-Migration
- [ ] Commit all current changes
- [ ] Push to GitHub
- [ ] Backup Ubuntu database: `pg_dump runmap > backup.sql`
- [ ] Document current Ubuntu setup (ports, services, cron jobs)

### Mac Setup
- [ ] Install PostgreSQL **client tools only** (`brew install libpq`)
- [ ] Install GDAL + Tippecanoe (`brew install gdal tippecanoe pmtiles`)
- [ ] Install Node.js (`brew install node`)
- [ ] Create directory: `mkdir -p /Users/markchouinard/Development/GIS`
- [ ] Clone repo to Mac: `git clone <repo> /Users/markchouinard/Development/GIS/runs-cdm`
- [ ] Create `.env` file with **DB_HOST=192.168.68.25** (points to server)
- [ ] Install Python dependencies: `pip install -r api/requirements.txt`
- [ ] Install Node dependencies: `npm install` (in web/)
- [ ] Test database connection: `psql -U runmap_user -d runmap -h 192.168.68.25`

### Testing
- [ ] Test database connection: `psql -U runmap_user runmap`
- [ ] Test scripts: `bash scripts/export_tiles_blocks.sh`
- [ ] Test API: `python api/app.py`
- [ ] Test React dev: `npm run dev`
- [ ] Import test GPX file: `bash scripts/ingest_gpx.sh test.gpx`
- [ ] Verify tiles generate correctly

### Deployment Setup
- [ ] Create deployment script: `scripts/deploy.sh`
- [ ] Test deployment: `bash scripts/deploy.sh`
- [ ] Verify production site works
- [ ] Set up git hooks (optional): pre-push linting, tests

### Ubuntu Server (Minimal Changes)
- [ ] Keep PostgreSQL running (for production data)
- [ ] Keep Nginx running (to serve static files)
- [ ] Keep API service running (Flask)
- [ ] **No path changes needed** - nginx already serves from web/build/

---

## Recommended Setup

**Simple and effective:**

1. **Mac Studio: Development Environment**
   - Local code (`/Users/markchouinard/Development/GIS/runs-cdm`)
   - Fast React dev server (`npm run dev`)
   - All scripts run locally
   - **Connects to Ubuntu PostgreSQL remotely** (192.168.68.25)
   - Commit to Git

2. **Ubuntu Server: Production + Database**
   - **PostgreSQL (shared for both dev and production)**
   - Nginx (serves static React build)
   - Flask API (production)
   - Receives deploys from Mac

3. **Deployment Flow:**
   ```
   Mac: Code + Test → Commit → Build → Deploy
                                          ↓
   Ubuntu: rsync receives build → Reload nginx
   ```

4. **Database Strategy:**
   - **RECOMMENDED:** Mac connects to Ubuntu PostgreSQL remotely
   - LAN is fast enough (~1ms latency)
   - Single source of truth
   - No sync needed
   - **Do NOT install PostgreSQL on Mac unless you need offline development**

---

## Summary: Do You Need to Move to /var/www?

**NO!** Your current setup is perfect:

```nginx
location / {
    root /home/mark/runmap/web/build;
    ...
}
```

This is **completely fine**. The `/var/www` convention is just that - a convention. Many production apps run from `/home`, `/opt`, or `/srv`.

**Only change if:**
- You want to follow strict Linux FHS (Filesystem Hierarchy Standard)
- You're setting up multiple sites and want organization
- You need specific permissions (www-data ownership)

**Current setup works because:**
- Nginx has read access to `/home/mark/runmap`
- Files are already there
- Paths are consistent between development and production

**Recommendation:** Keep everything at `/home/mark/runmap` and just rsync the `web/build/` directory on deploy.

---

## Next Steps

1. **Try local development first** without changing production
2. **Test deployment script** to ensure rsync works
3. **Decide on database strategy** (shared vs. local)
4. **Gradually migrate** - no need to do everything at once

You can run both environments in parallel during migration - develop on Mac, deploy to Ubuntu, and switch over when comfortable.
