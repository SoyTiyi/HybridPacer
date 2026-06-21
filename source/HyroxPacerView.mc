import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// ─── HyroxPacerView ────────────────────────────────────────────────────────────
// High-contrast imperative view for HYROX Pacer.
// Draws EXCLUSIVELY with Dc primitives (layout.xml is forbidden).
// Three-band structure whose CONTENT depends on the FSM state:
//   HEADER     (y < 25%):  state + cycle ("RUN  km 4/8", "STATION 4/8", ...)
//   CENTER     (middle):   primary metric for the state (pace target or timer)
//   FOOTER     (y > 75%):  secondary data / button hint / active athlete
//
// 1 HZ REFRESH: in addition to updates triggered by onPosition (~1Hz)
// and FSM transitions, a dedicated Timer forces requestUpdate() every 1000 ms
// so that partial timers advance even when the GPS reports no movement.
//
// MEMORY RULES (critical):
//   - No new in onUpdate (hot path at ~1 Hz). The new for the Timer lives in onShow.
//   - Dimensions pre-assigned in onLayout().
//   - No switch/case: state dispatch uses if/else if on mFsmState.
class HyroxPacerView extends WatchUi.View {

    // Pre-assigned dimensions to avoid repeated calculations in onUpdate().
    var mWidth        as Number = 0;
    var mHeight       as Number = 0;
    var mCenterX      as Number = 0;
    var mCenterY      as Number = 0;
    var mBandTopY     as Number = 0;   // center of the header band (~12.5% from top)
    var mBandBottomY  as Number = 0;   // center of the footer band (~87.5% from top)
    var mLineH        as Number = 0;   // approximate line height for stacking text

    // 1 Hz refresh timer. Nullable: created in onShow(), stopped in onHide().
    var mTimer as Timer.Timer? = null;

    function initialize() {
        View.initialize();
    }

    // Pre-computes screen dimensions once: eliminates divisions in the render
    // hot path. Fully replaces the old setLayout() approach.
    function onLayout(dc as Dc) as Void {
        mWidth       = dc.getWidth();
        mHeight      = dc.getHeight();
        mCenterX     = mWidth  / 2;
        mCenterY     = mHeight / 2;
        mBandTopY    = mHeight / 8;        // center within the top quarter (<25%)
        mBandBottomY = mHeight * 7 / 8;    // center within the bottom quarter (>75%)
        mLineH       = mHeight / 10;       // vertical spacing for stacked text
    }

    // Starts the 1 Hz refresh. onShow is not a hot path: `new` is allowed here.
    function onShow() as Void {
        var t = new Timer.Timer();
        t.start(method(:onTimerTick), 1000, true);
        mTimer = t;
    }

    // Stops the timer when the view is hidden to avoid unnecessary battery drain.
    function onHide() as Void {
        var t = mTimer;
        if (t != null) {
            t.stop();
        }
    }

    // Timer callback: requests a repaint to advance partial timers.
    function onTimerTick() as Void {
        WatchUi.requestUpdate();
    }

    // Imperative render. Dispatches drawing based on the FSM state (if/else if).
    function onUpdate(dc as Dc) as Void {
        var app   = getApp();
        var state = app.mFsmState;

        // ── Paused (Phase 7) ────────────────────────────────────────────────────
        // Interrupts live-state rendering and draws the dimmed pause screen.
        // Guarantees visual freeze: the partial timer is shown stopped.
        if (app.mIsPaused) {
            drawPaused(dc, app);
            return;
        }

        // ── Background by state ────────────────────────────────────────────────
        // High contrast: white during STATE_RUN, black for all other states.
        var bg = Graphics.COLOR_BLACK;
        var fg = Graphics.COLOR_WHITE;
        if (state == STATE_RUN) {
            bg = Graphics.COLOR_WHITE;
            fg = Graphics.COLOR_BLACK;
        }
        dc.setColor(Graphics.COLOR_TRANSPARENT, bg);
        dc.clear();

        if (state == STATE_WARMUP) {
            drawWarmup(dc, app, fg);
        } else if (state == STATE_RUN) {
            drawRun(dc, app, fg);
        } else if (state == STATE_ROXZONE_IN || state == STATE_ROXZONE_OUT) {
            drawRoxzone(dc, app, fg);
        } else if (state == STATE_STATION) {
            drawStation(dc, app, fg);
        } else {
            drawFinish(dc, app, fg);
        }
    }

