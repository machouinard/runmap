#!/bin/bash
# Quick activation script for local development
# Usage: source activate_dev.sh

# Activate Python venv
source api/venv/bin/activate

# Load environment variables
source scripts/common/env.sh

echo "✅ Development environment activated!"
echo ""
echo "Database: $DB_NAME @ $DB_HOST"
echo "Python: $(which python3)"
echo ""
echo "Quick commands:"
echo "  cd api && python app.py     # Start Flask API on port 5001"
echo "  cd web && npm run dev       # Start React dev server"
echo "  psql                        # Connect to database"
