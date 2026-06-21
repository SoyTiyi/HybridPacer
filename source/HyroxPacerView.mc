import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// ─── HyroxPacerView ────────────────────────────────────────────────────────────
// Vista imperativa de alto contraste para Hyrox Pacer.
// Dibuja EXCLUSIVAMENTE con primitivas del Dc (prohibido layout.xml).
// Estructura de tres bandas cuyo CONTENIDO depende del estado FSM:
//   CABECERA   (y < 25%):  estado + ciclo ("RUN  km 4/8", "STATION 4/8", ...)
//   ECUATORIAL (centro):   dato principal del estado (ritmo objetivo o timer)
//   INFERIOR   (y > 75%):  dato secundario / hint de botón / atleta activo
//
// REFRESCO 1 Hz: además de las actualizaciones disparadas por onPosition (~1Hz)
// y por las transiciones FSM, un Timer propio fuerza requestUpdate() cada 1000 ms
// para que los parciales de tiempo avancen aunque el GPS no reporte movimiento.
//
// REGLAS DE MEMORIA (críticas):
//   - Sin new en onUpdate (ruta caliente a ~1Hz). El new del Timer vive en onShow.
//   - Dimensiones pre-asignadas en onLayout().
//   - Sin switch/case: despacho de estado con if/else if sobre mFsmState.
class HyroxPacerView extends WatchUi.View {

    // Dimensiones pre-asignadas para evitar cálculos repetidos en onUpdate().
    var mWidth        as Number = 0;
    var mHeight       as Number = 0;
    var mCenterX      as Number = 0;
    var mCenterY      as Number = 0;
    var mBandTopY     as Number = 0;   // centro de la banda cabecera (~12.5% de alto)
    var mBandBottomY  as Number = 0;   // centro de la banda inferior (~87.5% de alto)
    var mLineH        as Number = 0;   // alto de línea aproximado para apilar texto

    // Timer de refresco 1 Hz. Nullable: creado en onShow(), liberado en onHide().
    var mTimer as Timer.Timer? = null;

    function initialize() {
        View.initialize();
    }

    // Pre-calcula dimensiones de pantalla una vez: elimina divisiones en la
    // ruta caliente de render. Sustituye completamente al antiguo setLayout().
    function onLayout(dc as Dc) as Void {
        mWidth       = dc.getWidth();
        mHeight      = dc.getHeight();
        mCenterX     = mWidth  / 2;
        mCenterY     = mHeight / 2;
        mBandTopY    = mHeight / 8;        // centro dentro del cuarto superior (<25%)
        mBandBottomY = mHeight * 7 / 8;    // centro dentro del cuarto inferior (>75%)
        mLineH       = mHeight / 10;       // separación vertical para texto apilado
    }

    // Arranca el refresco 1 Hz. onShow no es ruta caliente: el `new` está permitido.
    function onShow() as Void {
        var t = new Timer.Timer();
        t.start(method(:onTimerTick), 1000, true);
        mTimer = t;
    }

    // Detiene el timer al ocultar la vista para no consumir batería en segundo plano.
    function onHide() as Void {
        var t = mTimer;
        if (t != null) {
            t.stop();
        }
    }

    // Callback del Timer: solicita un repintado para avanzar los parciales.
    function onTimerTick() as Void {
        WatchUi.requestUpdate();
    }

    // Render imperativo. Despacha el dibujo según el estado FSM (if/else if).
    function onUpdate(dc as Dc) as Void {
        var app   = getApp();
        var state = app.mFsmState;

        // ── Pausa (Fase 7) ──────────────────────────────────────────────────────
        // Corta el render del estado vivo y dibuja la pantalla de pausa atenuada.
        // Garantiza congelación visual: el parcial se muestra detenido.
        if (app.mIsPaused) {
            drawPaused(dc, app);
            return;
        }

        // ── Fondo según estado ─────────────────────────────────────────────────
        // Alto contraste: blanco en carrera (STATE_RUN), negro en todo lo demás.
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

    // ── Pantalla de pausa (Fase 7) ──────────────────────────────────────────────
    // Fondo atenuado e inconfundible: "PAUSA" grande, el estado pausado, el parcial
    // congelado y el hint de reanudación. FONT_LARGE (no FONT_NUMBER_*, que solo
    // tiene dígitos). El parcial se ve detenido porque stateElapsedMs() congela la
    // referencia en mPauseStartMs mientras mIsPaused.
    private function drawPaused(dc as Dc, app as HyroxPacerApp) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_DK_GRAY);
        dc.clear();

