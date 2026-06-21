import Toybox.ActivityRecording;
import Toybox.FitContributor;
import Toybox.Lang;
import Toybox.System;

// ─── Constantes de pacing ─────────────────────────────────────────────────────
// Pace objetivo para una carrera Hyrox: 5:00 min/km = 300 s/km.
// pace_delta_deviation > 0 → más lento que objetivo; < 0 → más rápido.
const TARGET_PACE_SEC_PER_KM as Number = 300;
const PACE_MIN_SPEED         as Float  = 0.5f;  // Umbral mínimo (m/s) para calcular pace

// ─── FIT Field IDs ────────────────────────────────────────────────────────────
// DEBEN coincidir con el atributo id de los <fitField> en fitcontributions.xml.
const FIT_ID_CYCLE_ID        as Number = 0;
const FIT_ID_FSM_STATE       as Number = 1;
const FIT_ID_ROXZONE_TOTAL   as Number = 2;
const FIT_ID_STATION_ELAPSED as Number = 3;
const FIT_ID_ACTIVE_ATHLETE  as Number = 4;
const FIT_ID_PACE_DELTA      as Number = 5;
const FIT_ID_WORK_REST       as Number = 6;

// ─── HyroxFitSession ──────────────────────────────────────────────────────────
// Singleton que posee los 7 handles de FitContributor.Field y expone:
//   - initializeFitFields(session): registra los 7 campos en la sesión FIT activa.
//   - tickFitMetrics():             escribe los valores actuales a ~1Hz (sin new).
//   - clearFitFields():             deshabilita la escritura al cerrar la sesión.
//
// PATRÓN TYPECHECK=3 PARA HANDLES NULLABLE:
//   Los 7 campos se declaran como 'Field? = null'. En initializeFitFields() se usa
//   una variable local 'var f = session.createField(...)' (tipo inferido Field no-null)
//   para llamar f.setData() antes de asignar al miembro. En tickFitMetrics() se
//   usa 'var f = mFieldXxx; if (f != null) { f.setData(...); }' — el compilador
//   estrecha el tipo de f dentro del guard (mismo patrón que info.position en
//   GpsSessionManager.onPosition). mIsInitialized actúa de fast-path guard para
//   que en producción el null-check sea siempre true (cero overhead).
//
// REGLAS DE MEMORIA:
//   - Sin `new` en tickFitMetrics() ni en ninguna ruta caliente.
//   - Sin Lang.Dictionary como estructura de dominio.
//   - Sin switch/case: ramas con if/else if.
class HyroxFitSession {

    // ── Flag guardián ────────────────────────────────────────────────────
    // false hasta que initializeFitFields() termine; vuelve a false en clearFitFields().
    // tickFitMetrics() comprueba este flag primero: salida inmediata si no grabamos.
    var mIsInitialized as Boolean = false;

    // ── Handles de campo FIT (nullable) ──────────────────────────────────
    // null hasta que initializeFitFields() sea invocado; null otra vez tras clearFitFields().
    // Se acceden vía variable local para satisfacer typecheck=3 (ver tickFitMetrics).
    var mFieldCycleId        as FitContributor.Field? = null;
    var mFieldFsmState       as FitContributor.Field? = null;
    var mFieldRoxzoneTotal   as FitContributor.Field? = null;
    var mFieldStationElapsed as FitContributor.Field? = null;
    var mFieldActiveAthlete  as FitContributor.Field? = null;
    var mFieldPaceDelta      as FitContributor.Field? = null;
    var mFieldWorkRest       as FitContributor.Field? = null;

    function initialize() {
        // mIsInitialized = false y todos los handles = null (declarados arriba).
        // No se crea nada del SDK aquí; el Session handle no existe aún.
    }

    // ── initializeFitFields(session) ──────────────────────────────────────
    // Llamado desde GpsSessionManager.startRecording(), justo antes de session.start().
    // Patrón typecheck=3:
    //   1. var f = session.createField(...)  → f tiene tipo Field (no-nullable, inferido)
    //   2. f.setData(valor_inicial)           → válido porque f no es nullable
    //   3. mFieldXxx = f                     → asigna Field a Field? (válido)
    // Dict literales = excepción permitida: llamadas de init único, nunca en 1Hz.
    function initializeFitFields(session as ActivityRecording.Session) as Void {
        var f = session.createField(
            "hyrox_cycle_id",
            FIT_ID_CYCLE_ID,
            FitContributor.DATA_TYPE_UINT8,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "cycle"}
        );
        f.setData(0);
        mFieldCycleId = f;

