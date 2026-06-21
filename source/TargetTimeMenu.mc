import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.WatchUi;

// ─── Goal time menu (Phase 6) ─────────────────────────────────────────────────
// Menu2 list built imperatively (no layout.xml, no 29 items in XML):
// presets from TARGET_MIN_MINUTES to TARGET_MAX_MINUTES in steps of TARGET_STEP_MINUTES.
// Each item's identifier is the number of minutes (Number), retrievable via
// item.getId() in the delegate. Only invoked from onMenu() in WARMUP.

// Builds and returns the Menu2 focused on the currently selected preset.
// `new` is allowed here: called from a handler (onMenu), not a hot path.
function buildTargetTimeMenu(currentMinutes as Number) as WatchUi.Menu2 {
    var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.target_time_title) as String });

    for (var m = TARGET_MIN_MINUTES; m <= TARGET_MAX_MINUTES; m += TARGET_STEP_MINUTES) {
        menu.addItem(new WatchUi.MenuItem(m.toString() + " min", null, m, null));
    }

    // Focus on the currently configured value.
    var focusIndex = (currentMinutes - TARGET_MIN_MINUTES) / TARGET_STEP_MINUTES;
    if (focusIndex < 0) {
        focusIndex = 0;
    }
    menu.setFocus(focusIndex);

    return menu;
}

// Menu2 delegate: persists the selected preset and refreshes the WARMUP center band.
class TargetTimeMenuDelegate extends WatchUi.Menu2InputDelegate {

    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var minutes = item.getId();
        if (minutes instanceof Lang.Number) {
            var app = getApp();
            app.mTargetTimeMs = minutes * 60000;
            Storage.setValue(STORAGE_KEY_TARGET_MIN, minutes);
        }
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        WatchUi.requestUpdate(); // the WARMUP center band shows the new goal time
    }

}
