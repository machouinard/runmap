# Database Audit Findings

**Date:** 2025-11-18
**Purpose:** Document discrepancies between production database and documentation

---

## Known Issue: Manual Objects Not in Schema Files

### ✅ **FOUND: cleanup_coverage_on_delete trigger**

**Status:** Exists in production, NOT in schema files

**What it does:**
- Trigger: `trigger_cleanup_coverage_on_delete`
- Function: `cleanup_coverage_on_delete()`
- Purpose: Efficiently recalculates coverage when runs are deleted
- Only processes affected segments (not full rebuild)

**Action taken:**
- ✅ Added to documentation (CLAUDE.md, db/README.md, CLEANUP_GUIDE.md)
- ✅ Preserved in cleanup script (won't be deleted)
- ⚠️ Should be exported to a schema file for git tracking

---

## Potential Other Issues to Check

### 🔍 **Functions That Might Exist But Aren't Documented**

Run the audit script and look for functions marked `⚠️ NOT IN DOCS`:

```bash
bash scripts/audit_production_database.sh | grep "NOT IN DOCS"
```

**Possible undocumented functions:**
- Helper functions for coverage calculations
- Old migration/debugging functions
- Custom utility functions

### 🔍 **Tables That Might Exist From Old Systems**

**Should NOT exist (but might):**
- `runs_buffered_32610` - Old buffer table (replaced by `runs_buffered_subdiv`)
- `block_coverage_32610` - Block-percentage system (never deployed)
- `block_run_coverage` - Junction table (never deployed)
- `streets_chunks_32610` - Very old chunk system
- `chunk_coverage_32610` - Very old chunk system
- `street_coverage_32610` - Very old street-level system

**If these exist:** They're safe to drop (run cleanup script)

### 🔍 **Views That Might Exist From Old Systems**

**Should NOT exist (but might):**
- `streets_unrun`, `streets_partial`, `streets_complete` - Old street views
- `chunks_incomplete`, `chunks_complete` - Old chunk views
- `coverage_stats` - Old matview (replaced by `coverage_stats_blocks`)

**If these exist:** They're safe to drop (run cleanup script)

### 🔍 **Triggers That Might Be Undocumented**

**Expected triggers:**
- ✅ `trigger_auto_process_run_segments`
- ✅ `trigger_set_location_before_insert`
- ✅ `trigger_cleanup_coverage_on_delete` (found manually)
- ✅ `RI_ConstraintTrigger_*` (4 triggers for foreign keys - normal)

**If you see others:** Document them!

---

## Documentation Errors I May Have Made

### ❌ **Error 1: cleanup_coverage_on_delete**

**What I said:** "Cleanup triggers are NOT currently implemented"
**Reality:** `trigger_cleanup_coverage_on_delete` DOES exist
**Fixed:** ✅ Corrected in all docs

### ❓ **Potential Error 2: Missing helper functions?**

The cleanup trigger is sophisticated - it might rely on helper functions I don't know about.

**Check for:**
- Functions called by `cleanup_coverage_on_delete()`
- Functions called by `auto_process_new_run_segments()`
- Utility functions for geometry operations

### ❓ **Potential Error 3: Undocumented settings?**

**Documented settings:**
- `buffer_distance_m`
- `tiles_version`
- `completion_threshold_pct`

**Check if there are others:**
```sql
SELECT key, value FROM runmap.settings ORDER BY key;
```

### ❓ **Potential Error 4: Missing indexes?**

I documented some indexes but might have missed others.

**Check:**
```sql
SELECT
  tablename,
  indexname,
  indexdef
FROM pg_indexes
WHERE schemaname = 'runmap'
ORDER BY tablename, indexname;
```

---

## How to Verify Documentation Accuracy

### Step 1: Run the Audit Script

```bash
bash scripts/audit_production_database.sh > audit_results.txt
```

### Step 2: Review Undocumented Objects

Look for lines with `⚠️ NOT IN DOCS`:

```bash
grep "NOT IN DOCS" audit_results.txt
```

**For each undocumented object, determine:**
1. Is it part of the current system? → Add to docs
2. Is it from an old system? → Add to cleanup script
3. Is it a custom utility? → Document or remove

### Step 3: Check for Missing Expected Objects

Look for lines with `❌ MISSING`:

```bash
grep "MISSING" audit_results.txt
```

**If expected objects are missing:**
- Schema files may be incomplete
- Production database may not match docs
- Need to investigate and resolve

### Step 4: Export Manual Objects to Schema Files

For any manually-created objects (like cleanup trigger):

```sql
-- Export function definition
SELECT pg_get_functiondef(oid)
FROM pg_proc
WHERE proname = 'cleanup_coverage_on_delete';

-- Export trigger definition
SELECT pg_get_triggerdef(oid)
FROM pg_trigger
WHERE tgname = 'trigger_cleanup_coverage_on_delete';
```

Save these to a schema file: `db/05_cleanup_trigger.sql` (or similar)

---

## Questions to Answer

### Q1: Are there other manually-created triggers?

**Run:**
```bash
bash scripts/audit_production_database.sh | grep -A 20 "ALL TRIGGERS"
```

**Expected:** 3 custom triggers + 4 FK triggers = 7 total
**If different:** Investigate extras

### Q2: Are there helper functions I missed?

**Run:**
```bash
bash scripts/audit_production_database.sh | grep -A 50 "ALL FUNCTIONS"
```

**Expected functions (current system):**
- buffer_one_run_subdiv
- apply_run_to_segments
- auto_process_new_run_segments
- cleanup_coverage_on_delete
- detect_location
- get_buffer_distance
- get_completion_threshold (maybe?)

**Any others:** Document or investigate

### Q3: Do old system objects still exist?

**Run:**
```bash
bash scripts/audit_production_database.sh | grep -A 30 "Old system objects"
```

**Expected:** Empty (all cleaned up)
**If not empty:** Run cleanup script

### Q4: Is the segment-visited system complete?

**Run:**
```bash
bash scripts/audit_production_database.sh | grep -A 20 "VERIFICATION"
```

**Expected:** All ✅ EXISTS
**Any ❌ MISSING:** Critical issue!

---

## Action Items After Audit

**Based on audit results:**

1. **Document any undocumented objects**
   - Add to CLAUDE.md
   - Add to db/README.md
   - Note why they exist

2. **Export manually-created objects to schema files**
   - Create `db/05_cleanup_trigger.sql` for cleanup trigger
   - Commit to git for version control

3. **Update cleanup script**
   - Add any newly-discovered obsolete objects
   - Protect any newly-discovered current objects

4. **Verify documentation accuracy**
   - Update CLAUDE.md with complete function list
   - Update db/README.md with complete trigger list

5. **Run cleanup script** (after backup!)
   - Remove obsolete objects found in audit

---

## Commit Tracking

**What needs to be added to git:**
- [ ] Export cleanup trigger to schema file
- [ ] Any other manually-created objects found
- [ ] Updated documentation with complete object lists
- [ ] Audit results for future reference

---

## Related Files

- [scripts/audit_production_database.sh](../scripts/audit_production_database.sh) - Audit script
- [db/cleanup_obsolete_objects.sql](cleanup_obsolete_objects.sql) - Cleanup script
- [db/CLEANUP_GUIDE.md](CLEANUP_GUIDE.md) - Cleanup instructions
- [CLAUDE.md](../CLAUDE.md) - Main documentation
- [db/README.md](README.md) - Database documentation
