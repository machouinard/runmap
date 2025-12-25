# Environment Setup Quick Reference

## TL;DR

**Terminal 1 - Frontend:**
```bash
pnpm run dev
```

**Terminal 2 - Flask API:**
```bash
cd api
source venv/bin/activate  # Activate Python virtual environment
flask run --debug
```

**Mac Studio (Local Dev):**
```bash
ln -sf .env.local .env
cd api && ln -sf .env.local .env
```

**Ubuntu Server (Production):**
```bash
# Handled automatically by deploy.sh
./scripts/deploy.sh
```

## Environment Files

| File | Purpose | Git Tracked? | Location |
|------|---------|--------------|----------|
| `.env` | Active config (symlink/copy) | ❌ No | Project root |
| `.env.local` | Mac Studio local dev config | ✅ Yes | Project root |
| `.env.production` | Ubuntu server production config | ✅ Yes | Project root |
| `.env.example` | Template for new setups | ✅ Yes | Project root |
| `api/.env` | Active Flask config (symlink/copy) | ❌ No | api/ |
| `api/.env.local` | Flask local dev config | ✅ Yes | api/ |
| `api/.env.production` | Flask production config | ✅ Yes | api/ |
| `api/.env.example` | Flask template | ✅ Yes | api/ |

## Key Differences Between Environments

| Setting | Local (Mac Studio) | Production (Ubuntu) |
|---------|-------------------|---------------------|
| `DB_HOST` | `localhost` | `localhost` |
| `DB_NAME` | `runmap_local` | `runmap` |
| `DB_USER` | `runmap_user` | `runmap_user` |
| `PGPASSWORD` | `fucker` | `fucker` |
| `PROJECT_ROOT` | `/Users/markchouinard/Development/GIS/runs-cdm` | `/home/mark/runmap` |
| `TILES_DIR` | `/Users/.../runs-cdm/tiles` | `/home/mark/runmap/tiles` |
| `GPX_DIR` | `/Users/.../runs-cdm/gpx` | `/home/mark/runmap/gpx` |
| `FLASK_DEBUG` | `1` | `0` |
| `FLASK_ENV` | `development` | `production` |

## How It Works

### Scripts (`scripts/*.sh`)
1. Source `scripts/common/env.sh`
2. Loads variables from `$PROJECT_ROOT/.env`
3. Sets defaults: `DB_NAME=${DB_NAME:-runmap_local}`
4. Exports all variables for `psql`, `ogr2ogr`, etc.

### Flask API (`api/app.py`)
1. Calls `load_dotenv()` from python-dotenv
2. Loads from `api/.env` (in same directory as app.py)
3. Uses variables: `os.getenv('DB_NAME')`, etc.

### Deployment (`scripts/deploy.sh`)
1. Copies `.env.production` → `.env` on server
2. Copies `api/.env.production` → `api/.env` on server
3. Restarts services

## Database Setup Order

**IMPORTANT:** SQL files have dependencies. Run in this order:

```bash
# 1. Core tables
psql -U runmap_user -d runmap_local -h localhost -f db/01_create_tables.sql

# 2. Import OSM street data (your own process)

# 3. Create street blocks (REQUIRED before segment schema!)
psql -U runmap_user -d runmap_local -h localhost -f db/04_phase1_intersection_split.sql

# 4. Segment-visited coverage schema
psql -U runmap_user -d runmap_local -h localhost -f db/04_segment_schema.sql

# 5-8. Additional tables
psql -U runmap_user -d runmap_local -h localhost -f db/12_activity_tables.sql
psql -U runmap_user -d runmap_local -h localhost -f db/13_location_tracking.sql
psql -U runmap_user -d runmap_local -h localhost -f db/14_workout_hash_migration.sql
psql -U runmap_user -d runmap_local -h localhost -f db/15_add_route_name.sql

# 9-10. Views
psql -U runmap_user -d runmap_local -h localhost -f db/02_create_views.sql
psql -U runmap_user -d runmap_local -h localhost -f db/05_utility_views.sql
```

**Why the order matters:**
- `04_segment_schema.sql` creates tables with foreign keys to `streets_blocks_32610`
- `streets_blocks_32610` is created by `04_phase1_intersection_split.sql`
- If you run segment schema first, you get: `ERROR: relation "runmap.streets_blocks_32610" does not exist`

## Troubleshooting

### ❌ Flask 500 error: "ModuleNotFoundError: No module named 'psycopg2'"
```bash
# You forgot to activate the virtual environment!
cd api
source venv/bin/activate
flask run --debug
```

### ❌ "ERROR: .env file not found"
```bash
# You need to create the symlink
ln -sf .env.local .env
```

### ❌ "ERROR: relation does not exist"
```bash
# You're running SQL files out of order
# See "Database Setup Order" above
```

### ❌ Scripts use wrong database
```bash
# Check what .env points to
ls -la .env

# Should show on Mac Studio:
# .env -> .env.local

# If not, recreate symlink:
rm .env
ln -sf .env.local .env
```

### ❌ Flask can't connect to database
```bash
# Check API .env
cd api
ls -la .env

# Should show:
# .env -> .env.local

# If not:
rm .env
ln -sf .env.local .env
```

### ❌ Deploy script fails
```bash
# Make sure you have .env.production files committed
git status
# Should show .env.production and api/.env.production as tracked

# Check they exist
ls -la .env.production api/.env.production
```

## First-Time Setup Checklist

**Mac Studio (one-time setup):**
- [ ] Create `runmap_local` database
- [ ] Enable PostGIS extension
- [ ] Create `runmap` schema
- [ ] Symlink `.env.local` → `.env`
- [ ] Symlink `api/.env.local` → `api/.env`
- [ ] Run SQL files in order
- [ ] Import OSM street data
- [ ] Initialize segment coverage

**Ubuntu Server (handled by deploy.sh):**
- [ ] Database already exists with production data
- [ ] Deploy script copies `.env.production` → `.env`
- [ ] Deploy script copies `api/.env.production` → `api/.env`
- [ ] Services restart automatically

## See Also

- **[LOCAL_DEV_SETUP.md](docs/LOCAL_DEV_SETUP.md)** - Detailed setup guide with full instructions
- **[CLAUDE.md](CLAUDE.md)** - Full project documentation and architecture
- **[docs/README.md](docs/README.md)** - Master documentation index
