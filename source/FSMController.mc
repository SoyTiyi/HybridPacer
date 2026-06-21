import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// ─── FSMController ────────────────────────────────────────────────────────────
// Motor de mutación de la FSM Hyrox. Instancia única creada en App.initialize().
// Única fuente de mutación de:
//   mFsmState, mHyroxCycle, mLastTransitionMs,
//   mWorkMs, mRestMs, mRoxzoneTotalMs.
//
// REGLAS DE MEMORIA (críticas):
//   - Sin `new` en ningún método (cero asignaciones dinámicas en rutas calientes).
//   - Sin Lang.Dictionary como estructura de dominio.
//   - Sin switch/case: transiciones controladas por bloques if/else if.
//
// El estado real vive en el singleton HyroxPacerApp (accesible via getApp()).
// FSMController solo contiene la lógica de mutación, sin estado propio.
class FSMController {

    function initialize() {
        // Sin estado propio: la FSM vive en el singleton de la app (getApp()).
        // Nada que inicializar aquí; los miembros del App ya están pre-asignados.
    }

    // ── attemptTransition() ───────────────────────────────────────────────────
    // Intento de transición disparado por KEY_LAP / KEY_BACK desde el delegate.
    // Aplica debounce, contabiliza duraciones por estado, gestiona el ciclo de
    // vida de la grabación FIT y marca los splits en los límites correctos.
    // Si el evento entra en la ventana de 5000 ms, se descarta silenciosamente.
    function attemptTransition() as Void {
        var app   = getApp();
        var state = app.mFsmState;

        // STATE_FINISH(5) es terminal: no hay más transiciones posibles.
        if (state >= STATE_FINISH) {
            return;
        }

        // ── DEBOUNCE 5000 ms (candado temporal inmutable) ──────────────────
        // Descarta silenciosamente cualquier evento dentro de la ventana.
        var now = System.getTimer();
        if (now - app.mLastTransitionMs < FSM_DEBOUNCE_MS) {
            return;
        }

        // ── Contabilidad de duración del estado que se abandona ────────────
        // WARMUP no se contabiliza: es tiempo pre-carrera y mLastTransitionMs = 0.
        // Para los demás estados, elapsed = ms reales en ese estado.
        if (state != STATE_WARMUP) {
            // Resta el tiempo en pausa de este estado (Fase 7): el tiempo congelado
            // nunca entra en los acumuladores ni en el tiempo de atleta.
            var elapsed = now - app.mLastTransitionMs - app.mPausedMs;
            if (state == STATE_RUN) {
                // Tiempo de carrera → acumulador de trabajo.
                app.mWorkMs = app.mWorkMs + elapsed;
            } else if (state == STATE_ROXZONE_IN || state == STATE_ROXZONE_OUT) {
                // Tiempo en RoxZone → acumulador de descanso y acumulador Roxzone.
                app.mRestMs = app.mRestMs + elapsed;
                app.mRoxzoneTotalMs = app.mRoxzoneTotalMs + elapsed;
            } else if (state == STATE_STATION) {
                // Tiempo en estación de trabajo → acumulador de descanso.
                app.mRestMs = app.mRestMs + elapsed;
            }
            // Suma el elapsed al atleta activo en el relevo (modo dobles).
            accrueAthleteTime(app, elapsed);
        }

        // ── Lógica de transición (if/else if — PROHIBIDO switch/case) ──────
        if (state == STATE_ROXZONE_OUT) {        // 4 → (1 | 5)
            // Incrementa el ciclo maestro ANTES de evaluar si la carrera terminó.
            app.mHyroxCycle = app.mHyroxCycle + 1;

            if (app.mHyroxCycle >= HYROX_TOTAL_CYCLES) {
                // Los 8 ciclos completados: detiene y guarda la sesión FIT.
                app.mGps.stopRecording();
                app.mFsmState = STATE_FINISH;
            } else {
                // Nuevo ciclo: inserta split FIT y vuelve a RUN.
                markLap();
                app.mFsmState = STATE_RUN;
                // Recalcula el ritmo objetivo para el km naciente.
                // En este punto: mHyroxCycle ya incrementado, mRestMs ya actualizado con el
                // elapsed del ROXZONE_OUT, mWorkMs acumulado hasta el fin del último RUN.
                app.mDynamicPaceTargetSec = app.mPacing.computeDynamicPaceTarget(
                    app.mTargetTimeMs,
                    app.mWorkMs + app.mRestMs,
                    app.mHyroxCycle);
            }
        } else {
            // Incremento lineal: 0→1, 1→2, 2→3, 3→4.
            if (state == STATE_WARMUP) {
                // WARMUP→RUN: primer LAP del atleta → arranca la grabación FIT.
                app.mGps.startRecording();
            }
            if (state == STATE_RUN) {
                // RUN→ROXZONE_IN: entrada en zona de transición → split.
                markLap();
            }
            app.mFsmState = state + 1;
            // Al entrar al primer RUN (WARMUP→RUN), calcula el ritmo objetivo inicial.
            // elapsedTotalMs = 0 (sin tiempo comprometido aún), distanceCompleted = 0.
            // Resultado: targetTimeMs / 8 km → 675 s/km para un objetivo de 90 min.
            if (state == STATE_WARMUP) {
                app.mDynamicPaceTargetSec = app.mPacing.computeDynamicPaceTarget(
                    app.mTargetTimeMs,
                    app.mWorkMs + app.mRestMs,
                    app.mHyroxCycle);
            }
        }

        // Sella el candado temporal con el instante de esta transición exitosa.
        app.mLastTransitionMs = now;
        // Reinicia el acumulador de pausa: mPausedMs es por estado (Fase 7).
        app.mPausedMs = 0;
        // Refresca la vista para reflejar el nuevo estado FSM inmediatamente.
        WatchUi.requestUpdate();
    }

    // ── markLap() ─────────────────────────────────────────────────────────────
    // Inserta un split nativo en el archivo FIT.
    // Invocado en los dos límites que generan un split visible en Garmin Connect:
    //   - RUN(1) → ROXZONE_IN(2): el atleta abandona la carrera y entra en RoxZone.
    //   - ROXZONE_OUT(4) → RUN(1): el atleta completa la estación y vuelve a correr.
    private function markLap() as Void {
        getApp().mGps.addLap();
    }

    // ── accrueAthleteTime() ───────────────────────────────────────────────────
    // Suma el tiempo transcurrido (ms) al acumulador del atleta activo en el
    // modo dobles. mActiveAthlete = true → atleta A; false → atleta B.
    // Permite calcular el Work/Rest Ratio individual al finalizar la carrera.
    // Solo se invoca desde la contabilidad de duración (state != STATE_WARMUP).
    private function accrueAthleteTime(app as HyroxPacerApp, elapsed as Number) as Void {
        if (app.mActiveAthlete) {
            app.mTimeAthleteA = app.mTimeAthleteA + elapsed;
        } else {
            app.mTimeAthleteB = app.mTimeAthleteB + elapsed;
        }
    }

}
