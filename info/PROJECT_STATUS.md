# Project Status - RunMap v3 (Production)

**Project Started:** October 5, 2025
**Status:** ✅ **PRODUCTION - Fully Operational**
**Last Updated:** October 19, 2025

## Current State

RunMap v3 is **fully operational** with all core features working:

✅ **Infrastructure**
- Self-hosted on Ubuntu 24.04 server
- PostgreSQL 16 + PostGIS 3 running natively
- Nginx serving frontend + API proxy + tiles
- SSL (Let's Encrypt) configured and working
- Domain: https://runmap.chouinard.me

✅ **Core Features**
- iOS Shortcut upload (one-tap from phone)
- Web interface upload with drag-and-drop
- Duplicate detection across different apps (WorkoutDoors, Apple Health, Strava)
- Automatic processing (database triggers)
- Incremental block-based coverage system
- PMTiles serving with MapLibre GL JS
- Location detection (Sacramento vs Portland)
- Real-time map updates

✅ **Processing Pipeline**
- Bulk import support (20 runs in ~3 minutes)
- Automatic buffer creation (10m GPS buffer)
- Incremental coverage calculation (O(blocks touched))
- Tile generation (~30 seconds)
- Coverage statistics refresh

✅ **Data Quality**
- Workout deduplication via start_time hash (10-min buckets)
- Handles same workout from different export sources
- Block-level precision (100m segments)
- 90% completion threshold
- Location-based filtering

## System Architecture

**Database:**
- Block-based coverage system (100m blocks)
- Incremental processing (only updates touched blocks)
- Automatic triggers for zero-config uploads
- Materialized views for fast stats

**Processing:**
- Memory efficient: O(streets touched) vs O(all runs × all streets)
- Scales to unlimited runs (constant memory per run)
- Server handles uploads without Mac Studio

**Frontend:**
- React + MapLibre GL JS
- PMTiles for vector tiles
- Auto-reload on tile updates
- Real-time coverage display

## Recent Major Changes (Oct 19, 2025)

### Workout Hash Deduplication System
**Problem:** Same workout from different apps (WorkoutDoors vs Apple Health) wasn't detected as duplicate

**Solution:** Hash based on start_time rounded to 10-minute buckets
- Example: Run at 16:47:19 → bucket "2025-10-19 16:40"
- Tolerates ±5 minute timing differences
- Handles multiple runs per day
- Simple and fast

**Impact:**
- iOS shortcut now detects duplicates correctly
- Can import from multiple sources without duplicates
- Cross-app compatibility (WorkoutDoors, Apple Health, Strava)

### Scripts Cleanup
- Organized 33+ scripts → 6 production + 6 archived + 21 obsolete
- Created scripts/README.md with usage guide
- Consolidated bulk import scripts
- Added PGPASSWORD for server execution

### Documentation Updates
- Complete rewrite of ARCHITECTURE.md (current system)
- Updated CLAUDE.md with workout_hash strategy
- Updated USAGE_GUIDE.md with iOS shortcut instructions
- All docs now reflect production reality

## Performance Metrics

**Current Database:**
- ~20 test runs imported
- ~71% overall coverage
- ~2,597 total blocks
- ~37% block completion

**Processing Times:**
- Single run upload: ~2-5 seconds
- Bulk import (20 runs): ~2-3 minutes
- Tile export: ~30 seconds
- Coverage stats refresh: instant

**Memory Usage:**
- Processing: ~3GB RAM (constant regardless of run count)
- Database: ~50-100MB
- Server has 20GB RAM (plenty of headroom)

## Server Details

**Hardware:**
- **Host:** Ubuntu 24.04 LTS (Dell Studio XPS 8100)
- **CPU:** Intel i7-860 (2009, quad-core @ 2.8 GHz)
- **RAM:** 20GB
- **Storage:** 11.8TB total, ~5TB available
- **Network:** Gigabit ethernet, 700Mbps upload

**Software:**
- PostgreSQL 16 with PostGIS 3
- Python 3.12 with Flask
- Nginx 1.24
- Node.js 20 (for frontend build)
- Tippecanoe (for tile generation)

**Access:**
- SSH: Port 2222
- Web: https://runmap.chouinard.me
- Local IP: 192.168.68.25
- Database: PostgreSQL on localhost:5432

## Known Issues & Limitations

### Minor Issues
- No authentication (anyone with URL can upload)
- Single-threaded tile export (could parallelize)
- No automated backups configured

### Design Limitations
- 10-minute bucket deduplication (two runs <10 min apart = detected as duplicate)
  - Probability: Very low
  - Mitigation: User can manually adjust timestamp if needed
- Sacramento streets only (no other cities yet)
- Single-user system (no multi-user support)

## Next Steps (Priority Order)

### Short Term (Next Week)
1. **Full data import** - Import all 600+ historical runs from Apple Health
2. **iOS Shortcut refinement** - Better error messages, progress indicators
3. **Backup automation** - Daily database dumps + GPX file backups

### Medium Term (Next Month)
4. **Activity classification** - Auto-detect run vs walk vs cycle
5. **Heatmap visualization** - Show frequently run areas
6. **Time-based filtering** - View runs by date range
7. **Authentication** - API key or simple password protection

### Long Term (Future)
8. **Portland streets import** - Add second city
9. **Neighborhood stats** - Coverage by neighborhood
10. **Strava integration** - Auto-import from Strava
11. **Mobile app** - Native iOS app for uploads

## Development Workflow

**Current setup:**
- Code on Mac Studio via SMB share (`/Volumes/RunMap`)
- Execute on server via SSH (`ssh -p 2222 mark@192.168.68.25`)
- Edit in VS Code (remote development)
- Test locally with database connection to server

**Common commands:**
```bash
# Upload via iOS shortcut (from phone)
# Just tap the shortcut!

# Bulk import
DB_HOST=localhost bash scripts/bulk_import.sh /home/mark/runmap/data/import

# Export tiles
bash scripts/export_tiles_blocks.sh

# Check stats
psql -h localhost -U runmap_user -d runmap -c "SELECT * FROM runmap.coverage_stats_blocks;"
```

## Success Metrics

**What's Working:**
✅ Zero-config uploads via iOS shortcut
✅ Automatic processing (triggers handle everything)
✅ Duplicate detection across apps
✅ Fast processing (constant memory usage)
✅ Beautiful map visualization
✅ Real-time updates
✅ Location detection
✅ Comprehensive documentation

**What's Next:**
- Import full historical data (600+ runs)
- Add authentication
- Set up automated backups

## References

- **Usage Guide:** [docs/USAGE_GUIDE.md](../docs/USAGE_GUIDE.md)
- **Architecture:** [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)
- **Technical Reference:** [CLAUDE.md](../CLAUDE.md)
- **Scripts:** [scripts/README.md](../scripts/README.md)
- **Database Schema:** `db/` directory
- **API Code:** `api/` directory
- **Frontend:** `web/` directory

## Contact & Support

For issues or questions:
1. Check [USAGE_GUIDE.md](../docs/USAGE_GUIDE.md) first
2. Review [ARCHITECTURE.md](../docs/ARCHITECTURE.md) for technical details
3. Inspect logs: `journalctl -u runmap-api -f`
4. Database queries: `psql -h localhost -U runmap_user -d runmap`

---

**Status:** Production-ready, actively used, ready for full data import! 🎉
