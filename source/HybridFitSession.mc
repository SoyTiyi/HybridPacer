import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Lang;
import Toybox.System;

// ─── Pacing constants ─────────────────────────────────────────────────────────
// Reference pace for a hybrid race: 5:00 min/km = 300 s/km.
// pace_delta_deviation > 0 → slower than target; < 0 → faster.
const TARGET_PACE_SEC_PER_KM as Number = 300;
const PACE_MIN_SPEED         as Float  = 0.5f;  // Minimum threshold (m/s) to compute pace

// ─── FIT Field IDs ────────────────────────────────────────────────────────────
// MUST match the id attribute of the <fitField> entries in fitcontributions.xml.
const FIT_ID_CYCLE_ID        as Number = 0;
const FIT_ID_FSM_STATE       as Number = 1;
const FIT_ID_TRANSITION_TOTAL   as Number = 2;
const FIT_ID_STATION_ELAPSED as Number = 3;
const FIT_ID_ACTIVE_ATHLETE  as Number = 4;
const FIT_ID_PACE_DELTA      as Number = 5;
const FIT_ID_WORK_REST       as Number = 6;

// ─── HybridFitSession ──────────────────────────────────────────────────────────
// Singleton that owns the 7 FitContributor.Field handles and exposes:
//   - initializeFitFields(session): registers the 7 fields on the active FIT session.
//   - tickFitMetrics():             writes current values at ~1 Hz (no new).
//   - clearFitFields():             disables writing when the session closes.
//
// TYPECHECK=3 PATTERN FOR NULLABLE HANDLES:
//   The 7 fields are declared as 'Field? = null'. In initializeFitFields(), a local
//   variable 'var f = session.createField(...)' (inferred non-nullable Field type) is
//   used to call f.setData() before assigning to the member. In tickFitMetrics(), the
//   pattern 'var f = mFieldXxx; if (f != null) { f.setData(...); }' is used — the
//   compiler narrows f's type inside the guard (same pattern as info.position in
//   GpsSessionManager.onPosition). mIsInitialized acts as a fast-path guard so that
//   in production the null-checks are always true (zero overhead).
//
// MEMORY RULES:
//   - No `new` in tickFitMetrics() or in any hot path.
//   - No Lang.Dictionary as a domain structure.
//   - No switch/case: branches use if/else if.
class HybridFitSession {

    // ── Guard flag ────────────────────────────────────────────────────────
    // false until initializeFitFields() completes; returns to false in clearFitFields().
    // tickFitMetrics() checks this flag first: immediate exit if not recording.
    var mIsInitialized as Boolean = false;

    // ── FIT field handles (nullable) ──────────────────────────────────────
    // null until initializeFitFields() is called; null again after clearFitFields().
    // Accessed via local variable to satisfy typecheck=3 (see tickFitMetrics).
    var mFieldCycleId        as FitContributor.Field? = null;
    var mFieldFsmState       as FitContributor.Field? = null;
    var mFieldTransitionTotal   as FitContributor.Field? = null;
    var mFieldStationElapsed as FitContributor.Field? = null;
    var mFieldActiveAthlete  as FitContributor.Field? = null;
    var mFieldPaceDelta      as FitContributor.Field? = null;
    var mFieldWorkRest       as FitContributor.Field? = null;

    function initialize() {
        // mIsInitialized = false and all handles = null (declared above).
        // Nothing from the SDK is created here; the Session handle does not exist yet.
    }

    // ── initializeFitFields(session) ──────────────────────────────────────
    // Called from GpsSessionManager.startRecording(), just before session.start().
    // typecheck=3 pattern:
    //   1. var f = session.createField(...)  → f has type Field (non-nullable, inferred)
    //   2. f.setData(initial_value)          → valid because f is non-nullable
    //   3. mFieldXxx = f                     → assigns Field to Field? (valid)
    // Dict literals are a permitted exception: single init calls, never at 1 Hz.
    function initializeFitFields(session as ActivityRecording.Session) as Void {
        var f = session.createField(
            "race_cycle_id",
            FIT_ID_CYCLE_ID,
            FitContributor.DATA_TYPE_UINT8,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "cycle"}
        );
        f.setData(0);
        mFieldCycleId = f;