    // ── Pause screen (Phase 7) ──────────────────────────────────────────────────
    // Unmistakable dimmed background: "PAUSED" in large text, the paused state label,
    // the frozen partial timer, and the resume hint. FONT_LARGE (not FONT_NUMBER_*,
    // which only contains digits). The partial is frozen because stateElapsedMs()
    // locks the reference to mPauseStartMs while mIsPaused is true.
    private function drawPaused(dc as Dc, app as HyroxPacerApp) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_DK_GRAY);
        dc.clear();

        // Label showing which state is paused.
        var label = "STATION";
        var state = app.mFsmState;
        if (state == STATE_RUN) {
            label = "RUN  km " + (app.mHyroxCycle + 1).toString() + "/8";
        } else if (state == STATE_ROXZONE_IN || state == STATE_ROXZONE_OUT) {
            label = "ROXZONE";
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY, label,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // "PAUSED" in large, prominent text.
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY, Graphics.FONT_LARGE, "PAUSED",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Frozen partial timer for the current state.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY + mLineH * 2, Graphics.FONT_TINY,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Resume hint.
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "START > resume",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Per-state screens ────────────────────────────────────────────────────────

    // WARMUP: start screen. Goal time + distance, GPS status, and the button prompt.
    private function drawWarmup(dc as Dc, app as HyroxPacerApp, fg as Graphics.ColorType) as Void {
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY, "HYROX",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Goal time (large) + fixed distance (small, below).
        dc.drawText(mCenterX, mCenterY - mLineH, Graphics.FONT_NUMBER_MEDIUM,
                    formatClock(app.mTargetTimeMs),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mCenterX, mCenterY + mLineH, Graphics.FONT_TINY, "target · 8 km",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // GPS status: green if fix acquired, red if still searching.
        var gpsColor = Graphics.COLOR_RED;
        var gpsStr   = "Searching GPS";
        if (app.mGps.hasFix()) {
            gpsColor = Graphics.COLOR_GREEN;
            gpsStr   = "GPS OK";
        }
        dc.setColor(gpsColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY - mLineH, Graphics.FONT_TINY, gpsStr,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Start prompt.
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "START > begin",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // RUN: athlete's REAL pace (large, green/red vs. target) + reference target
    // (small) + current km + partial timer for this km.
    private function drawRun(dc as Dc, app as HyroxPacerApp, fg as Graphics.ColorType) as Void {
        var cycle = app.mHyroxCycle + 1;
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY,
                    "RUN  km " + cycle.toString() + "/8",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Real (smoothed) pace and the current dynamic target.
        var paceTarget = app.mDynamicPaceTargetSec;
        var avgSpeed   = app.mGps.getAvgSpeedMs();
        var realPace   = app.mPacing.computeCurrentPaceSec(avgSpeed);
        var delta      = app.mPacing.computePaceDeltaDeviation(avgSpeed, paceTarget);

        // Color of the real pace: green if at or ahead of target, red if falling behind.
        // Neutral (fg) while no valid pace is available (stopped / no target).
        var eqColor = fg;
        if (realPace > 0.0f && paceTarget > 0.0f) {
            eqColor = Graphics.COLOR_GREEN;
            if (delta > 0.0f) {
                eqColor = Graphics.COLOR_RED;
            }
        }
        dc.setColor(eqColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_HOT, formatPace(realPace),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Small reference target pace below the real pace.
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY + mLineH * 2, Graphics.FONT_TINY,
                    "tgt " + formatPace(paceTarget),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Partial timer for the current km segment.
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ROXZONE_IN / ROXZONE_OUT: transition corridor timer + button hint.
    private function drawRoxzone(dc as Dc, app as HyroxPacerApp, fg as Graphics.ColorType) as Void {
        var cycle = app.mHyroxCycle + 1;
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY,
                    "ROXZONE " + cycle.toString() + "/8",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_HOT,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "BACK > continue",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // STATION: station timer + active athlete (toggle with UP/DOWN in doubles mode).
    private function drawStation(dc as Dc, app as HyroxPacerApp, fg as Graphics.ColorType) as Void {
        var cycle = app.mHyroxCycle + 1;
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY,
                    "STATION " + cycle.toString() + "/8",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_HOT,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Active relay athlete, color-coded for quick identification.
        var athleteColor = Graphics.COLOR_BLUE;
        var athleteStr   = "Athlete A";
        if (!app.mActiveAthlete) {
            athleteColor = Graphics.COLOR_ORANGE;
            athleteStr   = "Athlete B";
        }
        dc.setColor(athleteColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, athleteStr,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // FINISH: race summary (total time + work/rest ratio) + exit hint.
    private function drawFinish(dc as Dc, app as HyroxPacerApp, fg as Graphics.ColorType) as Void {
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY, "FINISH",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_MEDIUM,
                    formatClock(app.mWorkMs + app.mRestMs),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.drawText(mCenterX, mBandBottomY - mLineH, Graphics.FONT_TINY,
                    "W/R " + formatRatio(app.mWorkMs, app.mRestMs),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "BACK > exit",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    // Elapsed time (ms) in the current state = ref - last transition - paused time.
    // Phase 7: while paused, the reference is frozen at mPauseStartMs (partial stops);
    // mPausedMs only grows on resume, so after resuming the partial continues from
    // where it stopped. Valid only outside WARMUP; clamp prevents negative values.
    private function stateElapsedMs(app as HyroxPacerApp) as Number {
        var ref = System.getTimer();
        if (app.mIsPaused) {
            ref = app.mPauseStartMs;
        }
        var elapsed = ref - app.mLastTransitionMs - app.mPausedMs;
        if (elapsed < 0) {
            elapsed = 0;
        }
        return elapsed;
    }

    // Formats a pace in s/km as "M:SS" (e.g. 300 → "5:00").
    // Returns "--:--" if the value is invalid (no active target).
    private function formatPace(sec as Float) as String {
        if (sec <= 0.0f) {
            return "--:--";
        }
        var totalSec = sec.toNumber();
        var mins     = totalSec / 60;
        var secs     = totalSec % 60;
        var secsStr  = secs.toString();
        if (secs < 10) {
            secsStr = "0" + secsStr;
        }
        return mins.toString() + ":" + secsStr;
    }

    // Formats a duration in ms as "M:SS" (minutes may exceed 60).
    private function formatClock(ms as Number) as String {
        var totalMs = ms;
        if (totalMs < 0) {
            totalMs = 0;
        }
        var totalSec = totalMs / 1000;
        var mins     = totalSec / 60;
        var secs     = totalSec % 60;
        var secsStr  = secs.toString();
        if (secs < 10) {
            secsStr = "0" + secsStr;
        }
        return mins.toString() + ":" + secsStr;
    }

    // Formats the work/rest ratio as "X.Y" (one decimal place).
    // Returns "--" if no rest time has been recorded yet (avoids division by zero).
    private function formatRatio(workMs as Number, restMs as Number) as String {
        if (restMs <= 0) {
            return "--";
        }
        var ratio10 = (workMs * 10) / restMs;  // integer division → tenths
        var whole   = ratio10 / 10;
        var frac    = ratio10 % 10;
        return whole.toString() + "." + frac.toString();
    }

}
