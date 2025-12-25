# Pre-Bulk Import Checklist
**Target:** Import ~650 runs from Portland
**Date:** October 2025
**Current state:** 17 runs, 8 walks in database

## System Readiness

### ✅ Hardware Resources (VERIFIED)
- **Mac disk space:** 128 GB available (need ~50 MB for 650 runs = plenty)
- **Server disk space:** 448 GB available (need ~200 MB total DB growth = plenty)
- **Server RAM:** 31 GB total, 29 GB available (need ~15 MB per run = plenty)
- **Database current size:** 581 MB (will grow to ~800 MB)

### ✅ Software Dependencies (VERIFIED)
- Python 3.14 installed
- psycopg3 (3.2.11) installed - compatible with Python 3.14
- gpxpy, shapely, geopy installed
- PostgreSQL connection working from Mac to Ubuntu server

### ✅ Network Connectivity (VERIFIED)
- SSH key authentication working
- PostgreSQL connection working (192.168.68.25:5432)
- No password required for database operations

---

## Projected Impact of 650 Run Import

### Database Growth
| Metric | Current | After 650 Runs | Growth |
|--------|---------|----------------|--------|
| runs_raw | 1.1 MB | ~43 MB | +42 MB |
| runs_buffered_32610 | 1.8 MB | ~69 MB | +67 MB |
| block_coverage_32610 | 552 KB | ~700 KB | +150 KB |
| Total DB size | 581 MB | ~780 MB | +200 MB |

### Processing Time Estimates
- **Per run:** ~13 seconds (buffer + coverage)
- **650 runs:** ~8,450 seconds = **~2.3 hours** total
- **Plus tile export:** +60 seconds once at end

### Coverage Impact
- **Current coverage:** 1,505 / 2,597 blocks (58%)
- **Portland runs:** Will NOT affect Sacramento coverage (different location)
- **Expected result:** Portland runs stored but marked as `location = 'portland'`

---

## CRITICAL ISSUES TO TEST FIRST

### ⚠️ Issue 1: Portland vs Sacramento Location Detection

**Problem:** Your 650 runs are from Portland, but your coverage system is for Sacramento streets.

**Current behavior:**
- `detect_location()` function auto-tags runs as 'sacramento', 'portland', or 'other'
- Only Sacramento runs should update block coverage
- Portland runs should be stored but NOT processed for coverage

**Test needed:**
```bash
# Test with a Portland GPX file
bash scripts/ingest_gpx.sh /path/to/portland_run.gpx

# Verify location is detected correctly
psql -c "SELECT id, filename, location FROM runmap.runs_raw ORDER BY uploaded_at DESC LIMIT 1;"

# Verify it did NOT create coverage for Portland run
psql -c "SELECT COUNT(*) FROM runmap.runs_buffered_32610;"
```

**Expected:** Portland runs should be inserted but NOT buffered/processed for Sacramento coverage.

### ⚠️ Issue 2: Bulk Import Script May Process Non-Sacramento Runs

**Problem:** The bulk import script calls processing functions for ALL imported runs:

```bash
# From scripts/bulk_import.sh line 93-103
for RUN_ID in $NEW_RUN_IDS; do
    psql -c "SELECT runmap.buffer_one_run('$RUN_ID'::uuid);
             SELECT runmap.apply_run_to_block_coverage('$RUN_ID'::uuid);"
done
```

This will try to create buffers and coverage for Portland runs, which should be skipped!

**Fix needed:** Update bulk_import.sh to only process Sacramento runs:

```sql
# Get IDs of runs without buffers (Sacramento only)
NEW_RUN_IDS=$(psql -t -A -c \
    "SELECT id FROM runmap.runs_raw r
     WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_32610 rb WHERE rb.run_id = r.id)
     AND location = 'sacramento'
     LIMIT $SUCCESS")
```

### ⚠️ Issue 3: Duplicate Detection

**Current system:** Uses `content_hash` (SHA256 of GPX content)

