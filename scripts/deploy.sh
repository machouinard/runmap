#!/bin/bash
# Deploy to production server
#
# Usage:
#   ./scripts/deploy.sh              # Deploy without tiles or GPX (server regenerates tiles from API uploads)
#   ./scripts/deploy.sh --tiles      # Deploy with tiles (for bulk imports/testing)
#   ./scripts/deploy.sh --gpx        # Deploy GPX files (for bulk imports where files were processed locally)
#   ./scripts/deploy.sh --deps       # Install Python dependencies (only needed when requirements.txt changes)
#   ./scripts/deploy.sh --aoi        # Sync AOI geometry from local to production
#   ./scripts/deploy.sh --all        # Deploy everything (tiles + GPX + deps)

set -e

# Parse arguments
DEPLOY_TILES=false
DEPLOY_GPX=false
INSTALL_DEPS=false
DEPLOY_AOI=false

for arg in "$@"; do
  case $arg in
    --tiles)
      DEPLOY_TILES=true
      ;;
    --gpx)
      DEPLOY_GPX=true
      ;;
    --deps)
      INSTALL_DEPS=true
      ;;
    --aoi)
      DEPLOY_AOI=true
      ;;
    --all)
      DEPLOY_TILES=true
      DEPLOY_GPX=true
      INSTALL_DEPS=true
      ;;
  esac
done

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

echo "Deploying frontend to server..."
rsync -avz --delete -e "ssh -p $SERVER_PORT" \
  "$PROJECT_ROOT/web/build/" \
  "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/web/build/"

echo "Deploying environment configuration to server..."
# Deploy root .env file (scripts need this)
scp -P $SERVER_PORT "$PROJECT_ROOT/.env.production" \
  "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/.env"

# Deploy API .env file
scp -P $SERVER_PORT "$PROJECT_ROOT/api/.env.production" \
  "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/api/.env"

echo "Deploying API code to server..."
rsync -avz -e "ssh -p $SERVER_PORT" \
  "$PROJECT_ROOT/api/app.py" \
  "$PROJECT_ROOT/api/valhalla_client.py" \
  "$PROJECT_ROOT/api/requirements.txt" \
  "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/api/"

if [ "$INSTALL_DEPS" = true ]; then
  echo "Installing/updating Python dependencies on server..."
  ssh -p $SERVER_PORT "$SERVER_USER@$SERVER_HOST" "cd $SERVER_PATH/api && venv/bin/pip install -r requirements.txt --quiet && echo '✓ Dependencies installed' || echo '⚠ Could not install dependencies (you may need to do this manually)'"
else
  echo "Skipping dependency installation (use --deps flag to install)"
fi

echo "Deploying scripts to server..."
rsync -avz --delete -e "ssh -p $SERVER_PORT" \
  --exclude 'obsolete' \
  "$PROJECT_ROOT/scripts/" \
  "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/scripts/"

echo "Deploying OSM data file to server..."
rsync -avz --progress -e "ssh -p $SERVER_PORT" \
  "$PROJECT_ROOT/norcal-latest.osm.pbf" \
  "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/"

if [ "$DEPLOY_TILES" = true ]; then
  echo "Deploying tiles to server..."
  rsync -avz -e "ssh -p $SERVER_PORT" \
    "$PROJECT_ROOT/tiles/"*.pmtiles \
    "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/tiles/"
else
  echo "Skipping tiles deployment (server will regenerate from API uploads)"
fi

if [ "$DEPLOY_GPX" = true ]; then
  echo "Deploying GPX files to server..."
  # Check if local GPX directory has files
  GPX_COUNT=$(find "$PROJECT_ROOT/gpx" -name "*.gpx" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$GPX_COUNT" -gt 0 ]; then
    echo "Found $GPX_COUNT GPX files to deploy"
    rsync -avz -e "ssh -p $SERVER_PORT" \
      "$PROJECT_ROOT/gpx/" \
      "$SERVER_USER@$SERVER_HOST:$SERVER_PATH/gpx/"
  else
    echo "⚠ No GPX files found in $PROJECT_ROOT/gpx/"
    echo "  Run 'bash scripts/sync_gpx_from_server.sh' first to download from server"
  fi
else
  echo "Skipping GPX deployment (use --gpx flag to deploy GPX files)"
fi

if [ "$DEPLOY_AOI" = true ]; then
  echo "Syncing AOI geometry to production..."

  # Export AOI from local database
  AOI_GEOM=$(psql -U runmap_user -d runmap_local -t -A -c "SELECT ST_AsText(geom) FROM runmap.aoi WHERE name='sacramento';")

  if [ -z "$AOI_GEOM" ]; then
    echo "⚠ No AOI found with name 'sacramento' in local database"
  else
    # Update AOI on production
    ssh -p $SERVER_PORT "$SERVER_USER@$SERVER_HOST" "PGPASSWORD=\$PGPASSWORD psql -U runmap_user -d runmap -c \"UPDATE runmap.aoi SET geom = ST_GeomFromText('$AOI_GEOM', 4326) WHERE name='sacramento';\""
    echo "✓ AOI geometry synced to production"
    echo ""
    echo "NOTE: To reimport streets for the new AOI, run on server:"
    echo "  cd $SERVER_PATH && bash scripts/add_streets_for_aoi.sh --prune <osm_file.pbf> sacramento"
    echo "  bash scripts/rebuild_all_coverage.sh"
  fi
else
  echo "Skipping AOI sync (use --aoi flag to sync AOI geometry)"
fi

echo "Restarting API service..."
ssh -p $SERVER_PORT "$SERVER_USER@$SERVER_HOST" "sudo -n systemctl restart runmap-api.service 2>/dev/null && echo '✓ API service restarted' || echo '⚠ Could not restart API service (you may need to do this manually)'"

echo "Reloading nginx..."
ssh -p $SERVER_PORT "$SERVER_USER@$SERVER_HOST" "sudo -n systemctl reload nginx 2>/dev/null && echo '✓ Nginx reloaded' || echo '⚠ Could not reload nginx (you may need to do this manually)'"

echo ""
echo "✓ Deployment complete!"
echo "Live at: https://run.chouinard.me"
echo ""
echo "Manual steps if needed:"
echo "  Restart API: ssh -p $SERVER_PORT $SERVER_USER@$SERVER_HOST 'sudo systemctl restart runmap-api.service'"
echo "  Reload nginx: ssh -p $SERVER_PORT $SERVER_USER@$SERVER_HOST 'sudo systemctl reload nginx'"