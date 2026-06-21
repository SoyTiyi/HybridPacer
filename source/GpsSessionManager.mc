import Toybox.Position;
import Toybox.ActivityRecording;
import Toybox.Activity;
import Toybox.Lang;
import Toybox.WatchUi;

// ─── GpsSessionManager ────────────────────────────────────────────────────────
// Encapsula dos responsabilidades del SDK de bajo nivel con vidas útiles distintas:
//
//   1. Positioning (GPS continuo): activo toda la vida de la app.
//      start() habilita el GPS en App.onStart(); stop() lo libera en App.onStop().
//
//   2. ActivityRecording (sesión FIT): activa solo entre startRecording() y stopRecording().
//      startRecording() → llamado desde FSMController al WARMUP→RUN.
//      stopRecording()  → llamado desde FSMController al alcanzar FINISH.
//      stop() actúa de red de seguridad ante cierre forzado.
//
// PATRÓN TYPECHECK=3 PARA MIEMBROS NULLABLE:
//   mSession se declara como 'Session?' (nullable). Para llamar métodos de SDK
//   sobre él sin errores de tipo, siempre se copia a una variable local antes
//   del null-check: 'var s = mSession; if (s != null) { ... }'. El compilador
//   estrecha el tipo de la local (igual que hace con 'pos' en onPosition).
//
// REGLA DE MEMORIA:
//   - Todos los campos de estado están pre-asignados en initialize().
//   - onPosition() NO instancia ningún objeto; solo actualiza primitivos y despacha
//     tickFitMetrics() (que es no-op si mIsInitialized = false).
//   - Dict literales en startRecording() = excepción justificada (init único, no 1Hz).

// Suavizado exponencial (EMA) de la velocidad GPS. alpha 0.25 ≈ constante de
// tiempo ~4 s a 1 Hz: amortigua el ruido del ritmo instantáneo (que salta varios
// s/km entre muestras) sin un retardo perceptible. Solo mult/suma de Float → apto
// para la ruta caliente onPosition (sin asignaciones dinámicas).
const SPEED_SMOOTHING_ALPHA as Float = 0.25f;

class GpsSessionManager {

    // ── Caché de posición GPS ─────────────────────────────────────────────
    // Pre-asignados para que onPosition() (callback a ~1Hz) nunca use `new`.
    var mLat      as Double  = 0.0d;   // Latitud en grados decimales
    var mLon      as Double  = 0.0d;   // Longitud en grados decimales
    var mSpeed    as Float   = 0.0f;   // Velocidad instantánea en m/s
    var mSpeedAvg as Float   = 0.0f;   // Velocidad suavizada (EMA) en m/s → ritmo real mostrado
    var mAccuracy as Number  = 0;      // Quality enum: Position.QUALITY_*
    var mHasFix   as Boolean = false;  // true cuando accuracy > NOT_AVAILABLE

    // ── Sesión de grabación FIT ───────────────────────────────────────────
    // null hasta que startRecording() sea invocado (WARMUP → RUN).
    var mSession as ActivityRecording.Session? = null;

    function initialize() {
        // Todos los miembros ya tienen valor inicial arriba.
        // El SDK NO se toca aquí: Position y ActivityRecording solo pueden
        // iniciarse después de que AppBase.onStart() haya sido invocado.
    }

