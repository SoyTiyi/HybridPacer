# Changelog

All notable changes to HybridPacer are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Planned
- Additional device support (Fenix 7, Epix, Forerunner 255)
- Named HYBRID station display (SkiErg, Sled Push, Sled Pull, …)
- Post-race summary screen with per-km splits
- Localization infrastructure (i18n string resources)

---

## [0.7.0] — Phase 7: Pause / Resume & Real-Time Pace Display

### Added
- **Pause / resume** via the START/STOP button during any race state (RUN, TRANSITION, STATION).
- `mIsPaused`, `mPauseStartMs`, `mPausedMs` app-level flags; paused time excluded from all accumulators.
- Dedicated **PAUSED** overlay screen (dark gray background, frozen partial timer, resume hint).
- FIT recording pauses with `Session.stop()` and resumes with `Session.start()` on the same session; `save()` deferred to FINISH to protect the `.fit` file on early exit.
- BACK/LAP blocked while paused — athlete must resume before advancing the FSM.
- **EMA-smoothed real pace** (`mSpeedAvg`, α = 0.25) displayed as the primary RUN metric.
- `GpsSessionManager.getAvgSpeedMs()` getter for the smoothed speed.
- `PacingEngine.computeCurrentPaceSec()` converts smoothed speed to s/km for display.

### Fixed
- Rewrote button handling to use Garmin-native `BehaviorDelegate` callbacks (`onSelect`, `onBack`, `onPreviousPage`, `onNextPage`) instead of overriding `onKey()`, which was silently breaking all routing.
- Removed `onStartSelect()` (does not exist in the SDK — was causing silent no-ops on START).

### Build
- Binary: ~117 KB `.prg` (fr965)

---

## [0.6.0] — Phase 6: Configurable Goal Time

### Added
- **In-app goal-time menu** (`TargetTimeMenu.mc`) using `WatchUi.Menu2` with presets from 40 to 180 minutes in 5-minute steps.
- Menu accessible via **long-press UP** in WARMUP only (changing mid-race would corrupt pacing calculations).
- Goal time **persisted** to `Application.Storage` (key `"target_min"` as minutes).
- `HybridPacerApp.initialize()` loads the persisted value with type-check, clamp to [40, 180], and fallback to 90 minutes.
- `TargetTimeMenuDelegate.onSelect()` writes new value to Storage and updates `mTargetTimeMs` live.
- `STORAGE_KEY_TARGET_MIN`, `TARGET_MIN_MINUTES`, `TARGET_MAX_MINUTES`, `TARGET_STEP_MINUTES`, `TARGET_DEFAULT_MINUTES` constants.

### Changed
- Hardcoded 90-minute default replaced by Storage-backed configurable value.
- WARMUP screen now shows the currently configured goal time in the center band.

### Build
- Binary: ~115 KB `.prg` (fr965)

---

## [0.5.0] — Phase 5: Imperative Three-Band UI

### Added
- `HybridPacerView.mc` — fully imperative rendering via `Dc` primitives (no `layout.xml`).
- **Three-band layout**: header (state + cycle counter), center (primary metric), footer (secondary / button hint).
- **Per-state screens**: WARMUP (goal time + GPS status), RUN (pace), TRANSITION (transition timer in yellow), STATION (station timer + active athlete), FINISH (total time + W/R ratio).
- High-contrast mode: white background during RUN, black background for all other states.
- Green/red pace coloring in RUN (green = at or ahead of target, red = behind).
- 1 Hz refresh `Timer` (`onTimerTick`) ensures partial timers advance even without GPS updates.
- Dimensions pre-computed in `onLayout()` to eliminate repeated divisions in `onUpdate()`.
- `formatPace()`, `formatClock()`, `formatRatio()` helper formatters.

### Fixed
- Button routing bug: `HybridPacerDelegate` rewritten using `BehaviorDelegate` callbacks.

### Build
- Binary: ~109 KB `.prg` (fr965)

---

## [0.4.0] — Phase 4: Predictive Pacing Engine

### Added
- `PacingEngine.mc` — stateless pacing math engine.
- `computeDynamicPaceTarget(targetTimeMs, elapsedTotalMs, distanceCompletedKm)` → target pace in s/km, recalculated on every RUN entry using projected future rest time.
- `computePaceDeltaDeviation(currentSpeedMps, paceTargetSecPerKm)` → pace delta (positive = slower than target).
- `mDynamicPaceTargetSec` member in `HybridPacerApp` updated by `FSMController` on each WARMUP→RUN and TRANSITION_OUT→RUN transition.
- `RACE_TOTAL_KM = 8.0f` constant.
- Per-athlete time accumulators (`mTimeAthleteA`, `mTimeAthleteB`) updated in `FSMController.accrueAthleteTime()`.
- `PACE_MIN_SPEED = 0.5f` guard against division by zero in pace calculations.

---

## [0.3.0] — Phase 3: FIT Recording & Developer Fields

### Added
- `HybridFitSession.mc` — owns 7 `FitContributor.Field` handles.
- `initializeFitFields(session)` registers all 7 developer fields on the `ActivityRecording.Session` at race start.
- `tickFitMetrics()` writes all 7 fields at ~1 Hz (called from `GpsSessionManager.onPosition()`).
- `clearFitFields()` disables writing after the session ends.
- `resources/fitcontributions.xml` — chart metadata (title, label, unit, fill color) for all 7 fields.
- FIT fields defined: `race_cycle_id`, `race_fsm_state`, `transition_total_time`, `station_elapsed`, `active_athlete`, `pace_delta_deviation`, `work_rest_ratio`.
- `FIT_ID_*` constants to keep field IDs in sync with `fitcontributions.xml`.
- `mIsInitialized` fast-path guard in `HybridFitSession` (no-op before `startRecording` or after `stopRecording`).

### Changed
- `GpsSessionManager.startRecording()` now calls `mFit.initializeFitFields(session)` before `session.start()`.
- `GpsSessionManager.stopRecording()` calls `mFit.clearFitFields()`.

---

## [0.2.0] — Phase 2: State Machine, Debounce & Doubles Mode

### Added
- `FSMController.mc` — sole mutator of FSM state, duration accumulators, and FIT lifecycle.
- `attemptTransition()` with 5000 ms debounce (`FSM_DEBOUNCE_MS`).
- Duration accounting: elapsed time (minus paused time) accumulated into `mWorkMs`, `mRestMs`, `mTransitionTotalMs` on each transition.
- `markLap()` → `GpsSessionManager.addLap()` on RUN→TRANSITION_IN and TRANSITION_OUT→RUN boundaries.
- **Doubles / relay mode**: `mActiveAthlete` flag, `accrueAthleteTime()` tracks per-athlete time.
- `STATE_WARMUP`, `STATE_RUN`, `STATE_TRANSITION_IN`, `STATE_STATION`, `STATE_TRANSITION_OUT`, `STATE_FINISH` constants.
- `RACE_TOTAL_CYCLES = 8` constant.

---

## [0.1.0] — Phase 1: Project Foundation

### Added
- Initial Garmin Connect IQ project scaffold for `fr965`.
- `HybridPacerApp` singleton with `getInitialView()`, `onStart()`, `onStop()`.
- `getApp()` global accessor function.
- `GpsSessionManager` with continuous GPS positioning and `ActivityRecording` session lifecycle.
- `HybridPacerView` and `HybridPacerDelegate` stubs.
- `manifest.xml` with Positioning, Fit, and FitContributor permissions.
- `monkey.jungle` with `typecheck=3` and `optimization=3z`.