**Potential issue:** If you've already uploaded these 650 runs before, they'll be detected as duplicates.

**Test:**
```bash
# Try importing same file twice
bash scripts/ingest_gpx.sh /path/to/test_run.gpx
bash scripts/ingest_gpx.sh /path/to/test_run.gpx

# Should see "⚠ Duplicate run" on second attempt
```

---

## Pre-Import Tests (DO THESE FIRST!)

### Test 1: Single Portland Run Import
```bash
# Copy one Portland GPX file to test location
cp ~/path/to/portland_run.gpx ./data/test/

# Import it
bash scripts/ingest_gpx.sh ./data/test/portland_run.gpx

# Verify location detection
psql -c "SELECT id, filename, location, start_time FROM runmap.runs_raw WHERE filename LIKE '%portland%';"

# Verify NO buffer was created
psql -c "SELECT COUNT(*) FROM runmap.runs_buffered_32610 WHERE run_id = (SELECT id FROM runmap.runs_raw WHERE filename LIKE '%portland%');"
```

**Expected results:**
- Run inserted with `location = 'portland'`
- NO buffer created (should be 0 count)
- NO coverage update

### Test 2: Bulk Import with 5 Portland Runs
```bash
# Copy 5 Portland GPX files to test folder
mkdir -p ./data/test-bulk-portland
cp ~/path/to/portland_runs/*.gpx ./data/test-bulk-portland/ | head -5

# Run bulk import
bash scripts/bulk_import.sh ./data/test-bulk-portland/

# Verify all detected as Portland
psql -c "SELECT location, COUNT(*) FROM runmap.runs_raw GROUP BY location;"

# Verify NO coverage processing happened
psql -c "SELECT COUNT(*) FROM runmap.runs_buffered_32610;"  # Should still be 17
```

### Test 3: Database Backup Before Full Import
```bash
# Backup current database state
ssh -p 2222 mark@192.168.68.25 "pg_dump -U runmap_user runmap | gzip > /home/mark/backups/runmap_before_650_runs_$(date +%Y%m%d).sql.gz"

# Verify backup created
ssh -p 2222 mark@192.168.68.25 "ls -lh /home/mark/backups/*.sql.gz | tail -1"
```

### Test 4: Performance Monitoring Script
```bash
# Create monitoring script
cat > scripts/monitor_import.sh << 'EOF'
#!/bin/bash
source scripts/common/env.sh

echo "=== Import Progress Monitor ==="
while true; do
    clear
    echo "Time: $(date)"
    echo ""
    psql -c "SELECT
        location,
        COUNT(*) as total_runs,
        MAX(uploaded_at) as last_uploaded
    FROM runmap.runs_raw
    GROUP BY location
    ORDER BY location;"

    echo ""
    psql -c "SELECT
        COUNT(*) as runs_with_buffers
    FROM runmap.runs_buffered_32610;"

    echo ""
    echo "Database size:"
    psql -c "SELECT pg_size_pretty(pg_database_size('runmap'));"

    sleep 30
done
EOF

chmod +x scripts/monitor_import.sh
```

---

## FIXES NEEDED BEFORE BULK IMPORT

### Fix 1: Update bulk_import.sh to Skip Non-Sacramento Runs

**File:** `scripts/bulk_import.sh`

**Change line 85-88 from:**
```bash
NEW_RUN_IDS=$(psql -t -A -c \
    "SELECT id FROM runmap.runs_raw r
     WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_32610 rb WHERE rb.run_id = r.id)
     LIMIT $SUCCESS")
```

**To:**
```bash
NEW_RUN_IDS=$(psql -t -A -c \
    "SELECT id FROM runmap.runs_raw r
     WHERE NOT EXISTS (SELECT 1 FROM runmap.runs_buffered_32610 rb WHERE rb.run_id = r.id)
     AND r.location = 'sacramento'
     LIMIT $SUCCESS")
```

**Reasoning:** Only process Sacramento runs for coverage. Portland runs should be imported but not buffered.

---

