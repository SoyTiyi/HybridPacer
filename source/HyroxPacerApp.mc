import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// ─── FSM State Constants ─────────────────────────────────────────────────────
// Immutable sequence: WARMUP → RUN → ROXZONE_IN → STATION → ROXZONE_OUT → FINISH
// Used as integer indices for future Lang.Array lookups.
// FORBIDDEN: switch/case — all transitions controlled by if/else if blocks.
const STATE_WARMUP      as Number = 0;
const STATE_RUN         as Number = 1;
const STATE_ROXZONE_IN  as Number = 2;
const STATE_STATION     as Number = 3;
const STATE_ROXZONE_OUT as Number = 4;
const STATE_FINISH      as Number = 5;

// Total number of HYROX cycles (8 runs + 8 workout stations)
const HYROX_TOTAL_CYCLES as Number = 8;

// Immutable debounce window between state transitions (ms) — enforced in Phase 2
const FSM_DEBOUNCE_MS as Number = 5000;

// ─── Configurable target time (Phase 6) ─────────────────────────────────────
// The athlete sets their overall goal in WARMUP (presets every 5 min). The value
// is persisted in Application.Storage as MINUTES (Number) and loaded in initialize().
const TARGET_MIN_MINUTES     as Number = 40;           // Minimum valid target (elite/training)
const TARGET_MAX_MINUTES     as Number = 180;          // Maximum valid target (beginner/scaled)
const TARGET_STEP_MINUTES    as Number = 5;            // Step size between presets
const TARGET_DEFAULT_MINUTES as Number = 90;           // Fallback if no saved value exists
const STORAGE_KEY_TARGET_MIN as String = "target_min"; // Storage key (minutes)

// ─── In-place target editing (WARMUP) ───────────────────────────────────────
// UP/DOWN adjust the target directly in WARMUP. Taps within ACCEL_WINDOW grow the
// step (rapid-press acceleration) because BehaviorDelegate exposes no button-hold.
const TARGET_ACCEL_WINDOW_MS as Number = 600;  // Two taps closer than this accelerate
const TARGET_ACCEL_MAX_STEP  as Number = 30;   // Step cap (minutes) while accelerating
const TARGET_QUICK_JUMP_MIN  as Number = 15;   // Long-press UP coarse jump (minutes)
const TARGET_BADGE_MS        as Number = 900;   // How long the step badge stays visible (ms)

class HyroxPacerApp extends Application.AppBase {

    // ── FSM members ───────────────────────────────────────────────────────
    // Pre-assigned in initialize() to satisfy the memory rule:
    // zero dynamic allocations outside of startup.
    var mFsmState        as Number = STATE_WARMUP;  // Initial state: warm-up
    var mLastTransitionMs as Number = 0;             // Timestamp of the last transition
                                                     // (base for the 5000 ms debounce in Phase 2)
    var mHyroxCycle      as Number = 0;              // Current cycle (0..7), used by the UI in Phase 5
    var mActiveAthlete   as Boolean = true;          // Doubles: active relay athlete (Phase 2)

    // ── Pause / Resume (Phase 7) ───────────────────────────────────────────
    // NOT a new FSM state: the FSM sequence is immutable. This is an App-level
    // flag that freezes the chronometer, partials, and FIT recording in race states.
    var mIsPaused     as Boolean = false; // true while the race is paused
    var mPauseStartMs as Number  = 0;     // System.getTimer() value when the current pause began
    var mPausedMs     as Number  = 0;     // ms paused accumulated WITHIN the current state;
                                          // reset to 0 on every successful transition

    // ── Duration accumulators per state ───────────────────────────────────
    // Updated by FSMController.attemptTransition() on each transition.
    // Only Number (ms) additions: zero dynamic allocations.
    var mWorkMs         as Number = 0;   // Total time in STATE_RUN (ms)
    var mRestMs         as Number = 0;   // Total time in ROXZONE_IN + STATION + ROXZONE_OUT (ms)
    var mRoxzoneTotalMs as Number = 0;   // Total time in ROXZONE_IN + ROXZONE_OUT only (ms)

    // ── Target time and pacing engine output (Phase 4) ────────────────────
    var mTargetTimeMs         as Number = 5400000; // Overall goal (ms). Overwritten in initialize() from Storage (Phase 6)
    var mTimeAthleteA         as Number = 0;       // Doubles: total ms accumulated by Athlete A
    var mTimeAthleteB         as Number = 0;       // Doubles: total ms accumulated by Athlete B
    var mDynamicPaceTargetSec as Float  = 0.0f;   // Dynamic target pace (s/km) — read by the UI in Phase 5

    // ── In-place target editing UI state (WARMUP) ─────────────────────────
    // Not FSM state: written by the button handler, read by the WARMUP renderer
    // for rapid-press acceleration and the transient "+15" step badge.
    var mTargetAdjustAtMs   as Number = 0;   // System.getTimer() of the last UP/DOWN adjust
    var mTargetLastDeltaMin as Number = 0;   // Signed minutes of the last adjust (badge text)

    // ── GPS + recording manager ────────────────────────────────────────────
    // Single instance; created here and never destroyed while the app is alive.
    var mGps as GpsSessionManager;

    // ── FSM controller ────────────────────────────────────────────────────
    // Single instance; the only source of mutation for mFsmState.
    var mFsm as FSMController;

