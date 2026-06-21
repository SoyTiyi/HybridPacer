import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// ─── HyroxPacerDelegate ───────────────────────────────────────────────────────
// InputDelegate principal de HyroxPacer.
//
// ARQUITECTURA DE BOTONES (fr965) — modelo Garmin-nativo:
//   onSelect()        → botón START/STOP (sup. der.). Solo en WARMUP arranca la
//                       carrera (WARMUP→RUN). Durante la carrera es no-op pero
//                       consume el evento (return true) para bloquear la pausa
//                       nativa de actividad.
//   onBack()          → botón BACK/LAP (inf. der.). Es el botón de "vuelta":
//                       en estados de carrera (RUN..ROXZONE_OUT) dispara la
//                       transición FSM. En WARMUP/FINISH retorna false → el
//                       runtime cierra la app (única vía de salida segura).
//   onPreviousPage()  → botón UP (sup. izq.).  En STATION alterna el atleta activo.
//   onNextPage()      → botón DOWN (inf. izq.). En STATION alterna el atleta activo.
//
// POR QUÉ SOLO CALLBACKS DE COMPORTAMIENTO (sin override de onKey()):
//   BehaviorDelegate.onKey() es el enrutador interno tecla→comportamiento.
//   Sobreescribir onKey() sin llamar a super ROMPE ese enrutamiento y deja sin
//   efecto onSelect()/onBack()/onNextPage()/onPreviousPage(). Por eso NO se
//   sobreescribe onKey(): se deja que BehaviorDelegate enrute las teclas físicas
//   a estos callbacks, que es el patrón documentado y fiable en el SDK 9.2.0.
//   (onStartSelect() NO existe en el SDK — por eso el botón START nunca respondía.)
//
// REGLAS: sin switch/case, sin new en rutas calientes, sin Dictionary de dominio.
class HyroxPacerDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    // ── BLOQUEO TÁCTIL ────────────────────────────────────────────────────────
    // El sudor y el movimiento en competición generan taps/swipes accidentales.

    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return true;
    }

    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        return true;
    }

    function onFlick(flickEvent as WatchUi.FlickEvent) as Boolean {
        return true;
    }

    // ── BOTÓN START/STOP (onSelect) ─────────────────────────────────────────────
    // Inicia la carrera desde WARMUP. Durante la carrera no avanza la FSM (esa es
    // función del botón BACK/LAP), pero consume el evento para que el sistema no
    // pause/detenga la actividad.
    function onSelect() as Boolean {
        var state = getApp().mFsmState;
        System.println("onSelect state: " + state.toString());
        if (state == STATE_WARMUP) {
            getApp().mFsm.attemptTransition();
        } else if (state >= STATE_RUN && state < STATE_FINISH) {
            // Fase 7: en estados de carrera, START/STOP alterna pausa/reanudar.
            getApp().togglePause();
        }
        return true;
    }

    // ── BOTÓN BACK/LAP (onBack) ─────────────────────────────────────────────────
    // Botón de "vuelta": avanza la FSM en cada transición durante la carrera.
    // En WARMUP/FINISH retorna false → el runtime cierra la app (salida segura).
    function onBack() as Boolean {
        var app   = getApp();
        var state = app.mFsmState;
        System.println("onBack state: " + state.toString());
        if (state >= STATE_RUN && state < STATE_FINISH) {
            // Fase 7: en pausa el avance de estado queda bloqueado; primero hay
            // que reanudar con START. Consume el evento para no salir de la app.
            if (app.mIsPaused) {
                return true;
            }
            app.mFsm.attemptTransition();
            return true;
        }
        return false;
    }

    // ── BOTONES UP / DOWN (onPreviousPage / onNextPage) ─────────────────────────
    // Alternan el atleta activo del relevo (modo dobles) cuando se está en STATION.
    function onPreviousPage() as Boolean {
        return toggleAthlete();
    }

    function onNextPage() as Boolean {
        return toggleAthlete();
    }

    // Invierte mActiveAthlete solo en STATE_STATION y refresca la vista.
    // Devuelve true si consumió el evento; false en cualquier otro estado.
    private function toggleAthlete() as Boolean {
        var app = getApp();
        // Fase 7: en pausa todo queda congelado, incluido el cambio de atleta.
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

    // ── MENÚ — CONFIGURACIÓN DE TIEMPO OBJETIVO (Fase 6) ───────────────────────
    // En fr965 se dispara con UP largo. Solo accesible en WARMUP: cambiar el
    // objetivo a mitad de carrera corrompería el pacing. Durante la carrera es
    // no-op (consume el evento). El menú persiste el valor en Storage.
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
