# Critique: Coverage Calculation and Display Issues

## The Real Issues

**1. The geometric precision "errors" aren't rounding - they're real problems:**
- Streets showing 100.40% coverage have `covered_length_m > total_length_m`
- This means your intersection/buffer operation is claiming to cover MORE road than actually exists
- If buffers are creating 0.40% extra coverage per street, this compounds across thousands of streets into significant overestimation

**2. The visibility problem is correct but the cause matters:**
- Yes, streets with 0.01m coverage disappear from the grey layer
- But WHY do they have 0.01m coverage? If your run didn't actually touch them, this is false positive coverage

## Why the Proposed Solutions Are Wrong

**Option 1 (5% threshold):** Hides streets that show trace coverage. If that coverage is spurious (from buffer overshoot), you're masking bad data. If it's real, you're misrepresenting completion status.

**Option 2 (partial coverage layer):** Reasonable for UX, but doesn't address whether the partial coverage values are accurate.

**Option 3 (95% threshold):** Same problem - you're working around potentially bad measurements instead of validating them.

## What You Should Actually Check

1. **Are those >100% streets actually fully covered?** Look at a few in QGIS with the actual GPX track overlaid. Is the geometry accurate?

2. **Are the <100% streets legitimately partial?** Or are these streets that got clipped by your buffer but weren't actually run?

3. **What's causing the overshoot?** Is `ST_Buffer` creating too large a corridor? Is `ST_Intersection` double-counting overlapping segments?

## The Right Approach

First **validate** your coverage calculations are geometrically sound (no false positives/negatives), THEN decide on display thresholds. A 95% threshold might be reasonable for "considering it done," but only if the underlying 100.00-100.40% values represent actual full coverage, not measurement artifacts.

The advice treats symptoms. You need to diagnose whether your incremental coverage calculation is geometrically accurate first.