        f = session.createField(
            "hyrox_fsm_state",
            FIT_ID_FSM_STATE,
            FitContributor.DATA_TYPE_UINT8,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "state"}
        );
        f.setData(1);          // Empieza en STATE_RUN (justo se transicionó desde WARMUP)
        mFieldFsmState = f;

        f = session.createField(
            "roxzone_total_time",
            FIT_ID_ROXZONE_TOTAL,
            FitContributor.DATA_TYPE_UINT32,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "s"}
        );
        f.setData(0);
        mFieldRoxzoneTotal = f;

        f = session.createField(
            "station_elapsed",
            FIT_ID_STATION_ELAPSED,
            FitContributor.DATA_TYPE_UINT32,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "s"}
        );
        f.setData(0);
        mFieldStationElapsed = f;

        f = session.createField(
            "active_athlete",
            FIT_ID_ACTIVE_ATHLETE,
            FitContributor.DATA_TYPE_UINT8,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "bool"}
        );
        f.setData(1);          // El atleta principal activo al arrancar
        mFieldActiveAthlete = f;

        f = session.createField(
            "pace_delta_deviation",
            FIT_ID_PACE_DELTA,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "s/km"}
        );
        f.setData(0.0f);
        mFieldPaceDelta = f;

        f = session.createField(
            "work_rest_ratio",
            FIT_ID_WORK_REST,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "ratio"}
        );
        f.setData(0.0f);
        mFieldWorkRest = f;

        // Activa el guardián: a partir de aquí tickFitMetrics() puede escribir.
        mIsInitialized = true;
    }

    // ── clearFitFields() ──────────────────────────────────────────────────
    // Llamado desde GpsSessionManager.stopRecording() y stop().
    // Desactiva el guardián; los handles quedan como estaban (nunca se acceden).
    function clearFitFields() as Void {
        mIsInitialized = false;
    }

    // ── tickFitMetrics() ──────────────────────────────────────────────────
    // Escribe los valores actuales de los 7 campos FIT. Invocado desde
    // GpsSessionManager.onPosition() a ~1Hz.
    // PROHIBIDO: new, Lang.Dictionary, switch/case.
    //
    // Patrón typecheck=3 para null-check de miembros:
    //   var f = mFieldXxx;          → f infiere tipo Field? desde el miembro
    //   if (f != null) { f.setData(...); }  → compilador estrecha f a Field
    // Se reutiliza 'f' para los 7 campos (una sola declaración de variable local).
    // En producción, mIsInitialized = true garantiza que los null-checks son siempre
    // verdaderos; son no-ops semánticos para satisfacer al type checker.
    function tickFitMetrics() as Void {
        // Fast-path: no grabamos aún (antes de startRecording o tras stopRecording).
        if (!mIsInitialized) {
            return;
        }

        var app   = getApp();
        var state = app.mFsmState;
        var now   = System.getTimer();

        // ── 1. hyrox_cycle_id (0-7) ──────────────────────────────────────
        var f = mFieldCycleId;
        if (f != null) {
            f.setData(app.mHyroxCycle);
        }

        // ── 2. hyrox_fsm_state (0-5) ─────────────────────────────────────
        f = mFieldFsmState;
        if (f != null) {
            f.setData(state);
        }

        // ── 3. roxzone_total_time — total comprometido + parcial en curso ─
        var roxzoneSec = app.mRoxzoneTotalMs / 1000;
        if (state == STATE_ROXZONE_IN || state == STATE_ROXZONE_OUT) {
            roxzoneSec = roxzoneSec + (now - app.mLastTransitionMs) / 1000;
        }
        f = mFieldRoxzoneTotal;
        if (f != null) {
            f.setData(roxzoneSec);
        }

        // ── 4. station_elapsed — tiempo en la estación de trabajo actual ──
        var stationSec = 0;
        if (state == STATE_STATION) {
            stationSec = (now - app.mLastTransitionMs) / 1000;
        }
        f = mFieldStationElapsed;
        if (f != null) {
            f.setData(stationSec);
        }

        // ── 5. active_athlete — 1=activo, 0=esperando relevo (dobles) ────
        f = mFieldActiveAthlete;
        if (f != null) {
            if (app.mActiveAthlete) {
                f.setData(1);
            } else {
                f.setData(0);
            }
        }

        // ── 6. pace_delta_deviation — delta respecto al objetivo dinámico ───
        // Delega en PacingEngine.computePaceDeltaDeviation():
        //   speed > PACE_MIN_SPEED → pace = 1000/speed (s/km); δ = pace - target.
        //   Positivo → más lento que el objetivo; negativo → más rápido.
        //   mDynamicPaceTargetSec se recalcula solo en transición a STATE_RUN.
        var paceDelta = app.mPacing.computePaceDeltaDeviation(
            app.mGps.getSpeedMs(),
            app.mDynamicPaceTargetSec);
        f = mFieldPaceDelta;
        if (f != null) {
            f.setData(paceDelta);
        }

        // ── 7. work_rest_ratio — tiempo en RUN / tiempo en pausa ─────────
        var ratio = 0.0f;
        if (app.mRestMs > 0) {
            ratio = app.mWorkMs.toFloat() / app.mRestMs.toFloat();
        }
        f = mFieldWorkRest;
        if (f != null) {
            f.setData(ratio);
        }
    }

}
