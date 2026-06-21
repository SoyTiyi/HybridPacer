import Toybox.Lang;

// ─── PacingEngine ─────────────────────────────────────────────────────────────
// Predictive pacing engine — the core value of HybridPacer.
// Stateless: reads mRestMs and mHyroxCycle from the singleton via getApp().
// Single instance created in HyroxPacerApp.initialize() as mPacing.
//
// Target pace is recomputed ONLY on entry to STATE_RUN (on the transition,
// never in the 1 Hz tick). Pure scalar arithmetic: < 1 ms execution time.
//
// MEMORY RULES:
//   - No `new` in any method (zero dynamic allocations in hot paths).
//   - No Lang.Dictionary as a domain structure.
//   - No switch/case: branches use if/else if.
//   - No Toybox.Math: only division and multiplication of primitives.

// Fixed HYROX running distance: 8 km total (1 km per cycle × 8 cycles).
const HYROX_TOTAL_KM as Float = 8.0f;

class PacingEngine {

    function initialize() {
        // No state of its own. All race parameters live in getApp().
    }

    // ── computeDynamicPaceTarget ──────────────────────────────────────────────
    // Calculates the dynamic target pace (s/km) for the next running kilometer.
    // Called by FSMController.attemptTransition() on every entry to STATE_RUN:
    //   - WARMUP → RUN: first km, no rest history yet.
    //   - ROXZONE_OUT → RUN: new km, with projected rest penalty.
    //
    // Parameters:
    //   targetTimeMs        — overall goal race time (ms).
    //   elapsedTotalMs      — committed time so far = mWorkMs + mRestMs (ms).
    //   distanceCompletedKm — kilometers already run = mHyroxCycle.
    //
    // Algorithm (integer/float arithmetic, no Math):
    //   1. distanceRemainingKm = 8.0 - distanceCompletedKm.
    //   2. avgRestMs = mRestMs / cyclesDone → mean rest per past cycle.
    //   3. projectedRestMs = avgRestMs × cyclesRemaining → projected future penalty.
    //   4. runTimeRemainingMs = targetTimeMs − elapsedTotalMs − projectedRestMs.
    //   5. return runTimeRemainingMs (ms) / 1000 / distanceRemainingKm (→ s/km).
    //
    // Returns 0.0f if the race is over or the athlete is off-plan
    // (the Phase 5 UI renders red when the result is 0.0f).
    function computeDynamicPaceTarget(targetTimeMs as Number, elapsedTotalMs as Number, distanceCompletedKm as Number) as Float {

        // 1. Remaining distance (km)
        var distanceRemainingKm = HYROX_TOTAL_KM - distanceCompletedKm.toFloat();
        if (distanceRemainingKm <= 0.0f) {
            return 0.0f;  // Race finished or distance exceeded
        }

        // 2. Project future rest penalty from historical average rest per cycle
        var app        = getApp();
        var cyclesDone = app.mHyroxCycle;  // Completed cycles (= km already run)
        var avgRestMs  = 0;
        if (cyclesDone > 0) {
            avgRestMs = app.mRestMs / cyclesDone;  // Integer division: mean rest ms per cycle
        }
        var cyclesRemaining = HYROX_TOTAL_CYCLES - cyclesDone;
        var projectedRestMs = avgRestMs * cyclesRemaining;  // Projected future logistics penalty (ms)

        // 3. Time available exclusively for running (ms)
        var runTimeRemainingMs = targetTimeMs - elapsedTotalMs - projectedRestMs;
        if (runTimeRemainingMs <= 0) {
            return 0.0f;  // Off-plan — UI will render in red (Phase 5)
        }

        // 4. Dynamic target pace (s/km): remaining run time / remaining distance
        return (runTimeRemainingMs / 1000.0f) / distanceRemainingKm;
    }

    // ── computePaceDeltaDeviation ─────────────────────────────────────────────
    // Calculates the deviation of the instantaneous pace from the dynamic target.
    //   Positive → athlete is slower than target (in deficit).
    //   Negative → athlete is faster than target (building surplus).
    //   0.0f    → speed below threshold (stopped, in transition, or at startup).
    //
    // Parameters:
    //   currentSpeedMps     — current GPS speed (m/s), from getApp().mGps.getSpeedMs().
    //   paceTargetSecPerKm  — current dynamic target (s/km), from mDynamicPaceTargetSec.
    //
    // Strict guard against division by zero: only computes if speed > PACE_MIN_SPEED.
    function computePaceDeltaDeviation(currentSpeedMps as Float, paceTargetSecPerKm as Float) as Float {
        if (currentSpeedMps > PACE_MIN_SPEED) {
            var paceNow = 1000.0f / currentSpeedMps;  // m/s → s/km
            return paceNow - paceTargetSecPerKm;       // δ vs. the dynamic target
        }
        return 0.0f;
    }

    // ── computeProjectedFinishMs ──────────────────────────────────────────────
    // Projects the total finishing time (ms) from the current real pace. It is the
    // inverse of computeDynamicPaceTarget: that solves for the pace needed to hit
    // the goal; this solves for the finish time if the athlete holds the current
    // pace, using the SAME real inputs (committed time, cycle count, average rest).
    // The RUN screen subtracts mTargetTimeMs from this to show ahead/behind goal.
    //
    // Parameters:
    //   elapsedTotalMs      — committed time so far = mWorkMs + mRestMs (ms).
    //   distanceCompletedKm — kilometers already run = mHyroxCycle.
    //   currentPaceSecPerKm — current real (smoothed) pace (s/km).
    //
    // Returns -1 when not yet computable (no valid pace, or race finished).
    function computeProjectedFinishMs(elapsedTotalMs as Number, distanceCompletedKm as Number, currentPaceSecPerKm as Float) as Number {
        if (currentPaceSecPerKm <= 0.0f) {
            return -1;  // No valid real pace yet → no projection
        }

        var distanceRemainingKm = HYROX_TOTAL_KM - distanceCompletedKm.toFloat();
        if (distanceRemainingKm <= 0.0f) {
            return -1;  // Race finished
        }

        // Project future rest penalty exactly as computeDynamicPaceTarget does.
        var app        = getApp();
        var cyclesDone = app.mHyroxCycle;
        var avgRestMs  = 0;
        if (cyclesDone > 0) {
            avgRestMs = app.mRestMs / cyclesDone;
        }
        var cyclesRemaining = HYROX_TOTAL_CYCLES - cyclesDone;
        var projectedRestMs = avgRestMs * cyclesRemaining;

        // Remaining run time if the current pace holds for the remaining distance.
        var runTimeRemainingMs = (distanceRemainingKm * currentPaceSecPerKm * 1000.0f).toNumber();

        return elapsedTotalMs + runTimeRemainingMs + projectedRestMs;
    }

    // ── computeCurrentPaceSec ─────────────────────────────────────────────────
    // Converts a speed (m/s) to a real pace (s/km) for display.
    // Pass the smoothed speed (getAvgSpeedMs) to avoid nervous display jumps.
    // Returns 0.0f if speed is below threshold (stopped / no fix) → UI renders "--:--".
    function computeCurrentPaceSec(currentSpeedMps as Float) as Float {
        if (currentSpeedMps > PACE_MIN_SPEED) {
            return 1000.0f / currentSpeedMps;  // m/s → s/km
        }
        return 0.0f;
    }

}
