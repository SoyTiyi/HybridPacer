import Toybox.Activity;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// ─── FSMController ────────────────────────────────────────────────────────────
// FSM mutation engine for the hybrid race. Single instance created in App.initialize().
// Sole source of mutation for:
//   mFsmState, mRaceCycle, mLastTransitionMs,
//   mWorkMs, mRestMs, mTransitionTotalMs.
//
// MEMORY RULES (critical):
//   - No `new` in any method (zero dynamic allocations in hot paths).
//   - No Lang.Dictionary as a domain structure.
//   - No switch/case: transitions controlled by if/else if blocks.
//
// All race state lives in the HybridPacerApp singleton (accessible via getApp()).
// FSMController contains only mutation logic; it holds no state of its own.
class FSMController {

    function initialize() {
        // No state of its own: the FSM lives in the app singleton (getApp()).
        // Nothing to initialize here; the App members are already pre-assigned.
    }

    // ── attemptTransition() ───────────────────────────────────────────────────
    // Transition attempt triggered by KEY_LAP / KEY_BACK from the delegate.
    // Applies debounce, accounts for per-state durations, manages the FIT recording
    // lifecycle, and marks splits at the correct boundaries.
    // Events arriving within the 5000 ms window are silently discarded.
    function attemptTransition() as Void {
        var app   = getApp();
        var state = app.mFsmState;

        // STATE_FINISH(5) is terminal: no further transitions are possible.
        if (state >= STATE_FINISH) {
            return;
        }

        // ── 5000 ms DEBOUNCE (immutable time lock) ────────────────────────
        // Silently discards any event within the debounce window.
        var now = System.getTimer();
        if (now - app.mLastTransitionMs < FSM_DEBOUNCE_MS) {
            return;
        }

        // ── Duration accounting for the state being left ──────────────────
        // WARMUP is not accounted for: it is pre-race time and mLastTransitionMs = 0.
        // For all other states, elapsed = actual ms spent in that state.
        if (state != STATE_WARMUP) {
            // Subtract paused time within this state (Phase 7): frozen time
            // never enters the accumulators or the athlete's total.
            var elapsed = now - app.mLastTransitionMs - app.mPausedMs;
            if (state == STATE_RUN) {
                // Running time → work accumulator.
                app.mWorkMs = app.mWorkMs + elapsed;
            } else if (state == STATE_TRANSITION_IN || state == STATE_TRANSITION_OUT) {
                // Transition time → rest accumulator and Transition accumulator.
                app.mRestMs = app.mRestMs + elapsed;
                app.mTransitionTotalMs = app.mTransitionTotalMs + elapsed;
            } else if (state == STATE_STATION) {
                // Workout station time → rest accumulator.
                app.mRestMs = app.mRestMs + elapsed;
            }
            // Credit elapsed time to the active relay athlete (doubles mode).
            accrueAthleteTime(app, elapsed);
        }

        // ── Transition logic (if/else if — switch/case FORBIDDEN) ─────────
        if (state == STATE_TRANSITION_OUT) {        // 4 → (1 | 5)
            // Increment the master cycle BEFORE evaluating whether the race is over.
            app.mRaceCycle = app.mRaceCycle + 1;

            if (app.mRaceCycle >= RACE_TOTAL_CYCLES) {
                // All 8 cycles completed: stop and save the FIT session.
                app.mGps.stopRecording();
                app.mFsmState = STATE_FINISH;
            } else {
                // New cycle: insert a FIT split and return to RUN.
                markLap();
                app.mFsmState = STATE_RUN;
                // Recompute the target pace for the new run segment.
                // At this point: mRaceCycle already incremented, mRestMs updated with
                // the TRANSITION_OUT elapsed, mWorkMs accumulated through the last RUN.
                app.mDynamicPaceTargetSec = app.mPacing.computeDynamicPaceTarget(
                    app.mTargetTimeMs,
                    app.mWorkMs + app.mRestMs,
                    app.mRaceCycle);
                // Anchor the per-km distance baseline for the new running segment.
                captureRunBaseline(app);
            }
        } else {
            // Linear increment: 0→1, 1→2, 2→3, 3→4.
            if (state == STATE_WARMUP) {
                // WARMUP→RUN: first athlete lap → start FIT recording.
                app.mGps.startRecording();
            }
            if (state == STATE_RUN) {
                // RUN→TRANSITION_IN: entering transition corridor → FIT split.
                markLap();
            }
            app.mFsmState = state + 1;
            // On entering the first RUN (WARMUP→RUN), compute the initial target pace.
            // elapsedTotalMs = 0 (no committed time yet), distanceCompleted = 0.
            // Result: targetTimeMs / 8 km → 675 s/km for a 90-minute goal.
            if (state == STATE_WARMUP) {
                app.mDynamicPaceTargetSec = app.mPacing.computeDynamicPaceTarget(
                    app.mTargetTimeMs,
                    app.mWorkMs + app.mRestMs,
                    app.mRaceCycle);
                // Anchor the per-km distance baseline for the first running segment.
                captureRunBaseline(app);
            }
        }

        // Seal the time lock with the timestamp of this successful transition.
        app.mLastTransitionMs = now;
        // Reset the pause accumulator: mPausedMs is per-state (Phase 7).
        app.mPausedMs = 0;
        // Refresh the view to immediately reflect the new FSM state.
        WatchUi.requestUpdate();
    }

    // ── markLap() ─────────────────────────────────────────────────────────────
    // Inserts a native split into the FIT file.
    // Called at the two boundaries that produce a visible split in Garmin Connect:
    //   - RUN(1) → TRANSITION_IN(2): athlete leaves the run and enters the Transition.
    //   - TRANSITION_OUT(4) → RUN(1): athlete completes the station and returns to running.
    private function markLap() as Void {
        getApp().mGps.addLap();
    }

    // ── captureRunBaseline() ──────────────────────────────────────────────────
    // Records the cumulative recorded distance (m) at the start of a running
    // segment so the RUN screen can show meters covered / remaining in the
    // current km. Called only on RUN entry (a transition, not a hot path).
    // Activity.Info.elapsedDistance is null until the FIT session reports valid
    // distance; the guard leaves the previous baseline untouched in that case.
    private function captureRunBaseline(app as HybridPacerApp) as Void {
        var info = Activity.getActivityInfo();
        if (info != null && info has :elapsedDistance) {
            var dist = info.elapsedDistance;
            if (dist != null) {
                app.mRunBaselineDistanceM = dist;
            }
        }
    }

    // ── accrueAthleteTime() ───────────────────────────────────────────────────
    // Adds the elapsed time (ms) to the active athlete's accumulator in doubles mode.
    // mActiveAthlete = true → Athlete A; false → Athlete B.
    // Allows individual Work/Rest Ratio calculation at the end of the race.
    // Only called from duration accounting (state != STATE_WARMUP).
    private function accrueAthleteTime(app as HybridPacerApp, elapsed as Number) as Void {
        if (app.mActiveAthlete) {
            app.mTimeAthleteA = app.mTimeAthleteA + elapsed;
        } else {
            app.mTimeAthleteB = app.mTimeAthleteB + elapsed;
        }
    }

}