    // ── FIT session engine ────────────────────────────────────────────────
    // Owns the 7 FitContributor.Field handles; initializeFitFields() is called
    // from GpsSessionManager.startRecording() when the session is created.
    var mFit as HyroxFitSession;

    // ── Predictive pacing engine (Phase 4) ────────────────────────────────
    // Computes computeDynamicPaceTarget and computePaceDeltaDeviation.
    // Single instance; stateless (reads/writes via getApp()).
    var mPacing as PacingEngine;

    function initialize() {
        AppBase.initialize();

        // Reserve the manager instances. The SDK (Position + ActivityRecording)
        // is NOT activated here; that happens in onStart() when the runtime is ready.
        mGps    = new GpsSessionManager();
        mFsm    = new FSMController();
        mFit    = new HyroxFitSession();
        mPacing = new PacingEngine();

        // Load the persisted target time (minutes) with fallback + defensive clamp.
        // SDK nullable pattern: local copy + type check.
        var saved = Storage.getValue(STORAGE_KEY_TARGET_MIN);
        var minutes = TARGET_DEFAULT_MINUTES;
        if (saved instanceof Lang.Number) {
            minutes = saved;
            if (minutes < TARGET_MIN_MINUTES) {
                minutes = TARGET_MIN_MINUTES;
            } else if (minutes > TARGET_MAX_MINUTES) {
                minutes = TARGET_MAX_MINUTES;
            }
        }
        mTargetTimeMs = minutes * 60000;
    }

    // onStart() is called when the app is in the foreground and the system is ready.
    // This is the only correct place to start activity recording.
    function onStart(state as Dictionary?) as Void {
        mGps.start();
    }

    // onStop() is called when exiting the app (BACK from root level or power-off).
    // Saves the FIT session and releases GPS to free radio resources.
    function onStop(state as Dictionary?) as Void {
        mGps.stop();
    }

    // ── togglePause() (Phase 7) ────────────────────────────────────────────
    // Toggles pause/resume ONLY in race states (RUN..ROXZONE_OUT).
    // Called from HyroxPacerDelegate.onSelect() (START/STOP button).
    // Timing: on resume, the time spent paused in this state is accumulated into
    // mPausedMs; FSMController and the view subtract it so the partial freezes and
    // continues where it left off (without inflating accumulators or the total).
    // FIT: stop() pauses the timer, start() resumes it (same session, save() deferred to FINISH).
    // No new, if/else (no switch).
    function togglePause() as Void {
        if (mFsmState < STATE_RUN || mFsmState >= STATE_FINISH) {
            return;
        }
        var now = System.getTimer();
        if (mIsPaused) {
            mPausedMs = mPausedMs + (now - mPauseStartMs);
            mIsPaused = false;
            mGps.resumeRecording();
        } else {
            mPauseStartMs = now;
            mIsPaused = true;
            mGps.pauseRecording();
        }
        WatchUi.requestUpdate();
    }

    // ── In-place target editing (WARMUP) ──────────────────────────────────
    // Called from the UP/DOWN handlers. dir = +1 (UP) / -1 (DOWN). Rapid taps
    // (gap < TARGET_ACCEL_WINDOW_MS) grow the step up to TARGET_ACCEL_MAX_STEP,
    // because BehaviorDelegate offers no button-hold callback. Not a hot path:
    // reading System.getTimer() here is allowed. No new, if/else (no switch).
    function nudgeTarget(dir as Number) as Void {
        var now  = System.getTimer();
        var step = TARGET_STEP_MINUTES;
        if (now - mTargetAdjustAtMs < TARGET_ACCEL_WINDOW_MS) {
            step = mTargetLastDeltaMin.abs() + TARGET_STEP_MINUTES;
            if (step > TARGET_ACCEL_MAX_STEP) {
                step = TARGET_ACCEL_MAX_STEP;
            }
        }
        applyTargetDelta(dir * step, now);
    }

    // Long-press UP coarse jump (replaces the removed presets Menu2).
    function quickJumpTarget() as Void {
        applyTargetDelta(TARGET_QUICK_JUMP_MIN, System.getTimer());
    }

    // Clamps to [TARGET_MIN_MINUTES, TARGET_MAX_MINUTES], updates the goal,
    // records badge state, and persists MINUTES to Storage. Persistence lives
    // in this handler-invoked path, never in the renderer.
    private function applyTargetDelta(deltaMin as Number, now as Number) as Void {
        var minutes = (mTargetTimeMs / 60000) + deltaMin;
        if (minutes < TARGET_MIN_MINUTES) {
            minutes = TARGET_MIN_MINUTES;
        } else if (minutes > TARGET_MAX_MINUTES) {
            minutes = TARGET_MAX_MINUTES;
        }
        mTargetTimeMs       = minutes * 60000;
        mTargetLastDeltaMin = deltaMin;
        mTargetAdjustAtMs   = now;
        Storage.setValue(STORAGE_KEY_TARGET_MIN, minutes);
        WatchUi.requestUpdate();
    }

    // Returns the app's initial view.
    // HyroxPacerDelegate is the InputDelegate with full FSM since Phase 2.
    // HyroxPacerView is the imperative three-band view (Phase 5).
    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new HyroxPacerView(), new HyroxPacerDelegate() ];
    }

}

// Global accessor for the app singleton — required so views and delegates
// can access mFsmState, mGps, etc. without instantiating anything new.
function getApp() as HyroxPacerApp {
    return Application.getApp() as HyroxPacerApp;
}
