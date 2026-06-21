import Toybox.Lang;

// ─── PacingEngine ─────────────────────────────────────────────────────────────
// Motor de pacing predictivo — Core Value de HyroxPacer.
// Sin estado propio: lee mRestMs y mHyroxCycle del singleton via getApp().
// Instancia única creada en HyroxPacerApp.initialize() como mPacing.
//
// El recálculo del ritmo objetivo se dispara SOLO al entrar a STATE_RUN
// (en la transición, nunca en el tick 1Hz). Aritmética escalar pura: < 1 ms.
//
// REGLAS DE MEMORIA:
//   - Sin `new` en ningún método (cero asignaciones dinámicas en rutas calientes).
//   - Sin Lang.Dictionary como estructura de dominio.
//   - Sin switch/case: ramas con if/else if.
//   - Sin Toybox.Math: solo división y multiplicación de primitivos.

// Distancia fija de carrera Hyrox: 8 km de RUN (1 km por ciclo × 8 ciclos).
const HYROX_TOTAL_KM as Float = 8.0f;

class PacingEngine {

    function initialize() {
        // Sin estado propio. Todos los parámetros de carrera viven en getApp().
    }

    // ── computeDynamicPaceTarget ──────────────────────────────────────────────
    // Calcula el ritmo objetivo dinámico (s/km) para el próximo km de carrera.
    // Invocado por FSMController.attemptTransition() al entrar a STATE_RUN:
    //   - WARMUP → RUN: primer km, sin histórico de descanso.
    //   - ROXZONE_OUT → RUN: km naciente, con penalización proyectada.
    //
    // Parámetros:
    //   targetTimeMs       — objetivo global de tiempo de carrera (ms).
    //   elapsedTotalMs     — tiempo ya comprometido = mWorkMs + mRestMs (ms).
    //   distanceCompletedKm— kilómetros ya recorridos = mHyroxCycle.
    //
    // Algoritmo (aritmética entera/flotante, sin Math):
    //   1. distanceRemainingKm = 8.0 - distanceCompletedKm.
    //   2. avgRestMs = mRestMs / ciclosDone → promedio de descanso por ciclo.
    //   3. projectedRestMs = avgRestMs × ciclosRestantes → penalización futura.
    //   4. runTimeRemainingMs = targetTimeMs − elapsedTotalMs − projectedRestMs.
    //   5. return runTimeRemainingMs (ms) / 1000 / distanceRemainingKm (→ s/km).
    //
    // Retorna 0.0f si la carrera terminó o el atleta está fuera del plan
    // (la UI de Fase 5 pintará el resultado en rojo cuando sea 0.0f).
    function computeDynamicPaceTarget(targetTimeMs as Number, elapsedTotalMs as Number, distanceCompletedKm as Number) as Float {

        // 1. Distancia restante (km)
        var distanceRemainingKm = HYROX_TOTAL_KM - distanceCompletedKm.toFloat();
        if (distanceRemainingKm <= 0.0f) {
            return 0.0f;  // Carrera terminada o distancia superada
        }

        // 2. Proyección de penalización futura basada en promedio histórico de descanso
        var app        = getApp();
        var cyclesDone = app.mHyroxCycle;  // Ciclos completados (= km recorridos)
        var avgRestMs  = 0;
        if (cyclesDone > 0) {
            avgRestMs = app.mRestMs / cyclesDone;  // Div entera: ms promedio de pausa por ciclo
        }
        var cyclesRemaining = HYROX_TOTAL_CYCLES - cyclesDone;
        var projectedRestMs = avgRestMs * cyclesRemaining;  // Penalización logística futura (ms)

        // 3. Tiempo disponible exclusivamente para correr (ms)
        var runTimeRemainingMs = targetTimeMs - elapsedTotalMs - projectedRestMs;
        if (runTimeRemainingMs <= 0) {
            return 0.0f;  // Fuera del plan temporal — UI pintará en rojo (Fase 5)
        }

        // 4. Ritmo objetivo dinámico (s/km): tiempo de carrera restante / distancia restante
        return (runTimeRemainingMs / 1000.0f) / distanceRemainingKm;
    }

    // ── computePaceDeltaDeviation ─────────────────────────────────────────────
    // Calcula la desviación del pace instantáneo respecto al objetivo dinámico.
    //   Positivo → el atleta va más lento que el objetivo (en déficit).
    //   Negativo → el atleta va más rápido (margen de ventaja).
    //   0.0f    → velocidad insuficiente (parado, transición, o arranque).
    //
    // Parámetros:
    //   currentSpeedMps     — velocidad GPS actual (m/s), de getApp().mGps.getSpeedMs().
    //   paceTargetSecPerKm  — objetivo dinámico vigente (s/km), de mDynamicPaceTargetSec.
    //
    // Guard estricto contra división por cero: solo calcula si speed > PACE_MIN_SPEED.
    function computePaceDeltaDeviation(currentSpeedMps as Float, paceTargetSecPerKm as Float) as Float {
        if (currentSpeedMps > PACE_MIN_SPEED) {
            var paceNow = 1000.0f / currentSpeedMps;  // m/s → s/km
            return paceNow - paceTargetSecPerKm;       // δ respecto al objetivo dinámico
        }
        return 0.0f;
    }

    // ── computeCurrentPaceSec ─────────────────────────────────────────────────
    // Convierte una velocidad (m/s) en ritmo real (s/km) para mostrar al atleta.
    // Pásale la velocidad suavizada (getAvgSpeedMs) para evitar saltos nerviosos.
    // Retorna 0.0f si la velocidad es insuficiente (parado / sin fix) → la UI lo
    // pintará como "--:--".
    function computeCurrentPaceSec(currentSpeedMps as Float) as Float {
        if (currentSpeedMps > PACE_MIN_SPEED) {
            return 1000.0f / currentSpeedMps;  // m/s → s/km
        }
        return 0.0f;
    }

}
