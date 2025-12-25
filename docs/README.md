# RunMap Documentation Index

**Master index of all project documentation**

This document serves as the central navigation hub for all RunMap documentation. Documents are organized by purpose and use case.

---

## Quick Start

**New to the project?** Start here:

1. **[CLAUDE.md](../CLAUDE.md)** - Project overview, architecture, database schema, common commands
2. **[USAGE_GUIDE.md](USAGE_GUIDE.md)** - Day-to-day operations (uploading runs, viewing stats, changing settings)

---

## Architecture & Design

### Core System Design

- **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** ⭐ **Current Production System** (migrated 2025-10-20)
  - Segment-visited coverage architecture
  - Binary visited flags instead of geometry unions
  - Constant-time performance (~0.4s/run, independent of total runs)
  - 67x speedup over previous approaches
  - Migration summary and performance results

### Coverage Processing Algorithm

- **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** - How the current system works
  - `buffer_one_run_subdiv()` - Buffer and subdivide runs
  - `apply_run_to_segments()` - Mark segments as visited
  - Why binary flags are faster than geometry unions
  - Performance characteristics and benchmarks

### Data Processing

- **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** - Incremental segment-visited processing
  - How runs are processed one at a time
  - Segment-based coverage tracking
  - Constant-time performance (O(segments touched), independent of run count)

---

## Operations & Workflow

### Day-to-Day Usage

- **[USAGE_GUIDE.md](USAGE_GUIDE.md)** - Daily operations guide
  - How to upload runs (API, bulk import)
  - Viewing coverage statistics
  - Changing settings (buffer distance, thresholds)
  - Accessing the web interface

### Development & Testing

- **[TESTING_WORKFLOW.md](TESTING_WORKFLOW.md)** - Fast iteration for development/testing
  - Separating GPX import from coverage processing
  - How to reset coverage without re-importing
  - Testing coverage algorithm changes
  - Time-saving workflow (10-15 min savings per iteration)
  - Scripts: `bulk_import_no_process.sh`, `process_all_runs.sh`, `reset_coverage.sh`

### Migration & Setup

- **[MIGRATION_UBUNTU_TO_MAC.md](MIGRATION_UBUNTU_TO_MAC.md)** - Dev environment setup on Mac
  - Database setup (PostgreSQL + PostGIS)
  - Python dependencies
  - Frontend development (Vite, React)
  - SSH key configuration for deployment
  - Local tile serving with PMTiles

---

## Performance & Scalability

- **[SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md)** - System scalability analysis
  - Memory usage patterns
  - Database size projections
  - Performance bottlenecks
  - Handling large datasets (thousands of runs)

- **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** - Specific optimization work
  - Bulk import slowdown (geometry accumulation)
  - Diagnostic logging and profiling
  - Before/after performance metrics
  - PostGIS best practices learned

- **[POSTGIS_PERFORMANCE_REVIEW.md](POSTGIS_PERFORMANCE_REVIEW.md)** - Review of PostGIS optimization techniques
  - Evaluation of POSTGIS_PERFORMANCE_NOTES.md recommendations
  - Which optimizations apply to our architecture
  - What NOT to do (and why)
  - Testing plan for additional optimizations
  - Context for external reviewers/colleagues

- **[APPLICABLE_POSTGIS_OPTIMIZATIONS.md](APPLICABLE_POSTGIS_OPTIMIZATIONS.md)** ⭐ **Actionable optimization guide**
  - Techniques to implement now (indexes, session settings, ANALYZE)
  - Techniques to test (cheaper buffers, ST_Subdivide)
  - Techniques to avoid (additive coverage, geometry accumulation)
  - Why external optimization guides don't match our architecture
  - Implementation priority and testing methodology