        f = session.createField(
            "race_fsm_state",
            FIT_ID_FSM_STATE,
            FitContributor.DATA_TYPE_UINT8,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "state"}
        );
        f.setData(1);          // Starts at STATE_RUN (just transitioned from WARMUP)
        mFieldFsmState = f;

        f = session.createField(
            "transition_total_time",
            FIT_ID_TRANSITION_TOTAL,
            FitContributor.DATA_TYPE_UINT32,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "s"}
        );
        f.setData(0);
        mFieldTransitionTotal = f;

        f = session.createField(
            "station_elapsed",
            FIT_ID_STATION_ELAPSED,
            FitContributor.DATA_TYPE_UINT32,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "s"}
        );
        f.setData(0);
        mFieldStationElapsed = f;

        f = session.createField(
            "active_athlete",
            FIT_ID_ACTIVE_ATHLETE,
            FitContributor.DATA_TYPE_UINT8,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "bool"}
        );
        f.setData(1);          // Primary athlete active at race start
        mFieldActiveAthlete = f;

        f = session.createField(
            "pace_delta_deviation",
            FIT_ID_PACE_DELTA,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "s/km"}
        );
        f.setData(0.0f);
        mFieldPaceDelta = f;

        f = session.createField(
            "work_rest_ratio",
            FIT_ID_WORK_REST,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "ratio"}
        );
        f.setData(0.0f);
        mFieldWorkRest = f;

        // Activate the guard: tickFitMetrics() can now write.
        mIsInitialized = true;
    }

    // ── clearFitFields() ──────────────────────────────────────────────────
    // Called from GpsSessionManager.stopRecording() and stop().
    // Deactivates the guard; handles remain as-is (never accessed after this).
    function clearFitFields() as Void {
        mIsInitialized = false;
    }

    // ── tickFitMetrics() ──────────────────────────────────────────────────
    // Writes the current values of all 7 FIT fields. Called from
    // GpsSessionManager.onPosition() at ~1 Hz.
    // FORBIDDEN: new, Lang.Dictionary, switch/case.
    //
    // typecheck=3 null-check pattern for members:
    //   var f = mFieldXxx;          → f infers type Field? from the member
    //   if (f != null) { f.setData(...); }  → compiler narrows f to Field
    // 'f' is reused for all 7 fields (single local variable declaration).
    // In production, mIsInitialized = true guarantees null-checks are always true;
    // they are semantic no-ops to satisfy the type checker.
    function tickFitMetrics() as Void {
        // Fast path: not recording yet (before startRecording or after stopRecording).
        if (!mIsInitialized) {
            return;
        }

        var app   = getApp();
        var state = app.mFsmState;
        var now   = System.getTimer();

        // ── 1. race_cycle_id (0-7) ──────────────────────────────────────
        var f = mFieldCycleId;
        if (f != null) {
            f.setData(app.mRaceCycle);
        }

        // ── 2. race_fsm_state (0-5) ─────────────────────────────────────
        f = mFieldFsmState;
        if (f != null) {
            f.setData(state);
        }

        // ── 3. transition_total_time — committed total + live partial ─────────
        var transitionSec = app.mTransitionTotalMs / 1000;
        if (state == STATE_TRANSITION_IN || state == STATE_TRANSITION_OUT) {
            transitionSec = transitionSec + (now - app.mLastTransitionMs) / 1000;
        }
        f = mFieldTransitionTotal;
        if (f != null) {
            f.setData(transitionSec);
        }

        // ── 4. station_elapsed — time in the current workout station ──────
        var stationSec = 0;
        if (state == STATE_STATION) {
            stationSec = (now - app.mLastTransitionMs) / 1000;
        }
        f = mFieldStationElapsed;
        if (f != null) {
            f.setData(stationSec);
        }

        // ── 5. active_athlete — 1=active, 0=waiting for relay (doubles) ──
        f = mFieldActiveAthlete;
        if (f != null) {
            if (app.mActiveAthlete) {
                f.setData(1);
            } else {
                f.setData(0);
            }
        }

        // ── 6. pace_delta_deviation — δ vs. dynamic target ────────────────
        // Delegates to PacingEngine.computePaceDeltaDeviation():
        //   speed > PACE_MIN_SPEED → pace = 1000/speed (s/km); δ = pace - target.
        //   Positive → slower than target; negative → faster.
        //   mDynamicPaceTargetSec is recalculated only on STATE_RUN entry.
        var paceDelta = app.mPacing.computePaceDeltaDeviation(
            app.mGps.getSpeedMs(),
            app.mDynamicPaceTargetSec);
        f = mFieldPaceDelta;
        if (f != null) {
            f.setData(paceDelta);
        }

        // ── 7. work_rest_ratio — running time / rest time ─────────────────
        var ratio = 0.0f;
        if (app.mRestMs > 0) {
            ratio = app.mWorkMs.toFloat() / app.mRestMs.toFloat();
        }
        f = mFieldWorkRest;
        if (f != null) {
            f.setData(ratio);
        }
    }

}
