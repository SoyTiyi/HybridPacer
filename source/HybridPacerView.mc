import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.UserProfile;
import Toybox.WatchUi;

// ─── HybridPacerView ────────────────────────────────────────────────────────────
// High-contrast imperative view for HybridPacer.
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
class HybridPacerView extends WatchUi.View {

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

    // STATION catalog (Phase 10): name + universal official standard, indexed by
    // mRaceCycle (0..7). Loaded once from resources in onLayout (not a hot path)
    // so drawStation() only indexes these arrays. Array-indexed, never a Dictionary.
    var mStationNames as Array<String> = [];
    var mStationStds  as Array<String> = [];
    var mLabelStation as String = "STATION";
    var mLabelTotal   as String = "TOTAL";

    // Cached running HR zone boundaries from the user profile (null when unset).
    // Read once in onLayout to avoid allocating an array each render tick.
    var mHrZones as Array<Number>? = null;

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

        loadStationCatalog();

        // HR zones for the running sport (z1..z5 boundaries). May be null/empty
        // if the user has not configured zones; drawStation falls back to plain bpm.
        mHrZones = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_RUNNING);
    }

    // Builds the STATION name/standard arrays once from string resources, indexed
    // by mRaceCycle (fixed race order). Resource loads are confined to this
    // non-hot path; the render only indexes the cached arrays.
    private function loadStationCatalog() as Void {
        mLabelStation = WatchUi.loadResource(Rez.Strings.labelStation) as String;
        mLabelTotal   = WatchUi.loadResource(Rez.Strings.labelTotal) as String;
        mStationNames = [
            WatchUi.loadResource(Rez.Strings.stationSkiErg) as String,
            WatchUi.loadResource(Rez.Strings.stationSledPush) as String,
            WatchUi.loadResource(Rez.Strings.stationSledPull) as String,
            WatchUi.loadResource(Rez.Strings.stationBurpee) as String,
            WatchUi.loadResource(Rez.Strings.stationRow) as String,
            WatchUi.loadResource(Rez.Strings.stationFarmers) as String,
            WatchUi.loadResource(Rez.Strings.stationLunges) as String,
            WatchUi.loadResource(Rez.Strings.stationWallBalls) as String
        ];
        mStationStds = [
            WatchUi.loadResource(Rez.Strings.stationStdSkiErg) as String,
            WatchUi.loadResource(Rez.Strings.stationStdSledPush) as String,
            WatchUi.loadResource(Rez.Strings.stationStdSledPull) as String,
            WatchUi.loadResource(Rez.Strings.stationStdBurpee) as String,
            WatchUi.loadResource(Rez.Strings.stationStdRow) as String,
            WatchUi.loadResource(Rez.Strings.stationStdFarmers) as String,
            WatchUi.loadResource(Rez.Strings.stationStdLunges) as String,
            WatchUi.loadResource(Rez.Strings.stationStdWallBalls) as String
        ];
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
        } else if (state == STATE_TRANSITION_IN || state == STATE_TRANSITION_OUT) {
            drawTransition(dc, app, fg);
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
    private function drawPaused(dc as Dc, app as HybridPacerApp) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_DK_GRAY);
        dc.clear();

        // Label showing which state is paused.
        var label = "STATION";
        var state = app.mFsmState;
        if (state == STATE_RUN) {
            label = "RUN  km " + (app.mRaceCycle + 1).toString() + "/8";
        } else if (state == STATE_TRANSITION_IN || state == STATE_TRANSITION_OUT) {
            label = "TRANSITION";
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

    // WARMUP: start screen. The goal time is editable in place (UP +5 / DOWN -5),
    // so it is rendered in cyan with bracket framing to read as adjustable. A
    // transient yellow badge shows the last step (e.g. "+15") right after a press.
    // Header carries HYBRID + GPS status; the footer carries the UP/DOWN + START hints.
    private function drawWarmup(dc as Dc, app as HybridPacerApp, fg as Graphics.ColorType) as Void {
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY, "HYBRID",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // GPS status moved up to the header band: green if fix acquired, red if searching.
        var gpsColor = Graphics.COLOR_RED;
        var gpsStr   = "Searching GPS";
        if (app.mGps.hasFix()) {
            gpsColor = Graphics.COLOR_GREEN;
            gpsStr   = "GPS OK";
        }
        dc.setColor(gpsColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY + mLineH, Graphics.FONT_TINY, gpsStr,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Editable goal time (large, cyan) flanked by brackets. The brackets are a
        // separate text font because FONT_NUMBER_* only contains digits and the colon.
        var clock = formatClock(app.mTargetTimeMs);
        var numW  = dc.getTextWidthInPixels(clock, Graphics.FONT_NUMBER_MEDIUM);
        var bx    = numW / 2 + mLineH / 3;
        dc.setColor(0x00FFFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY - mLineH, Graphics.FONT_NUMBER_MEDIUM, clock,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mCenterX - bx, mCenterY - mLineH, Graphics.FONT_SMALL, "[",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mCenterX + bx, mCenterY - mLineH, Graphics.FONT_SMALL, "]",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Below the number: transient step badge right after a press, else the label.
        var sinceAdjust = System.getTimer() - app.mTargetAdjustAtMs;
        if (sinceAdjust >= 0 && sinceAdjust < TARGET_BADGE_MS) {
            var delta = app.mTargetLastDeltaMin;
            var sign  = "+";
            if (delta < 0) {
                sign = "-";
            }
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(mCenterX, mCenterY + mLineH, Graphics.FONT_TINY,
                        sign + delta.abs().toString() + " min",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            dc.drawText(mCenterX, mCenterY + mLineH, Graphics.FONT_TINY, "target · 8 km",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // Footer: UP/DOWN edit hint (cyan, ties to the editable number) + START prompt.
        dc.setColor(0x00FFFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY - mLineH, Graphics.FONT_TINY, "UP +5     DOWN -5",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "START > begin",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // RUN: redesigned race screen. Information architecture by band:
    //   HEADER  — race-level context: current km, total race time, projected
    //             finish vs. goal (green ahead / red behind).
    //   CENTER  — pacing performance: real pace (large, green/red vs. dynamic
    //             target) + pace delta as TIME + goal-pace reference. When GPS
    //             speed is not yet valid, heart rate (or the km split) is
    //             promoted here so the screen is never empty (first ~200 m).
    //   FOOTER  — current-km telemetry: heart rate, km split, meters remaining.
    // Every value comes from a real source; missing sources render "--" only.
    private function drawRun(dc as Dc, app as HybridPacerApp, fg as Graphics.ColorType) as Void {
        // ── Gather real data (no placeholders) ──────────────────────────────
        var cycle      = app.mRaceCycle + 1;
        var paceTarget = app.mDynamicPaceTargetSec;
        var avgSpeed   = app.mGps.getAvgSpeedMs();
        var realPace   = app.mPacing.computeCurrentPaceSec(avgSpeed);
        var delta      = app.mPacing.computePaceDeltaDeviation(avgSpeed, paceTarget);
        var hr         = readHeartRate();
        var metersLeft = kmMetersLeft(app);
        var partialMs  = stateElapsedMs(app);
        var committed  = app.mWorkMs + app.mRestMs;

        // ── Header L1: current running kilometer ────────────────────────────
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY,
                    "KM " + cycle.toString() + "/8",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // ── Header L2: total race time (left) + projected finish vs goal ────
        var headerY = mBandTopY + mLineH;
        var gap     = mWidth / 16;
        dc.drawText(mCenterX - gap, headerY, Graphics.FONT_TINY,
                    formatClock(committed + partialMs),
                    Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        var projFinish = app.mPacing.computeProjectedFinishMs(committed, app.mRaceCycle, realPace);
        if (projFinish >= 0) {
            var projDelta = projFinish - app.mTargetTimeMs;
            var projColor = Graphics.COLOR_GREEN;   // on or ahead of goal
            if (projDelta > 0) {
                projColor = Graphics.COLOR_RED;       // behind goal
            }
            dc.setColor(projColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(mCenterX + gap, headerY, Graphics.FONT_TINY,
                        formatSignedClock(projDelta),
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            dc.drawText(mCenterX + gap, headerY, Graphics.FONT_TINY, "--:--",
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // ── Center: pacing performance, or HR fallback when no GPS speed ────
        if (realPace > 0.0f) {
            // Real pace as the primary metric: green on/ahead of target, red behind.
            var eqColor = fg;
            if (paceTarget > 0.0f) {
                eqColor = Graphics.COLOR_GREEN;
                if (delta > 0.0f) {
                    eqColor = Graphics.COLOR_RED;
                }
            }
            dc.setColor(eqColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_HOT, formatPace(realPace),
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Pace delta as TIME + goal-pace reference (clear label, no cryptic "tgt").
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            dc.drawText(mCenterX, mCenterY + mLineH * 2, Graphics.FONT_TINY,
                        formatDelta(delta) + "   goal " + formatPace(paceTarget),
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            // No-signal fallback: show a real value that is NOT already on screen
            // (the km split lives in the footer, the total in the header), so the
            // center never duplicates them. Priority: HR → goal pace → "--:--".
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            var centerStr = "--:--";
            var subStr    = "acquiring GPS";
            if (hr != null) {
                centerStr = "HR " + hr.toString();
            } else if (paceTarget > 0.0f) {
                centerStr = formatPace(paceTarget);
                subStr    = "goal pace";
            }
            dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_HOT, centerStr,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(mCenterX, mCenterY + mLineH * 2, Graphics.FONT_TINY, subStr,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        // ── Footer: current-km telemetry (insets keep text off the round edge) ─
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        var rowY  = mBandBottomY - mLineH;
        var hrStr = "HR --";
        if (hr != null) {
            hrStr = "HR " + hr.toString();
        }
        dc.drawText(mWidth / 6, rowY, Graphics.FONT_TINY, hrStr,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        var distStr = "-- m";
        if (metersLeft >= 0) {
            distStr = metersLeft.toString() + " m";
        }
        dc.drawText(mWidth * 5 / 6, rowY, Graphics.FONT_TINY, distStr,
                    Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        // Current km split, centered at the bottom.
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, formatClock(partialMs),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // TRANSITION_IN / TRANSITION_OUT: transition corridor timer + button hint.
    private function drawTransition(dc as Dc, app as HybridPacerApp, fg as Graphics.ColorType) as Void {
        var cycle = app.mRaceCycle + 1;
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY,
                    "TRANSITION " + cycle.toString() + "/8",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_HOT,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "BACK > continue",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // STATION: tells the athlete WHAT station it is and its official standard, with
    // the station timer as the primary metric, plus HR/zone (effort & recovery) and
    // the live total race time (continuity with RUN). The active-athlete row only
    // appears in doubles, inferred from the relay toggle (no division/format config).
    private function drawStation(dc as Dc, app as HybridPacerApp, fg as Graphics.ColorType) as Void {
        // Safe catalog index: mRaceCycle is 0..7 in STATION, but clamp defensively.
        var idx = app.mRaceCycle;
        if (idx < 0) {
            idx = 0;
        } else if (idx > 7) {
            idx = 7;
        }

        // ── Header L1: station number (cyan accent, matches the RUN km header) ──
        dc.setColor(0x00FFFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY,
                    mLabelStation + " " + (idx + 1).toString() + "/8",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // ── Header L2: station name (what the athlete is doing right now) ──────
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY + mLineH, Graphics.FONT_TINY, mStationNames[idx],
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // ── Center: station timer (primary) + official standard as reference ──
        dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_HOT,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mCenterX, mCenterY + mLineH * 2, Graphics.FONT_TINY, mStationStds[idx],
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // ── Footer row: HR + zone (left), live total race time (right) ────────
        var rowY = mBandBottomY - mLineH;
        var hr   = readHeartRate();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        if (hr != null) {
            // "HR 162" in white, then a color-coded zone token for effort/recovery.
            var hrStr = "HR " + hr.toString();
            dc.drawText(mWidth / 6, rowY, Graphics.FONT_TINY, hrStr,
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            var zone = hrZoneFor(hr);
            if (zone > 0) {
                dc.setColor(zoneColor(zone), Graphics.COLOR_TRANSPARENT);
                dc.drawText(mWidth / 6 + dc.getTextWidthInPixels(hrStr + " ", Graphics.FONT_TINY),
                            rowY, Graphics.FONT_TINY, "Z" + zone.toString(),
                            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        } else {
            dc.drawText(mWidth / 6, rowY, Graphics.FONT_TINY, "HR --",
                        Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        var totalMs = app.mWorkMs + app.mRestMs + stateElapsedMs(app);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mWidth * 5 / 6, rowY, Graphics.FONT_TINY,
                    mLabelTotal + " " + formatClock(totalMs),
                    Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        // ── Footer center: active relay athlete, shown only in doubles ────────
        // Doubles is inferred from relay usage: B is active now, or B already ran.
        if (!app.mActiveAthlete || app.mTimeAthleteB > 0) {
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
    }

    // FINISH: race summary (total time + work/rest ratio) + exit hint.
    private function drawFinish(dc as Dc, app as HybridPacerApp, fg as Graphics.ColorType) as Void {
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
    private function stateElapsedMs(app as HybridPacerApp) as Number {
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

    // Reads the current heart rate (bpm) from Activity.Info. Available to a
    // watch-app while an ActivityRecording session is active (fr965 optical HR);
    // null-guarded per typecheck=3. Returns null when not yet available.
    private function readHeartRate() as Number? {
        var info = Activity.getActivityInfo();
        if (info != null && info has :currentHeartRate) {
            var bpm = info.currentHeartRate;
            if (bpm != null) {
                return bpm;
            }
        }
        return null;
    }

    // Maps a heart rate (bpm) to its running zone (1..5) using the cached profile
    // boundaries, or 0 when zones are unavailable or the HR is below zone 1.
    // typecheck=3: copy the nullable member to a local and null-check before use.
    private function hrZoneFor(bpm as Number) as Number {
        var zones = mHrZones;
        if (zones == null) {
            return 0;
        }
        var n = zones.size();
        if (n < 2 || bpm < zones[0]) {
            return 0;
        }
        var zone = 0;
        var i = 0;
        while (i < n - 1) {
            if (bpm >= zones[i]) {
                zone = i + 1;
            }
            i = i + 1;
        }
        return zone;
    }

    // Effort color for a zone token, legible on black: 1-2 green (easy/recovery),
    // 3 white (steady), 4 orange (hard), 5 red (max).
    private function zoneColor(zone as Number) as Graphics.ColorType {
        if (zone >= 5) {
            return Graphics.COLOR_RED;
        } else if (zone == 4) {
            return Graphics.COLOR_ORANGE;
        } else if (zone == 3) {
            return Graphics.COLOR_WHITE;
        }
        return Graphics.COLOR_GREEN;
    }

    // Meters remaining in the current km, from the recorded cumulative distance
    // (Activity.elapsedDistance) minus the per-km baseline captured at RUN entry.
    // Clamped to 0..1000. Returns -1 when distance is not yet available.
    private function kmMetersLeft(app as HybridPacerApp) as Number {
        var info = Activity.getActivityInfo();
        if (info != null && info has :elapsedDistance) {
            var dist = info.elapsedDistance;
            if (dist != null) {
                var into = dist - app.mRunBaselineDistanceM;  // m into current km
                var left = 1000 - into.toNumber();
                if (left < 0) {
                    left = 0;
                }
                if (left > 1000) {
                    left = 1000;
                }
                return left;
            }
        }
        return -1;
    }

    // Formats a pace deviation (s/km) as signed seconds, e.g. "+7s" / "-5s".
    // Positive = slower than target, negative = faster.
    private function formatDelta(secPerKm as Float) as String {
        var n = secPerKm.toNumber();
        if (n >= 0) {
            return "+" + n.toString() + "s";
        }
        return n.toString() + "s";  // negative value already carries the '-'
    }

    // Formats a signed duration (ms) as "+M:SS" / "-M:SS" for the finish projection.
    private function formatSignedClock(ms as Number) as String {
        var sign = "+";
        var v    = ms;
        if (v < 0) {
            sign = "-";
            v    = -v;
        }
        var totalSec = v / 1000;
        var mins     = totalSec / 60;
        var secs     = totalSec % 60;
        var secsStr  = secs.toString();
        if (secs < 10) {
            secsStr = "0" + secsStr;
        }
        return sign + mins.toString() + ":" + secsStr;
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
