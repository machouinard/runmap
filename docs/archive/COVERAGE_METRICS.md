# Understanding Coverage Metrics

RunMap tracks **two different coverage metrics**. It's important to understand the difference:

## Metric 1: Block Completion Percentage (Primary Metric)

**What it measures:** Percentage of blocks that are ≥90% complete

**Formula:**
```
block_completion_pct = (complete_blocks / total_blocks) × 100
```

**Example:**
- Total blocks: 2,597
- Complete blocks (≥90%): 624
- **Block completion: 24.0%**

**This is the meaningful metric** - it tells you what percentage of the city you've actually run.

**Displayed on map:** "24.0% Complete (624/2597 blocks ≥90%)"

---

## Metric 2: Distance Coverage Percentage (Secondary)

**What it measures:** Total distance covered across all blocks (includes partial coverage)

**Formula:**
```
overall_coverage_pct = (sum of covered_length_m / sum of total_length_m) × 100
```

**Example:**
- Total street distance: 59.2 km
- Distance covered: 41.3 km
- **Distance coverage: 69.7%**

**Why it's misleading:**
- Crossing a street perpendicularly adds distance
- Running halfway down a block counts
- You can have 70% distance coverage but only 24% blocks complete

**Not displayed on frontend** (confusing metric)

---

## Why Block Completion is Better

### Distance Coverage Problems

**Scenario:** You run a grid pattern, crossing streets perpendicularly

- P Street (1,800m long, split into 39 blocks)
- You cross P Street 20 times perpendicularly
- Each crossing touches ~50m of the street

**Distance coverage calculation:**
- 20 crossings × 50m = 1,000m covered
- 1,000m / 1,800m = **55.6% distance coverage**

**Block completion calculation:**
- 20 blocks crossed at 5-10% each = 0 complete blocks
- 0 complete / 39 total = **0% block completion**

**Which is accurate?** Block completion! You haven't actually "run" P Street, you just crossed it.

---

### Block Completion Accurately Reflects Running

**With 90% threshold:**

| Scenario | Distance Coverage | Block Completion | Accurate? |
|----------|------------------|------------------|-----------|
| Ran entire block | ~95-100% | 100% ✅ | Both work |
| Ran most of block | ~85% | 85% (incomplete) | Block is better |
| Crossed perpendicularly | ~10% | 10% (incomplete) | Block is better |
| Ran on sidewalk (15m from road) | Varies by buffer | Depends on buffer | Both affected |

**Block completion treats blocks as binary:** Either you ran it (≥90%) or you didn't (<90%).

---

## Current Stats Breakdown

Check your current stats:

```sql
PGPASSWORD=fucker psql -h 192.168.68.25 -U runmap_user -d runmap << 'EOF'
SELECT
  total_blocks,
  complete_blocks,
  incomplete_blocks,
  ROUND(block_completion_pct::numeric, 1) as block_pct,
  ROUND(overall_coverage_pct::numeric, 1) as distance_pct
FROM runmap.coverage_stats_blocks;
EOF
```

**Example output:**
```
 total_blocks | complete_blocks | incomplete_blocks | block_pct | distance_pct
--------------+-----------------+-------------------+-----------+--------------
         2597 |             624 |               313 |      24.0 |         69.7
```

**Interpretation:**
- **24.0% block completion** = You've fully run 624 blocks (the real metric)
- **69.7% distance coverage** = You've touched 69.7% of total street distance (inflated by crossings)

---

## API Response

The API returns both metrics:

```json
{
  "coverage": {
    "total_blocks": 2597,
    "complete_blocks": 624,
    "incomplete_blocks": 313,
    "block_completion_pct": 24.0,      // ← Use this (blocks ≥90%)
    "coverage_pct": 69.7,              // ← Ignore (misleading distance metric)
    "completion_threshold_pct": 90
  }
}
```

**Frontend now displays:** `block_completion_pct` only

---

## Adjusting the Threshold

The **completion threshold** (default 90%) determines when a block counts as "complete":

```sql
-- Change threshold to 85% (more lenient)
UPDATE runmap.settings SET value = '85'::jsonb
WHERE key = 'completion_threshold_pct';

REFRESH MATERIALIZED VIEW runmap.coverage_stats_blocks;
```

**Effect on metrics:**

| Threshold | Complete Blocks | Block Completion % | Distance Coverage % |
|-----------|----------------|-------------------|-------------------|
| 95% | ~500 | ~19% | 69.7% (unchanged) |
| 90% | ~624 | ~24% | 69.7% (unchanged) |
| 85% | ~700 | ~27% | 69.7% (unchanged) |

**Note:** Distance coverage stays the same - only block completion changes with threshold.

---

## Which Metric Should I Use?

**For tracking progress:** **Block Completion %**
- "I've run 24% of Sacramento blocks"
- Accurate measure of what you've actually run
- Not inflated by perpendicular crossings

**For planning routes:** Look at individual block coverage percentages
```sql
-- Find streets that are partially done
SELECT name, highway,
  COUNT(*) FILTER (WHERE bc.coverage_pct >= 50 AND bc.coverage_pct < 90) as almost_done
FROM runmap.streets_blocks_32610 b
LEFT JOIN runmap.block_coverage_32610 bc USING (block_id)
WHERE name IS NOT NULL
GROUP BY name, highway
HAVING COUNT(*) FILTER (WHERE bc.coverage_pct >= 50 AND bc.coverage_pct < 90) > 0
ORDER BY almost_done DESC;
```

---

## See Also

- [Usage Guide](USAGE_GUIDE.md) - Day-to-day operations
- [Block Coverage Migration](BLOCK_PERCENTAGE_MIGRATION.md) - How the system works
- [CLAUDE.md](../CLAUDE.md) - Full technical reference
