import Toybox.Position;
import Toybox.ActivityRecording;
import Toybox.Activity;
import Toybox.Lang;
import Toybox.WatchUi;

// ─── GpsSessionManager ────────────────────────────────────────────────────────
// Encapsulates two low-level SDK responsibilities with different lifetimes:
//
//   1. Positioning (continuous GPS): active for the entire app lifetime.
//      start() enables GPS in App.onStart(); stop() releases it in App.onStop().
//
//   2. ActivityRecording (FIT session): active only between startRecording() and stopRecording().
//      startRecording() → called from FSMController on WARMUP→RUN.
//      stopRecording()  → called from FSMController on reaching FINISH.
//      stop() acts as a safety net on forced app exit.
//
// TYPECHECK=3 PATTERN FOR NULLABLE MEMBERS:
//   mSession is declared as 'Session?' (nullable). To call SDK methods on it without
//   type errors, always copy to a local variable before the null-check:
//   'var s = mSession; if (s != null) { ... }'. The compiler narrows the local's type
//   (same pattern used with 'pos' in onPosition).
//
// MEMORY RULE:
//   - All state fields are pre-assigned in initialize().
//   - onPosition() instantiates nothing; it only updates primitives and dispatches
//     tickFitMetrics() (which is a no-op if mIsInitialized = false).
//   - Dict literals in startRecording() are a justified exception (single init call, not 1 Hz).

// Exponential moving average (EMA) of GPS speed. alpha 0.25 ≈ ~4 s time constant
// at 1 Hz: smooths out instant-pace noise (which can jump several s/km between samples)
// without introducing a perceptible lag. Only float multiply/add → safe for the
// onPosition hot path (no dynamic allocations).
const SPEED_SMOOTHING_ALPHA as Float = 0.25f;

class GpsSessionManager {

    // ── GPS position cache ─────────────────────────────────────────────────
    // Pre-assigned so that onPosition() (~1 Hz callback) never uses `new`.
    var mLat      as Double  = 0.0d;   // Latitude in decimal degrees
    var mLon      as Double  = 0.0d;   // Longitude in decimal degrees
    var mSpeed    as Float   = 0.0f;   // Instantaneous speed in m/s
    var mSpeedAvg as Float   = 0.0f;   // EMA-smoothed speed in m/s → used for on-screen pace
    var mAccuracy as Number  = 0;      // Quality enum: Position.QUALITY_*
    var mHasFix   as Boolean = false;  // true when accuracy > NOT_AVAILABLE

    // ── FIT recording session ──────────────────────────────────────────────
    // null until startRecording() is called (WARMUP → RUN).
    var mSession as ActivityRecording.Session? = null;

    function initialize() {
        // All members already have initial values above.
        // The SDK is NOT touched here: Position and ActivityRecording can only be
        // initialized after AppBase.onStart() has been called.
    }