    // ── start() ───────────────────────────────────────────────────────────
    // Llamado desde HyroxPacerApp.onStart(). Solo activa el GPS continuo.
    // La sesión FIT NO se crea aquí; eso ocurre en startRecording() cuando
    // el atleta confirma el inicio de la carrera (WARMUP → RUN).
    function start() as Void {
        // method(:onPosition) → referencia de método, no crea objetos.
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    // ── startRecording() ──────────────────────────────────────────────────
    // Llamado desde FSMController.attemptTransition() al transicionar WARMUP→RUN.
    // Crea la sesión FIT, registra los 7 campos Hyrox y arranca la grabación.
    // Patrón typecheck=3: var s = mSession; if (s != null) para estrechar el tipo.
    function startRecording() as Void {
        mSession = ActivityRecording.createSession({
            :name     => "Hyrox",
            :sport    => Activity.SPORT_RUNNING,
            :subSport => Activity.SUB_SPORT_GENERIC
        });

        var s = mSession;
        if (s != null) {
            // Registra los 7 campos FIT developer antes de iniciar el timer.
            getApp().mFit.initializeFitFields(s);
            // Arranca la grabación (inicia el timer FIT y los registros por segundo).
            s.start();
        }
    }

    // ── stopRecording() ───────────────────────────────────────────────────
    // Llamado desde FSMController.attemptTransition() al alcanzar STATE_FINISH.
    // Detiene el timer FIT, guarda el archivo .fit y deshabilita la escritura.
    function stopRecording() as Void {
        var s = mSession;
        if (s != null && s.isRecording()) {
            s.stop();
            s.save();
        }
        mSession = null;
        // Desactiva mIsInitialized: tickFitMetrics() queda como no-op.
        getApp().mFit.clearFitFields();
    }

    // ── pauseRecording() (Fase 7) ─────────────────────────────────────────
    // Pausa el timer FIT sin guardar: la sesión sigue viva. SDK 9.2.0:
    // Session.stop() detiene el timer; un start() posterior lo reanuda.
    // Patrón nullable: copia local + null-check; guard isRecording().
    function pauseRecording() as Void {
        var s = mSession;
        if (s != null && s.isRecording()) {
            s.stop();
        }
    }

    // ── resumeRecording() (Fase 7) ────────────────────────────────────────
    // Reanuda el timer FIT de la MISMA sesión (save() se difiere a FINISH).
    function resumeRecording() as Void {
        var s = mSession;
        if (s != null && !s.isRecording()) {
            s.start();
        }
    }

    // ── addLap() ──────────────────────────────────────────────────────────
    // Inserta un evento de vuelta (split nativo) en el archivo FIT.
    // Invocado desde FSMController.markLap() en los límites:
    //   - RUN(1) → ROXZONE_IN(2): inicio de zona de transición
    //   - ROXZONE_OUT(4) → RUN(1): vuelta a la carrera
    function addLap() as Void {
        var s = mSession;
        if (s != null && s.isRecording()) {
            s.addLap();
        }
    }

    // ── onPosition() ──────────────────────────────────────────────────────
    // Callback del SDK de Positioning. Invocado a ~1Hz mientras el GPS está activo.
    // PROHIBIDO: new, Lang.Dictionary, switch/case, accesos a objetos transitorios.
    // Solo actualiza primitivos pre-asignados y dispara el tick FIT.
    function onPosition(info as Position.Info) as Void {
        // Cachea la precisión de señal (Position.QUALITY_* enum, es un Number).
        mAccuracy = info.accuracy;

        if (mAccuracy > Position.QUALITY_NOT_AVAILABLE) {
            mHasFix = true;

            // toDegrees() devuelve Array<Double> de [lat, lon].
            // Guard null obligatorio: info.position es Position.Location or Null (API 4.x).
            var pos = info.position;
            if (pos != null) {
                var deg = pos.toDegrees() as Array<Double>;
                mLat = deg[0];
                mLon = deg[1];
            }

            // Velocidad en m/s (puede ser null si el dispositivo no la reporta).
            if (info has :speed && info.speed != null) {
                mSpeed = info.speed as Float;
            }
        } else {
            mHasFix = false;
        }

        // Suavizado exponencial de la velocidad para el ritmo real mostrado en RUN.
        // Se actualiza cada callback (~1Hz) con la última velocidad conocida (mSpeed).
        mSpeedAvg = mSpeedAvg + SPEED_SMOOTHING_ALPHA * (mSpeed - mSpeedAvg);

        // Escribe las métricas FIT al ritmo del GPS (~1Hz).
        // No-op si mIsInitialized = false (antes de startRecording o tras stopRecording).
        getApp().mFit.tickFitMetrics();
        // Refresca la vista imperativa con los datos GPS más recientes.
        WatchUi.requestUpdate();
    }

    // ── stop() ────────────────────────────────────────────────────────────
    // Llamado desde HyroxPacerApp.onStop(). Red de seguridad: guarda la sesión
    // si todavía está activa (ej. cierre forzado antes de FINISH) y libera el GPS.
    function stop() as Void {
        var s = mSession;
        // Fase 7: guarda también una sesión en PAUSA (isRecording()=false tras
        // pauseRecording). Si no, salir de la app en pausa perdería el .fit.
        if (s != null) {
            if (s.isRecording()) {
                s.stop();
            }
            s.save();
        }
        mSession = null;
        // Desactiva mIsInitialized (idempotente si ya fue llamado por stopRecording).
        getApp().mFit.clearFitFields();
        // Libera el módulo GPS.
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }

    // ── Getters de solo lectura para la vista y el pacing engine ─────────

    function hasFix() as Boolean {
        return mHasFix;
    }

    function getLatitude() as Double {
        return mLat;
    }

    function getLongitude() as Double {
        return mLon;
    }

    function getSpeedMs() as Float {
        return mSpeed;
    }

    // Velocidad suavizada (EMA) en m/s. Úsala para mostrar el ritmo real al atleta
    // (evita el salto nervioso del ritmo instantáneo).
    function getAvgSpeedMs() as Float {
        return mSpeedAvg;
    }

    function getAccuracy() as Number {
        return mAccuracy;
    }

}
