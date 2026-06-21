import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.WatchUi;

// ─── Menú de tiempo objetivo (Fase 6) ────────────────────────────────────────
// Lista Menu2 construida imperativamente (sin layout.xml ni 29 items en XML):
// presets de TARGET_MIN_MINUTES a TARGET_MAX_MINUTES en pasos de TARGET_STEP_MINUTES.
// El identificador de cada item es el número de minutos (Number), recuperable con
// item.getId() en el delegate. Solo se invoca desde onMenu() en WARMUP.

// Construye y devuelve el Menu2 con foco en el preset actual.
// `new` permitido: lo invoca un handler (onMenu), no una ruta caliente.
function buildTargetTimeMenu(currentMinutes as Number) as WatchUi.Menu2 {
    var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.target_time_title) as String });

    for (var m = TARGET_MIN_MINUTES; m <= TARGET_MAX_MINUTES; m += TARGET_STEP_MINUTES) {
        menu.addItem(new WatchUi.MenuItem(m.toString() + " min", null, m, null));
    }

    // Foco en el valor actualmente configurado.
    var focusIndex = (currentMinutes - TARGET_MIN_MINUTES) / TARGET_STEP_MINUTES;
    if (focusIndex < 0) {
        focusIndex = 0;
    }
    menu.setFocus(focusIndex);

    return menu;
}

// Delegate del Menu2: persiste el preset elegido y refresca la banda WARMUP.
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
        WatchUi.requestUpdate(); // la banda central de WARMUP muestra el nuevo objetivo
    }

}