- **[ST_SUBDIVIDE_INTEGRATION.md](ST_SUBDIVIDE_INTEGRATION.md)** ⭐ **Next optimization to test**
  - Why external additive coverage approach is bugged (double-counting)
  - How to integrate ST_Subdivide into our junction table architecture
  - Complete benchmark protocol adapted to our system
  - Performance tracking infrastructure (performance_log table)
  - Migration analysis (verdict: don't migrate, ST_Subdivide works as-is)

---

## Reference Documentation

### Project Configuration

- **[CLAUDE.md](../CLAUDE.md)** - Main project documentation
  - Project overview and key innovations
  - Architecture summary
  - Complete database schema
  - Common commands (database, processing, tiles)
  - File locations and conventions
  - Code conventions (SQL, Shell, Python, Frontend)
  - Diagnostics and troubleshooting

### Database Schema

Schema documentation is split across:

- **[CLAUDE.md](../CLAUDE.md)** - Complete schema reference
  - All tables with field descriptions
  - Views (unrun, partial, complete blocks)
  - Functions (buffer_one_run, apply_run_to_block_coverage, detect_location)
  - Coordinate systems (4326, 32610, 3857)

- **[BLOCK_PERCENTAGE_MIGRATION.md](BLOCK_PERCENTAGE_MIGRATION.md)** - Block-specific schema
  - `streets_blocks_32610` structure
  - `block_coverage_32610` structure
  - `block_run_coverage` junction table

- **[PERFORMANCE_OPTIMIZATION.md](PERFORMANCE_OPTIMIZATION.md)** - Schema changes for performance
  - Why `covered_geom` is NULL in `block_coverage_32610`
  - Junction table rationale

---

## Documentation by Use Case

### "I want to upload runs and view coverage"
→ **[USAGE_GUIDE.md](USAGE_GUIDE.md)**

### "I want to understand how coverage is calculated"
→ **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** (current system)
→ **[archive/PERFORMANCE_OPTIMIZATION.md](archive/PERFORMANCE_OPTIMIZATION.md)** (older system details - archived)

### "I want to test coverage algorithm changes"
→ **[TESTING_WORKFLOW.md](TESTING_WORKFLOW.md)**

### "I want to set up a development environment"
→ **[MIGRATION_UBUNTU_TO_MAC.md](MIGRATION_UBUNTU_TO_MAC.md)**

### "I want to understand the database schema"
→ **[CLAUDE.md](../CLAUDE.md)** (complete reference)
→ **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** (segment-visited tables)

### "I want to know why the system is designed this way"
→ **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** (segment-visited approach)
→ **[archive/PERFORMANCE_OPTIMIZATION.md](archive/PERFORMANCE_OPTIMIZATION.md)** (why unions failed)
→ **[SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md)** (memory/performance analysis)

### "I'm experiencing performance issues"
→ **[SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)** (current system performance)
→ **[SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md)** (capacity planning)
→ **[CLAUDE.md](../CLAUDE.md)** (diagnostics section)

---

## Key Concepts

### Coverage Calculation (Segment-Visited System)

**How it works:**

1. **Buffering** (`buffer_one_run_subdiv`): Create 10m buffer around GPS track, then subdivide into smaller polygons
2. **Intersection**: Find 5m street segments that intersect the subdivided buffer
3. **Mark visited** (`apply_run_to_segments`):
   - Set `visited = TRUE` for intersecting segments (one-time, idempotent)
   - Update aggregate coverage by counting visited segments
   - **No geometry unions** - just boolean flags (constant time)
   - Calculate coverage percentage: `(visited_segments × 5m) / total_block_length`

**Detailed explanation:** [SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)

### Block-Based Architecture

Streets are grouped into **blocks** (connected segments split at intersections). Blocks are then pre-segmented into ~5m pieces.

**Benefits:**
- More granular coverage visualization
- Constant-time updates using binary visited flags
- No geometry accumulation or union operations

**Detailed explanation:** [SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)

### Incremental Processing

Each new run only marks new segments as visited - no geometry recalculation needed.

**Performance:** Constant time (~0.4s/run) regardless of total run count

**Memory usage:** O(segments touched) - independent of total runs in database

**Detailed explanation:** [SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md)

### Location Detection

Runs are automatically classified as "sacramento", "portland", or "other" based on GPS coordinates. Only Sacramento runs contribute to coverage.

**Implementation:** `detect_location()` function in database

**Reference:** [CLAUDE.md](../CLAUDE.md)

---

## Scripts Reference

### Import & Processing

- **`scripts/bulk_import.sh`** - Import GPX files AND process coverage
- **`scripts/bulk_import_no_process.sh`** - Import GPX files WITHOUT processing (faster testing)
- **`scripts/process_all_runs.sh`** - Process coverage for unprocessed runs only
- **`scripts/ingest_gpx.sh`** - Import single GPX file
- **`scripts/reset_coverage.sh`** - Clear processing results, keep imported runs

### Tiles & Export

- **`scripts/export_tiles_blocks.sh`** - Export PMTiles for blocks (unrun, partial, complete)
- **`scripts/export_tiles_incremental.sh`** - (Legacy) Export tiles incrementally

### Database

- **`db/01_create_tables.sql`** - Create schema, tables, indexes
- **`db/03_incremental_coverage.sql`** - Coverage functions (buffer_one_run, apply_run_to_block_coverage)

### Deployment

- **`scripts/deploy.sh`** - Deploy frontend and tiles to production server

**Detailed usage:** [USAGE_GUIDE.md](USAGE_GUIDE.md), [TESTING_WORKFLOW.md](TESTING_WORKFLOW.md)

---

## Database Tables Quick Reference

### Activity Storage
- `runs_raw` - GPS tracks for runs (all locations)
- `walks_raw` - GPS tracks for walks (all locations)
- `cycling_raw` - GPS tracks for cycling (all locations)

### Street/Block Data
- `streets_reference` - OSM street network (WGS84)
- `streets_blocks_32610` - Street blocks for coverage tracking (UTM)

### Coverage Processing
- `runs_buffered_32610` - 10m buffers around each run (UTM)
- `block_coverage_32610` - Aggregated coverage per block
- `block_run_coverage` - Junction table (which runs touched which blocks)

### Configuration
- `settings` - System settings (buffer distance, tile version)

**Complete schema:** [CLAUDE.md](../CLAUDE.md)

---

## Document Change Log

### 2025-10-20
- Created **PERFORMANCE_OPTIMIZATION.md** - Geometry accumulation fix
- Created **TESTING_WORKFLOW.md** - Fast iteration workflow
- Created **README.md** (this document) - Master index
- Updated **CLAUDE.md** - Added block_run_coverage table, performance doc references

### Earlier
- **BLOCK_PERCENTAGE_MIGRATION.md** - Block-based coverage architecture
- **BLOCK_PERCENTAGE_PROPOSAL.md** - Original proposal
- **SCALABILITY_ANALYSIS.md** - Memory/performance analysis
- **INCREMENTAL_MIGRATION.md** - Incremental processing system
- **MIGRATION_UBUNTU_TO_MAC.md** - Dev environment setup
- **USAGE_GUIDE.md** - Day-to-day operations

---

## Contributing to Documentation

When adding new documentation:

1. Create the document in `docs/` directory
2. Add entry to this index (README.md) in appropriate section
3. Update related documents with cross-references
4. Update CLAUDE.md if it affects core architecture/schema
5. Add to "Document Change Log" section above

**Cross-referencing:** Use relative links like `[USAGE_GUIDE.md](USAGE_GUIDE.md)` for discoverability.

---

## Archived Documentation

Historical documentation for previous coverage systems:

- **[archive/BLOCK_PERCENTAGE_MIGRATION.md](archive/BLOCK_PERCENTAGE_MIGRATION.md)** - Block-percentage coverage (superseded 2025-10-20)
- **[archive/BLOCK_PERCENTAGE_PROPOSAL.md](archive/BLOCK_PERCENTAGE_PROPOSAL.md)** - Original block-based proposal
- **[archive/INCREMENTAL_MIGRATION.md](archive/INCREMENTAL_MIGRATION.md)** - Early incremental system
- **[archive/PERFORMANCE_OPTIMIZATION.md](archive/PERFORMANCE_OPTIMIZATION.md)** - Junction table approach (superseded by segment-visited)

These documents are kept for historical reference. The current production system is **segment-visited coverage**.

---

## Questions?

- **General project info**: [CLAUDE.md](../CLAUDE.md)
- **How to use**: [USAGE_GUIDE.md](USAGE_GUIDE.md)
- **How it works**: [SEGMENT_VISITED_MIGRATION.md](SEGMENT_VISITED_MIGRATION.md) (current system)
- **Development setup**: [MIGRATION_UBUNTU_TO_MAC.md](MIGRATION_UBUNTU_TO_MAC.md)
