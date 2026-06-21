import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// ─── FSM State Constants ─────────────────────────────────────────────────────
// Secuencia inmutable: WARMUP → RUN → ROXZONE_IN → STATION → ROXZONE_OUT → FINISH
// Se usan como índice entero de Lang.Array en fases posteriores.
// PROHIBIDO switch/case: transiciones controladas por bloques if/else if.
const STATE_WARMUP      as Number = 0;
const STATE_RUN         as Number = 1;
const STATE_ROXZONE_IN  as Number = 2;
const STATE_STATION     as Number = 3;
const STATE_ROXZONE_OUT as Number = 4;
const STATE_FINISH      as Number = 5;

// Número total de ciclos Hyrox (8 carreras + 8 estaciones de trabajo)
const HYROX_TOTAL_CYCLES as Number = 8;

// Debounce inmutable entre transiciones de estado (ms) — aplicado en Fase 2
const FSM_DEBOUNCE_MS as Number = 5000;

// ─── Tiempo objetivo configurable (Fase 6) ───────────────────────────────────
// El usuario elige su objetivo global en WARMUP (presets cada 5 min). El valor
// persiste en Application.Storage como MINUTOS (Number) y se carga en initialize().
const TARGET_MIN_MINUTES     as Number = 40;          // Límite inferior válido (élite/entreno)
const TARGET_MAX_MINUTES     as Number = 180;         // Límite superior válido (principiante/scaled)
const TARGET_STEP_MINUTES    as Number = 5;           // Incremento entre presets
const TARGET_DEFAULT_MINUTES as Number = 90;          // Fallback si no hay valor guardado
const STORAGE_KEY_TARGET_MIN as String = "target_min"; // Clave de persistencia (minutos)

class HyroxPacerApp extends Application.AppBase {

    // ── Miembros de la FSM ─────────────────────────────────────────────────
    // Pre-asignados en initialize() para cumplir la regla de memoria:
    // cero asignaciones dinámicas fuera del arranque.
    var mFsmState        as Number = STATE_WARMUP;  // Estado inicial: calentamiento
    var mLastTransitionMs as Number = 0;             // Marca de tiempo de la última transición
                                                     // (base para debounce de 5000 ms en Fase 2)
    var mHyroxCycle      as Number = 0;              // Ciclo actual (0..7), usado por la UI en Fase 5
    var mActiveAthlete   as Boolean = true;          // dobles: atleta activo en el relevo (Fase 2)

    // ── Pausa/Reanudar (Fase 7) ────────────────────────────────────────────
    // NO es un estado FSM nuevo: la secuencia FSM es inmutable. Es un flag de App
    // que congela cronómetro, parciales y grabación FIT en estados de carrera.
    var mIsPaused     as Boolean = false; // true mientras la carrera está en pausa
    var mPauseStartMs as Number  = 0;     // System.getTimer() del inicio de la pausa actual
    var mPausedMs     as Number  = 0;     // ms en pausa acumulados DENTRO del estado actual;
                                          // se resetea a 0 en cada transición exitosa

    // ── Acumuladores de duración por estado ───────────────────────────────
    // Actualizados por FSMController.attemptTransition() en cada transición.
    // Solo sumas de Number (ms): cero asignaciones dinámicas.
    var mWorkMs         as Number = 0;   // Tiempo total en STATE_RUN (ms)
    var mRestMs         as Number = 0;   // Tiempo total en ROXZONE_IN+STATION+ROXZONE_OUT (ms)
    var mRoxzoneTotalMs as Number = 0;   // Tiempo total en ROXZONE_IN+ROXZONE_OUT (ms)

    // ── Objetivo de tiempo y salida del motor de pacing (Fase 4) ─────────
    var mTargetTimeMs         as Number = 5400000; // Objetivo global (ms). Se sobrescribe en initialize() desde Storage (Fase 6)
    var mTimeAthleteA         as Number = 0;       // Dobles: ms totales acumulados por el atleta A
    var mTimeAthleteB         as Number = 0;       // Dobles: ms totales acumulados por el atleta B
    var mDynamicPaceTargetSec as Float  = 0.0f;   // Ritmo objetivo dinámico (s/km) — leído por UI Fase 5

    // ── Gestor de GPS + grabación ──────────────────────────────────────────
    // Instancia única; el objeto se crea aquí y nunca se destruye mientras la app vive.
    var mGps as GpsSessionManager;

    // ── Controlador de la FSM ──────────────────────────────────────────────
    // Instancia única; única fuente de mutación del estado mFsmState.
    var mFsm as FSMController;

    // ── Motor de sesión FIT ────────────────────────────────────────────────
    // Posee los 7 handles FitContributor.Field; initializeFitFields() se invoca
    // desde GpsSessionManager.startRecording() al crear la sesión.
    var mFit as HyroxFitSession;

    // ── Motor de pacing predictivo (Fase 4) ───────────────────────────────
    // Calcula computeDynamicPaceTarget y computePaceDeltaDeviation.
    // Instancia única; sin estado propio (lee/escribe via getApp()).
    var mPacing as PacingEngine;

    function initialize() {
        AppBase.initialize();

        // Reserva la instancia del gestor. El SDK (Position + ActivityRecording)
        // NO se activa aquí; eso ocurre en onStart() cuando el runtime está listo.
        mGps    = new GpsSessionManager();
        mFsm    = new FSMController();
        mFit    = new HyroxFitSession();
        mPacing = new PacingEngine();

        // Carga el tiempo objetivo persistido (minutos) con fallback + clamp
        // defensivo. Patrón nullable del SDK: copia local + comprobación de tipo.
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

    // onStart() se invoca cuando la app está en primer plano y el sistema está listo.
    // Es el único lugar correcto para iniciar la grabación de actividad.
    function onStart(state as Dictionary?) as Void {
        mGps.start();
    }

    // onStop() se invoca al salir de la app (botón Atrás desde el nivel raíz o apagado).
    // Guarda la sesión FIT y desactiva el GPS para liberar recursos de radio.
    function onStop(state as Dictionary?) as Void {
        mGps.stop();
    }

    // ── togglePause() (Fase 7) ─────────────────────────────────────────────
    // Alterna pausa/reanudar SOLO en estados de carrera (RUN..ROXZONE_OUT).
    // Invocado desde HyroxPacerDelegate.onSelect() (botón START/STOP).
    // Cronometraje: al reanudar se acumula el tiempo en pausa de este estado en
    // mPausedMs; FSMController y la vista lo restan para que el parcial se congele
    // y continúe donde estaba (sin inflar acumuladores ni el total). FIT: stop()
    // pausa el timer, start() lo reanuda (misma sesión, save() diferido a FINISH).
    // Sin new, if/else (no switch).
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

    // Devuelve la vista inicial de la app.
    // HyroxPacerDelegate es el InputDelegate con FSM completo desde Fase 2.
    // HyroxPacerView es la vista imperativa de tres bandas (Fase 5).
    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new HyroxPacerView(), new HyroxPacerDelegate() ];
    }

}

// Función de acceso global al singleton de la app — necesaria para que vistas y
// delegados accedan a mFsmState, mGps, etc. sin instanciar nada nuevo.
function getApp() as HyroxPacerApp {
    return Application.getApp() as HyroxPacerApp;
}