        // Estado actual (qué se ha pausado).
        var label = "ESTACION";
        var state = app.mFsmState;
        if (state == STATE_RUN) {
            label = "RUN  km " + (app.mHyroxCycle + 1).toString() + "/8";
        } else if (state == STATE_ROXZONE_IN || state == STATE_ROXZONE_OUT) {
            label = "ROXZONE";
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY, label,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // "PAUSA" grande y destacado.
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY, Graphics.FONT_LARGE, "PAUSA",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Parcial congelado del estado en curso.
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY + mLineH * 2, Graphics.FONT_TINY,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Hint de reanudación.
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "START > reanudar",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Pantallas por estado ─────────────────────────────────────────────────────

    // WARMUP: pantalla de inicio. Objetivo de tiempo + distancia, estado del GPS y
    // prompt de qué botón pulsar para comenzar.
    private function drawWarmup(dc as Dc, app as HyroxPacerApp, fg as Graphics.ColorType) as Void {
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY, "HYROX",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Objetivo de tiempo (grande) + distancia fija (pequeño debajo).
        dc.drawText(mCenterX, mCenterY - mLineH, Graphics.FONT_NUMBER_MEDIUM,
                    formatClock(app.mTargetTimeMs),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(mCenterX, mCenterY + mLineH, Graphics.FONT_TINY, "objetivo - 8 km",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Estado del GPS: verde si hay fix, rojo si aún busca señal.
        var gpsColor = Graphics.COLOR_RED;
        var gpsStr   = "Buscando GPS";
        if (app.mGps.hasFix()) {
            gpsColor = Graphics.COLOR_GREEN;
            gpsStr   = "GPS OK";
        }
        dc.setColor(gpsColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY - mLineH, Graphics.FONT_TINY, gpsStr,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Prompt de inicio.
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "START > comenzar",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // RUN: ritmo REAL del atleta (grande, verde/rojo vs objetivo) + objetivo de
    // referencia (pequeño) + km actual + parcial del km.
    private function drawRun(dc as Dc, app as HyroxPacerApp, fg as Graphics.ColorType) as Void {
        var cycle = app.mHyroxCycle + 1;
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY,
                    "RUN  km " + cycle.toString() + "/8",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Ritmo real (suavizado) y objetivo dinámico vigente.
        var paceTarget = app.mDynamicPaceTargetSec;
        var avgSpeed   = app.mGps.getAvgSpeedMs();
        var realPace   = app.mPacing.computeCurrentPaceSec(avgSpeed);
        var delta      = app.mPacing.computePaceDeltaDeviation(avgSpeed, paceTarget);

        // Color del ritmo real: verde si igualas/superas el objetivo, rojo si te
        // retrasas. Neutro (fg) mientras no haya ritmo válido (parado / sin objetivo).
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

        // Objetivo de referencia (pequeño) debajo del ritmo real.
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mCenterY + mLineH * 2, Graphics.FONT_TINY,
                    "obj " + formatPace(paceTarget),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Parcial del km en curso.
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ROXZONE_IN / ROXZONE_OUT: tiempo en la zona de transición + hint de botón.
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
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "BACK > seguir",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // STATION: timer de la estación + atleta activo (toggle con UP/DOWN en dobles).
    private function drawStation(dc as Dc, app as HyroxPacerApp, fg as Graphics.ColorType) as Void {
        var cycle = app.mHyroxCycle + 1;
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandTopY, Graphics.FONT_TINY,
                    "STATION " + cycle.toString() + "/8",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.drawText(mCenterX, mCenterY, Graphics.FONT_NUMBER_HOT,
                    formatClock(stateElapsedMs(app)),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // Atleta activo del relevo, con color para identificación rápida.
        var athleteColor = Graphics.COLOR_BLUE;
        var athleteStr   = "Atleta A";
        if (!app.mActiveAthlete) {
            athleteColor = Graphics.COLOR_ORANGE;
            athleteStr   = "Atleta B";
        }
        dc.setColor(athleteColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, athleteStr,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // FINISH: resumen de carrera (tiempo total + work/rest ratio) + salida.
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
        dc.drawText(mCenterX, mBandBottomY, Graphics.FONT_TINY, "BACK > salir",
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ── Helpers privados ───────────────────────────────────────────────────────

    // Tiempo transcurrido (ms) en el estado actual = ref - última transición - pausa.
    // Fase 7: en pausa la referencia se congela en mPauseStartMs (el parcial se
    // detiene); mPausedMs solo crece al reanudar, así que tras reanudar el parcial
    // continúa donde estaba. Solo válido fuera de WARMUP; el clamp evita negativos.
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

    // Formatea un ritmo en s/km como "M:SS" (ej. 300 → "5:00").
    // Retorna "--:--" si el valor es inválido (sin objetivo activo).
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

    // Formatea una duración en ms como "M:SS" (los minutos pueden superar 60).
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

    // Formatea el cociente trabajo/descanso como "X.Y" (un decimal).
    // Retorna "--" si no hay tiempo de descanso registrado (evita división por cero).
    private function formatRatio(workMs as Number, restMs as Number) as String {
        if (restMs <= 0) {
            return "--";
        }
        var ratio10 = (workMs * 10) / restMs;  // división entera → décimas
        var whole   = ratio10 / 10;
        var frac    = ratio10 % 10;
        return whole.toString() + "." + frac.toString();
    }

}
