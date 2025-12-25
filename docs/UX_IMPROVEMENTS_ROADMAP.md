# UX Improvements Roadmap

**Decision Date:** October 19, 2025
**Status:** Planned

## Overview

This document outlines the planned UX improvements for the RunMap web interface. These improvements focus on visual polish, usability, and interactivity before tackling complex routing features.

## Prioritized Roadmap

### Phase 1: Base Map Choices
**Priority:** 1 (First)
**Effort:** Low
**Impact:** High

**Rationale:**
- Sets the visual foundation for all other improvements
- Affects color contrast decisions
- Quick win - relatively easy to implement
- Different users prefer different map styles

**Implementation:**
- Add base map picker to web UI
- Support multiple tile providers (OpenStreetMap, Satellite, Terrain, etc.)
- Save user preference to localStorage
- Test with different PMTiles overlay combinations

**Acceptance Criteria:**
- [ ] User can switch between 3+ base map styles
- [ ] Selection persists across sessions
- [ ] Works on mobile and desktop
- [ ] All coverage layers visible on each base map

---

### Phase 2: Improve Colors for Better UX
**Priority:** 2 (Second)
**Effort:** Medium
**Impact:** High

**Rationale:**
- Need base maps in place to test contrast
- Better colors improve readability and motivation
- Informs which layers users want to toggle
- Makes legend/modal clearer

**Implementation:**
- Test current colors (grey, purple, green, red) against each base map
- Optimize contrast ratios for accessibility
- Consider colorblind-friendly palette
- Add opacity controls for overlapping layers
- Improve street stroke width for mobile visibility

**Current Colors:**
- **Incomplete blocks:** Grey
- **Complete blocks:** Green
- **Runs:** Red
- **Streets (partial):** Purple (deprecated - now using blocks)

**Potential Improvements:**
- Higher contrast for incomplete blocks
- Brighter green for complete blocks (motivational)
- Adjustable opacity for runs layer
- Different colors per base map option

**Acceptance Criteria:**
- [ ] All layers meet WCAG AA contrast requirements
- [ ] Colors tested on all base map options
- [ ] Colorblind-friendly (test with simulator)
- [ ] Mobile visibility improved (thicker strokes if needed)

---

### Phase 3: Toggle Layers On/Off
**Priority:** 3 (Third)
**Effort:** Medium
**Impact:** Medium-High

**Rationale:**
- Reduces visual clutter
- Enables users to focus on specific data
- Natural progression after improving appearance
- Allows comparing base maps with different layer combinations

**Implementation:**
- Add layer controls to web UI (checkbox list or toggle switches)
- Layers to control:
  - Complete blocks (green)
  - Incomplete blocks (grey)
  - All runs (red lines)
  - Individual runs (if implemented)
- Save toggle state to localStorage
- Smooth transitions when toggling

**Acceptance Criteria:**
- [ ] Users can show/hide each layer independently
- [ ] Toggle state persists across sessions
- [ ] Smooth fade in/out transitions
- [ ] Works on mobile (touch-friendly controls)
- [ ] At least one layer always visible (prevent blank map)

---

### Phase 4: Improve Legend/Layer Modal (Mobile Focus)
**Priority:** 4 (Fourth)
**Effort:** Medium
**Impact:** Medium

**Rationale:**
- Consolidates all controls (base maps, layer toggles, legend)
- Benefits from all previous improvements being complete
- Mobile UX is currently lacking
- Cleaner interface once colors and toggles are settled

**Current Issues:**
- Legend may not be mobile-optimized
- No centralized controls
- Layer info scattered

**Implementation:**
- Design unified control panel/modal
- Include:
  - Base map picker
  - Layer toggles
  - Color legend
  - Coverage statistics
- Mobile-first design (drawer or bottom sheet)
- Desktop: sidebar or collapsible panel

**Acceptance Criteria:**
- [ ] Single control panel for all map settings
- [ ] Mobile-friendly (easy to tap, not covering map)
- [ ] Shows current coverage stats
- [ ] Color legend matches actual layer colors
- [ ] Accessible (keyboard navigation, screen reader support)

---

## Future Enhancements (Deferred)