    // ── start() ───────────────────────────────────────────────────────────
    // Called from HybridPacerApp.onStart(). Enables continuous GPS only.
    // The FIT session is NOT created here; that happens in startRecording() when
    // the athlete confirms race start (WARMUP → RUN).
    function start() as Void {
        // method(:onPosition) → method reference, does not create objects.
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    // ── startRecording() ──────────────────────────────────────────────────
    // Called from FSMController.attemptTransition() on WARMUP→RUN.
    // Creates the FIT session, registers the 7 race FIT fields, and starts recording.
    // typecheck=3 pattern: var s = mSession; if (s != null) to narrow the type.
    function startRecording() as Void {
        mSession = ActivityRecording.createSession({
            :name     => "HybridPacer",
            :sport    => Activity.SPORT_RUNNING,
            :subSport => Activity.SUB_SPORT_GENERIC
        });

        var s = mSession;
        if (s != null) {
            // Register the 7 FIT developer fields before starting the timer.
            getApp().mFit.initializeFitFields(s);
            // Start recording (starts the FIT timer and per-second records).
            s.start();
        }
    }

    // ── stopRecording() ───────────────────────────────────────────────────
    // Called from FSMController.attemptTransition() on reaching STATE_FINISH.
    // Stops the FIT timer, saves the .fit file, and disables further writes.
    function stopRecording() as Void {
        var s = mSession;
        if (s != null && s.isRecording()) {
            s.stop();
            s.save();
        }
        mSession = null;
        // Disable mIsInitialized: tickFitMetrics() becomes a no-op.
        getApp().mFit.clearFitFields();
    }

    // ── pauseRecording() (Phase 7) ─────────────────────────────────────────
    // Pauses the FIT timer without saving: the session stays alive. SDK 9.2.0:
    // Session.stop() halts the timer; a subsequent start() resumes it.
    // Nullable pattern: local copy + null-check; guard with isRecording().
    function pauseRecording() as Void {
        var s = mSession;
        if (s != null && s.isRecording()) {
            s.stop();
        }
    }

    // ── resumeRecording() (Phase 7) ───────────────────────────────────────
    // Resumes the FIT timer on the SAME session (save() deferred to FINISH).
    function resumeRecording() as Void {
        var s = mSession;
        if (s != null && !s.isRecording()) {
            s.start();
        }
    }

    // ── addLap() ──────────────────────────────────────────────────────────
    // Inserts a native lap event (split) into the FIT file.
    // Called from FSMController.markLap() at the boundaries:
    //   - RUN(1) → TRANSITION_IN(2): start of transition corridor
    //   - TRANSITION_OUT(4) → RUN(1): return to running
    function addLap() as Void {
        var s = mSession;
        if (s != null && s.isRecording()) {
            s.addLap();
        }
    }

    // ── onPosition() ──────────────────────────────────────────────────────
    // SDK Positioning callback. Called at ~1 Hz while GPS is active.
    // FORBIDDEN: new, Lang.Dictionary, switch/case, access to transient objects.
    // Only updates pre-assigned primitives and triggers the FIT tick.
    function onPosition(info as Position.Info) as Void {
        // Cache signal quality (Position.QUALITY_* enum, a Number).
        mAccuracy = info.accuracy;

        if (mAccuracy > Position.QUALITY_NOT_AVAILABLE) {
            mHasFix = true;

            // toDegrees() returns Array<Double> of [lat, lon].
            // Null guard required: info.position is Position.Location or Null (API 4.x).
            var pos = info.position;
            if (pos != null) {
                var deg = pos.toDegrees() as Array<Double>;
                mLat = deg[0];
                mLon = deg[1];
            }

            // Speed in m/s (may be null if the device does not report it).
            if (info has :speed && info.speed != null) {
                mSpeed = info.speed as Float;
            }
        } else {
            mHasFix = false;
        }

        // Exponential moving average of speed for the on-screen real pace display.
        // Updated every callback (~1 Hz) using the last known speed (mSpeed).
        mSpeedAvg = mSpeedAvg + SPEED_SMOOTHING_ALPHA * (mSpeed - mSpeedAvg);

        // Write FIT metrics at the GPS rate (~1 Hz).
        // No-op if mIsInitialized = false (before startRecording or after stopRecording).
        getApp().mFit.tickFitMetrics();
        // Refresh the imperative view with the latest GPS data.
        WatchUi.requestUpdate();
    }

    // ── stop() ────────────────────────────────────────────────────────────
    // Called from HybridPacerApp.onStop(). Safety net: saves the session if it is
    // still alive (e.g. forced exit before FINISH) and releases GPS.
    function stop() as Void {
        var s = mSession;
        // Phase 7: also saves a PAUSED session (isRecording()=false after pauseRecording).
        // Without this, exiting the app while paused would lose the .fit file.
        if (s != null) {
            if (s.isRecording()) {
                s.stop();
            }
            s.save();
        }
        mSession = null;
        // Disable mIsInitialized (idempotent if already called by stopRecording).
        getApp().mFit.clearFitFields();
        // Release the GPS module.
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }

    // ── Read-only getters for the view and pacing engine ─────────────────

    function hasFix() as Boolean {
        return mHasFix;
    }

    function getLatitude() as Double {
        return mLat;
    }

    function getLongitude() as Double {
        return mLon;
    }

    function getSpeedMs() as Float {
        return mSpeed;
    }

    // EMA-smoothed speed in m/s. Use this for displaying real pace (avoids the
    // nervous jumps of instantaneous pace between GPS samples).
    function getAvgSpeedMs() as Float {
        return mSpeedAvg;
    }

    function getAccuracy() as Number {
        return mAccuracy;
    }

}
