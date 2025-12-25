# Archived Documentation

This directory contains historical documentation from the RunMap v3 development process (October 2025).

These documents are kept for reference but are **not part of current production**.

## What's Here

### Migration History
- **BLOCK_PERCENTAGE_MIGRATION.md** - How we moved from chunks to blocks (Oct 16)
- **BLOCK_PERCENTAGE_PROPOSAL.md** - Why blocks instead of chunks
- **INCREMENTAL_MIGRATION.md** - Migration from full recalculation to incremental
- **LOCATION_TRACKING.md** - How we added Sacramento/Portland detection (Oct 19)
- **SESSION_2025-10-19.md** - Workout hash deduplication implementation

### Problems We Solved
- **SCALABILITY_ANALYSIS.md** - Memory issues analysis (112GB → 3GB)
- **RESOURCE_IMPACT_ANALYSIS.md** - Why old system couldn't scale
- **CHUNK_COVERAGE_SYSTEM.md** - Old chunk system documentation
- **CHUNK_SIZE_ANALYSIS.md** - Why 500m chunks didn't work
- **COVERAGE_GRANULARITY_OPTIONS.md** - Options we considered
- **COVERAGE_METRICS.md** - Metric calculations explored

### Planning & Implementation Docs (Completed)
- **BULK_IMPORT_ASSESSMENT.md** - Bulk import planning
- **IMPLEMENTATION_PLAN_CHUNK_COVERAGE.md** - Old chunk implementation plan
- **DEPLOYMENT_CHECKLIST.md** - One-time deployment checklist (completed)
- **DEPLOYMENT.md** - Deployment guide (completed)
- **FEATURE_ROADMAP.md** - Original feature planning

## Why Archived?

These docs describe:
- **Old systems** that have been replaced (chunks → blocks)
- **Completed migrations** (incremental coverage, location tracking)
- **One-time deployments** (server setup complete)
- **Historical decisions** (valuable for understanding "why" but not needed daily)

## Current Production Documentation

See parent `docs/` directory for active docs:

**Daily Use:**
- **USAGE_GUIDE.md** - How to upload runs, view stats, change settings
- **SCRIPTS_REFERENCE.md** - All production scripts explained

**Technical Reference:**
- **ARCHITECTURE.md** - Complete system design (blocks, incremental, triggers)
- **IOS_SHORTCUT_SETUP.md** - How to set up iOS shortcut

**Status:**
- **../info/PROJECT_STATUS.md** - Current production status
- **../CLAUDE.md** - AI assistance reference

## When to Reference These

**Good reasons to look here:**
- Understanding why we chose blocks over chunks
- Learning how incremental processing solved memory issues
- Seeing the evolution from old system to current
- Understanding migration decisions
- Historical context for "why did we do it this way?"

**Don't use these for:**
- Current system operations (use USAGE_GUIDE.md)
- Script usage (use SCRIPTS_REFERENCE.md)
- Architecture reference (use ARCHITECTURE.md)

---

**Archived:** October 19, 2025
**Current System:** Block-based incremental coverage with automatic triggers