### Phase 5: Host PMTiles on Cloudflare R2
**Priority:** 5 (After Phase 4)
**Effort:** Low-Medium
**Impact:** Medium

**Rationale:**
- Can be done after UX improvements are complete
- Cloudflare R2 provides fast, global CDN for PMTiles
- Reduces load on your home server
- Better performance for remote access
- No egress fees (unlike S3)

**Benefits:**
- Faster tile loading from anywhere
- Offload bandwidth from home server
- Better caching with Cloudflare CDN
- Production-ready hosting

**Implementation:**
- Create Cloudflare R2 bucket
- Upload PMTiles files to R2
- Configure public access or custom domain
- Update web app to fetch tiles from R2 URL
- Set up sync script to push new tiles after generation

**Acceptance Criteria:**
- [ ] PMTiles served from Cloudflare R2
- [ ] Tiles load faster than self-hosted
- [ ] Automatic sync after tile regeneration
- [ ] Custom domain (optional): tiles.runmap.chouinard.me
- [ ] Cache headers properly configured

**Cost:** ~$0.015/GB storage + $0 egress (very cheap for personal use)

---

### Phase 6: Creating Routes to Increase Coverage with Minimal Duplication (pgRouting)
**Priority:** 6 (Long-term/Optional)
**Effort:** Very High
**Impact:** High (but complex)

**Rationale for deferring:**
- Most complex feature - requires significant infrastructure
- Needs pgRouting PostgreSQL extension
- Requires OSM network topology setup
- Algorithm design for optimal gap-filling routes
- Benefits from having good visualization already in place
- Standalone feature - doesn't block other improvements

**When to revisit:**
- After completing Phases 1-5
- When you want a complex technical challenge
- When basic UX is polished and working well

**Potential Implementation (future):**
- Install pgRouting extension
- Build routable network from OSM data
- Identify incomplete blocks/streets
- Generate optimal routes connecting gaps
- Display suggested routes on map
- Export routes to GPX for WorkOutDoors

**Acceptance Criteria (TBD):**
- [ ] Algorithm finds optimal routes to fill coverage gaps
- [ ] Minimizes duplicate coverage
- [ ] Respects user preferences (distance, difficulty)
- [ ] Exports to GPX for immediate use
- [ ] Updates as coverage changes

---

## Success Metrics

**Overall Goals:**
1. Improved usability on mobile devices
2. Better visual clarity of coverage data
3. Flexible viewing options (base maps, layer toggles)
4. Motivational design (celebrating progress)

**Measurements:**
- Mobile usability (subjective - easier to use?)
- Layer visibility (can you see everything clearly?)
- Control accessibility (can you change settings easily?)
- Personal satisfaction (is it more enjoyable to use?)

---

## Technical Notes

**Technologies:**
- MapLibre GL JS (current map library)
- PMTiles (current tile format)
- React (current frontend framework)
- LocalStorage (preference persistence)

**No Database Changes Required:**
- All improvements are frontend-only
- Uses existing PMTiles and API endpoints
- Minimal backend changes (if any)

**Development Environment:**
- Test on multiple devices (phone, tablet, desktop)
- Test on different browsers (Chrome, Safari, Firefox)
- Test with slow network connections
- Test with different screen sizes

---

## Timeline

**Estimated Effort:**
- Phase 1 (Base maps): 1-2 days
- Phase 2 (Colors): 2-3 days
- Phase 3 (Toggle layers): 2-3 days
- Phase 4 (Legend/modal): 3-4 days

**Total:** ~2 weeks of focused work (flexible based on your schedule)

**Note:** This is frontend polish work. Can be done incrementally as you have time.

---

## References

- [MapLibre GL JS Documentation](https://maplibre.org/maplibre-gl-js-docs/api/)
- [PMTiles Specification](https://github.com/protomaps/PMTiles)
- [WCAG Contrast Guidelines](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html)
- [Colorblind-Friendly Palettes](https://colorbrewer2.org/)

---

## Change Log

- **2025-10-19:** Initial roadmap created
  - Prioritized base maps → colors → toggles → legend
  - Deferred route planning to future phase
  - Decision: Focus on UX polish before complex features
