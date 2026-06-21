import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// ─── HyroxPacerDelegate ───────────────────────────────────────────────────────
// Main InputDelegate for HybridPacer.
//
// BUTTON ARCHITECTURE (fr965) — Garmin-native model:
//   onSelect()        → START/STOP button (upper right). In WARMUP starts the
//                       race (WARMUP→RUN). During a race, toggles pause/resume.
//                       Always returns true to block the system's native
//                       activity pause behavior.
//   onBack()          → BACK/LAP button (lower right). This is the "lap" button:
//                       in race states (RUN..ROXZONE_OUT) it triggers an FSM
//                       transition. In WARMUP/FINISH it returns false →
//                       the runtime closes the app (the only safe exit path).
//   onPreviousPage()  → UP button (upper left).  In STATION toggles the active athlete.
//   onNextPage()      → DOWN button (lower left). In STATION toggles the active athlete.
//
// WHY BEHAVIOR CALLBACKS ONLY (no onKey() override):
//   BehaviorDelegate.onKey() is the internal key-to-behavior router.
//   Overriding onKey() without calling super BREAKS that routing and silently
//   disables onSelect(), onBack(), onNextPage(), and onPreviousPage(). Therefore
//   onKey() is NOT overridden: BehaviorDelegate routes physical keys to these
//   callbacks, which is the documented and reliable pattern in SDK 9.2.0.
//   (onStartSelect() does NOT exist in the SDK — that was why START never responded.)
//
// RULES: no switch/case, no new in hot paths, no domain Dictionary.
class HyroxPacerDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    // ── TOUCH BLOCK ───────────────────────────────────────────────────────────
    // Sweat and movement during competition generate accidental taps/swipes.

    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return true;
    }

    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        return true;
    }

    function onFlick(flickEvent as WatchUi.FlickEvent) as Boolean {
        return true;
    }

    // ── START/STOP BUTTON (onSelect) ───────────────────────────────────────────
    // Starts the race from WARMUP. During the race it does not advance the FSM
    // (that is the BACK/LAP button's role), but consumes the event so the system
    // does not pause or stop the activity.
    function onSelect() as Boolean {
        var state = getApp().mFsmState;
        System.println("onSelect state: " + state.toString());
        if (state == STATE_WARMUP) {
            getApp().mFsm.attemptTransition();
        } else if (state >= STATE_RUN && state < STATE_FINISH) {
            // Phase 7: in race states, START/STOP toggles pause/resume.
            getApp().togglePause();
        }
        return true;
    }

    // ── BACK/LAP BUTTON (onBack) ───────────────────────────────────────────────
    // The "lap" button: advances the FSM on each race transition.
    // In WARMUP/FINISH returns false → the runtime closes the app (safe exit).
    function onBack() as Boolean {
        var app   = getApp();
        var state = app.mFsmState;
        System.println("onBack state: " + state.toString());
        if (state >= STATE_RUN && state < STATE_FINISH) {
            // Phase 7: while paused, state advance is blocked; the athlete must
            // resume with START first. Consume the event to avoid exiting the app.
            if (app.mIsPaused) {
                return true;
            }
            app.mFsm.attemptTransition();
            return true;
        }
        return false;
    }

    // ── UP / DOWN BUTTONS (onPreviousPage / onNextPage) ────────────────────────
    // Toggle the active relay athlete (doubles mode) when in STATION.
    function onPreviousPage() as Boolean {
        return toggleAthlete();
    }

    function onNextPage() as Boolean {
        return toggleAthlete();
    }

    // Flips mActiveAthlete only in STATE_STATION and refreshes the view.
    // Returns true if the event was consumed; false in any other state.
    private function toggleAthlete() as Boolean {
        var app = getApp();
        // Phase 7: everything is frozen while paused, including athlete toggle.
        if (app.mIsPaused) {
            return true;
        }
        if (app.mFsmState == STATE_STATION) {
            app.mActiveAthlete = !app.mActiveAthlete;
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    // ── MENU — GOAL TIME CONFIGURATION (Phase 6) ───────────────────────────────
    // On the fr965, triggered by a long press of UP. Only accessible in WARMUP:
    // changing the target mid-race would corrupt the pacing projection. During the
    // race this is a no-op (consumes the event). The menu persists the value to Storage.
    function onMenu() as Boolean {
        var app = getApp();
        if (app.mFsmState == STATE_WARMUP) {
            WatchUi.pushView(
                buildTargetTimeMenu(app.mTargetTimeMs / 60000),
                new TargetTimeMenuDelegate(),
                WatchUi.SLIDE_UP);
        }
        return true;
    }

}
