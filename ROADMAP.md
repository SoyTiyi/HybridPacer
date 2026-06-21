# HybridPacer Roadmap

This document tracks what has shipped and what is being considered for future development. Items in "Candidate future work" are **not committed** — they are ideas open for community input and contribution.

---

## ✅ Shipped

### Phase 1 — Foundation
App scaffold, `HyroxPacerApp` singleton, `getApp()` global accessor, GPS + FIT session lifecycle stubs.

### Phase 2 — State Machine & Doubles Mode
Full 6-state FSM (`WARMUP → RUN → ROXZONE_IN → STATION → ROXZONE_OUT → FINISH`), 5-second debounce between transitions, doubles/relay mode with per-athlete time tracking.

### Phase 3 — FIT Recording
7 FitContributor developer fields written at 1 Hz; custom chart metadata in `fitcontributions.xml`; fields surface as charts in Garmin Connect after sync.

### Phase 4 — Predictive Pacing Engine
`PacingEngine.computeDynamicPaceTarget` recalculates target pace on every RUN entry using projected future station time. `computePaceDeltaDeviation` measures live deviation vs. that dynamic target.

### Phase 5 — Imperative Three-Band UI
Fully imperative rendering with `Dc` primitives; per-state screens; high-contrast white background during RUN; green/red pace coloring; 1 Hz refresh timer.

### Phase 6 — Configurable Goal Time
In-app `Menu2` presets (40–180 min, 5-min steps); persisted to `Application.Storage`; loaded with clamp + fallback on startup; gated to WARMUP only.

### Phase 7 — Pause / Resume
START/STOP freezes chronometer and FIT recording; paused time excluded from all accumulators; PAUSED overlay screen; FIT session survives early app exit.

---

## 🔮 Candidate Future Work

These are potential improvements. Not all will be built; community feedback and contributions welcome.

### Device Expansion
- **Priority: High** — Add more popular HYROX-participant devices: Fenix 7 series, Epix (Gen 2), Forerunner 255, Forerunner 745, Venu 3.
- Each new device requires testing screen dimensions and font availability.
- See `manifest.xml` → `<iq:products>` to add entries.

### Named HYROX Stations
- Display the actual station name (SkiErg, Sled Push, Sled Pull, Burpee Broad Jumps, Rowing, Farmers Carry, Sandbag Lunges, Wall Balls) based on the current cycle number.
- Could include per-station personal bests or expected time.

### Connect IQ Settings Integration
- Move goal-time selection to `settings.xml` so it can be configured from the Garmin Connect app on the phone, not just from the watch menu.

### Post-Race Summary Screen
- After FINISH: show per-km split times, per-station times, average running pace, total work vs. rest breakdown.
- May require additional FIT lap message fields.

### Localization (i18n)
- Move all on-watch UI strings to `strings.xml` with language-specific variants.
- Initial candidates: English (default), Spanish, German, French.
- Note: UI strings must remain short to fit watch display widths.

### Pace Alert Vibration
- Haptic feedback when pace delta exceeds a configurable threshold (e.g., 30 s/km behind target).

### Garmin Connect IQ Store Publication
- Code signing review, compatibility matrix testing, Connect IQ Store listing.

---

## 💬 Feedback

Open an issue to vote on any of these items or propose new ones. Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md).