## Import Process (AFTER TESTS PASS)

### Step 1: Create Backup
```bash
ssh -p 2222 mark@192.168.68.25 "pg_dump -U runmap_user runmap | gzip > /home/mark/backups/runmap_before_bulk_$(date +%Y%m%d_%H%M%S).sql.gz"
```

### Step 2: Copy All GPX Files to Mac
```bash
# Create import directory
mkdir -p ~/Development/GIS/runs-cdm/data/bulk-import-portland

# Copy all ~650 Portland runs
# (adjust path to wherever your Portland GPX files are)
cp ~/path/to/portland_gpx_files/*.gpx ~/Development/GIS/runs-cdm/data/bulk-import-portland/

# Count files
ls -1 ~/Development/GIS/runs-cdm/data/bulk-import-portland/*.gpx | wc -l
```

### Step 3: Start Import (in tmux/screen)
```bash
# Start monitoring in one terminal
cd ~/Development/GIS/runs-cdm
./scripts/monitor_import.sh

# In another terminal, start import
cd ~/Development/GIS/runs-cdm
time ./scripts/bulk_import.sh ./data/bulk-import-portland/
```

### Step 4: Monitor Progress
- Import progress logged to terminal
- Monitor script shows real-time stats
- Estimated completion: ~2.5 hours

### Step 5: Post-Import Verification
```bash
# Check final counts
psql -c "SELECT location, COUNT(*) FROM runmap.runs_raw GROUP BY location;"

# Verify only Sacramento runs were buffered
psql -c "SELECT COUNT(*) FROM runmap.runs_buffered_32610;"  # Should still be 17

# Check database size
psql -c "SELECT pg_size_pretty(pg_database_size('runmap'));"

# Verify coverage only shows Sacramento
psql -c "SELECT * FROM runmap.coverage_stats_blocks;"
```

---

## Rollback Plan (If Something Goes Wrong)

### Option 1: Delete Imported Runs (Selective)
```bash
# Delete all Portland runs
psql -c "DELETE FROM runmap.runs_raw WHERE location = 'portland';"
```

### Option 2: Restore from Backup (Nuclear)
```bash
# On Ubuntu server
ssh -p 2222 mark@192.168.68.25

# Drop and recreate database
dropdb -U runmap_user runmap
createdb -U runmap_user runmap

# Restore backup
gunzip -c /home/mark/backups/runmap_before_bulk_*.sql.gz | psql -U runmap_user runmap
```

---

## Success Criteria

After import completes successfully:

- ✅ ~667 total runs in database (17 Sacramento + 650 Portland)
- ✅ 17 runs with buffers (Sacramento only)
- ✅ 8 walks unchanged
- ✅ Coverage stats show only Sacramento data
- ✅ Database size ~780 MB
- ✅ No errors in import log
- ✅ Map still displays correctly (Sacramento coverage unchanged)

---

## Potential Issues & Solutions

| Issue | Symptom | Solution |
|-------|---------|----------|
| Out of disk space | Import fails partway | Free up space, resume from failed file |
| Memory exhausted | Server becomes unresponsive | Restart PostgreSQL, reduce batch size |
| Network timeout | Connection drops | Resume import, duplicates will be skipped |
| Wrong location tagged | All runs tagged as 'other' | Check GPS coordinates in GPX files |
| Coverage corrupted | Portland streets appear | Restore backup, fix location filter |

---

## Timeline

- **Tests:** 30 minutes
- **Fixes:** 15 minutes
- **Backup:** 5 minutes
- **Import:** 2-3 hours
- **Verification:** 15 minutes
- **Total:** ~3-4 hours

---

## Next Steps

1. ✅ Fix bulk_import.sh location filter (see Fix 1 above)
2. ✅ Run Test 1 (single Portland run)
3. ✅ Run Test 2 (5 Portland runs)
4. ✅ Run Test 3 (backup database)
5. ✅ Start full import if all tests pass
6. ✅ Monitor progress
7. ✅ Verify results
