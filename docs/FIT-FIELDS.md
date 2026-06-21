# HybridPacer — FIT Developer Fields

HybridPacer writes **7 custom FIT developer fields** to every recorded activity at approximately 1 Hz. After syncing to Garmin Connect, these fields appear as data charts on the activity page.

---

## Table of Contents

1. [Overview](#overview)
2. [Field Reference](#field-reference)
3. [Reading Fields in Garmin Connect](#reading-fields-in-garmin-connect)
4. [Technical Details](#technical-details)
5. [Adding or Modifying Fields](#adding-or-modifying-fields)

---

## Overview

FIT developer fields are written by `HyroxFitSession.tickFitMetrics()`, called from `GpsSessionManager.onPosition()` at ~1 Hz during an active recording session (from WARMUP→RUN until FINISH).

The field **IDs (0–6) are immutable** — they must stay in sync between `source/HyroxFitSession.mc` (`FIT_ID_*` constants) and `resources/fitcontributions.xml`. Changing an ID on a device that has a `.fit` file with the old ID will silently produce unreadable data.

---

## Field Reference

### Field 0 — `hyrox_cycle_id`

| Attribute | Value |
|---|---|
| **ID** | 0 |
| **Constant** | `FIT_ID_CYCLE_ID` |
| **Data type** | UINT8 |
| **Unit** | cycle |
| **Chart** | Yes |
| **Chart color** | `#FF6600` (orange) |

**Description:** The current HYROX cycle number, 0-indexed (0 = first run, 7 = eighth run). Advances after each ROXZONE_OUT→RUN transition.

**Values:** 0, 1, 2, 3, 4, 5, 6, 7. Stays at 7 after the last run completes.

**Usefulness:** Shows which km segment was being run at any point in time. When overlaid with pace data, reveals per-km performance.

---

### Field 1 — `hyrox_fsm_state`

| Attribute | Value |
|---|---|
| **ID** | 1 |
| **Constant** | `FIT_ID_FSM_STATE` |
| **Data type** | UINT8 |
| **Unit** | state |
| **Chart** | Yes |
| **Chart color** | `#0066FF` (blue) |

**Description:** The current FSM state code.

**Values:**

| Code | State | Meaning |
|---|---|---|
| 0 | WARMUP | Pre-race warm-up (not recorded — FIT session starts at RUN) |
| 1 | RUN | Actively running a 1 km segment |
| 2 | ROXZONE_IN | Entering transition corridor toward the station |
| 3 | STATION | Performing the functional workout at the station |
| 4 | ROXZONE_OUT | Exiting transition corridor back toward the next run |
| 5 | FINISH | Race complete |

> Note: because the FIT session starts on WARMUP→RUN transition, the recording never contains state 0 (WARMUP). The first record always shows state 1.

**Usefulness:** The step-function shape of this chart instantly shows how many cycles were completed and how long each phase lasted.

---

### Field 2 — `roxzone_total_time`

| Attribute | Value |
|---|---|
| **ID** | 2 |
| **Constant** | `FIT_ID_ROXZONE_TOTAL` |
| **Data type** | UINT32 |
| **Unit** | seconds |
| **Chart** | Yes |
| **Chart color** | `#9900CC` (purple) |

**Description:** Cumulative time spent in **ROXZONE_IN + ROXZONE_OUT** across all completed cycles, plus the live partial of the current RoxZone segment if currently in one.

**Formula written to FIT:**
```
value = mRoxzoneTotalMs / 1000
// if currently in ROXZONE_IN or ROXZONE_OUT:
value += (now − mLastTransitionMs) / 1000
```

**Usefulness:** Tracks how much total time was spent in transition corridors. Monotonically increasing; flat during RUN and STATION.

---

### Field 3 — `station_elapsed`

| Attribute | Value |
|---|---|
| **ID** | 3 |
| **Constant** | `FIT_ID_STATION_ELAPSED` |
| **Data type** | UINT32 |
| **Unit** | seconds |
| **Chart** | Yes |
| **Chart color** | `#CC0000` (dark red) |

**Description:** Time elapsed since entering the current STATION segment. Resets to 0 at every non-STATION state.

**Formula:**
```
if state == STATION:
    value = (now − mLastTransitionMs) / 1000
else:
    value = 0
```

**Usefulness:** Shows exactly how long each individual station took. The sawtooth pattern (rising during STATION, drop to 0 on exit) makes individual station durations easy to read.

---

### Field 4 — `active_athlete`

| Attribute | Value |
|---|---|
| **ID** | 4 |
| **Constant** | `FIT_ID_ACTIVE_ATHLETE` |
| **Data type** | UINT8 |
| **Unit** | bool |
| **Chart** | No |

**Description:** Which athlete is currently active in doubles/relay mode.

**Values:** `1` = Athlete A active, `0` = Athlete B active. In solo mode, always `1`.

**Usefulness:** In doubles races, lets post-race analysis assign each segment to the correct athlete's split times.

---

### Field 5 — `pace_delta_deviation`

| Attribute | Value |
|---|---|
| **ID** | 5 |
| **Constant** | `FIT_ID_PACE_DELTA` |
| **Data type** | FLOAT |
| **Unit** | s/km |
| **Precision** | 1 decimal |
| **Chart** | Yes |
| **Chart color** | `#CCCC00` (yellow) |

**Description:** The deviation of the current instantaneous GPS pace from the dynamic pace target, in seconds per km.

**Formula (from `PacingEngine.computePaceDeltaDeviation`):**
```
if speed > 0.5 m/s:
    paceNow = 1000 / speed          (m/s → s/km)
    value   = paceNow − paceTarget  (positive = slower, negative = faster)
else:
    value = 0.0
```

**Interpretation:**
- `+30.0` → running 30 s/km slower than target (fall behind).
- `−15.0` → running 15 s/km faster than target (building surplus).
- `0.0` → at target, or speed below minimum threshold.

> Uses **instantaneous** speed (not EMA-smoothed), so the FIT record captures raw GPS signal variance.

**Usefulness:** The most analytically rich field — shows exactly how much faster or slower the athlete ran vs. the dynamically adjusted target at every second of the race.

---

### Field 6 — `work_rest_ratio`

| Attribute | Value |
|---|---|
| **ID** | 6 |
| **Constant** | `FIT_ID_WORK_REST` |
| **Data type** | FLOAT |
| **Unit** | ratio |
| **Precision** | 2 decimals |
| **Chart** | Yes |
| **Chart color** | `#00CCCC` (teal) |

**Description:** Running time divided by station+transition time, updated live as the race progresses.

**Formula:**
```
if mRestMs > 0:
    value = mWorkMs / mRestMs
else:
    value = 0.0
```

**Interpretation:** A ratio of `2.5` means the athlete spent 2.5× more time running than resting. For a well-paced HYROX race with ~3 min stations and ~6 min per km, expect values in the range of 1.5–3.0.

**Usefulness:** A single number that captures the running-to-rest balance for the entire race up to that point. The chart shape shows how this ratio evolves — it typically rises during RUN and drops during STATION/ROXZONE.

---

## Reading Fields in Garmin Connect

After syncing your watch:

1. Open the activity in [Garmin Connect](https://connect.garmin.com).
2. Scroll to the **Charts** section on the activity page.
3. Developer fields appear as additional chart overlays alongside standard metrics (heart rate, pace, elevation).

Fields with `displayInChart="true"` in `fitcontributions.xml` are shown automatically. Each has a distinct color for easy identification.

For more detailed analysis, export the `.fit` file from Garmin Connect and open it in [FIT File Tools](https://www.fitfiletools.com/) or [FIT CSV Tool](https://developer.garmin.com/fit/download/) to see the raw record data at 1 Hz resolution.

---

## Technical Details

### Field initialization

All 7 fields are registered in `HyroxFitSession.initializeFitFields(session)`, called from `GpsSessionManager.startRecording()` immediately before `session.start()`. Each field is created with `session.createField(name, id, type, options)`.

The field ID passed to `createField` **must exactly match** the `id` attribute in `fitcontributions.xml`. A mismatch causes the chart metadata (title, label, color) to be disassociated from the data.

### Write guard

`HyroxFitSession.mIsInitialized` is `false` until `initializeFitFields()` completes. `tickFitMetrics()` returns immediately if `!mIsInitialized`, making it a no-op before recording starts or after it ends.

### Hot-path compliance

`tickFitMetrics()` contains **no `new` calls** and **no `Lang.Dictionary`**. The 7 field handles are reused across every write. The typecheck=3 nullable-narrowing pattern (`var f = mFieldXxx; if (f != null) { ... }`) is used for all field writes.

---

## Adding or Modifying Fields

1. Add the new field definition to `resources/fitcontributions.xml` with a new unique `id` (use the next sequential integer).
2. Add a `FIT_ID_*` constant in `source/HyroxFitSession.mc` matching that `id`.
3. Declare a nullable field handle member (`var mFieldNewName as FitContributor.Field? = null`).
4. In `initializeFitFields()`, create the field with `session.createField(...)`, call `f.setData(initial)`, and assign to the member.
5. In `tickFitMetrics()`, add a null-guarded write: `var f = mFieldNewName; if (f != null) { f.setData(value); }`.
6. Add the corresponding string resources (`fitXxxTitle`, `fitXxxLabel`, `fitXxxUnit`) to `resources/strings/strings.xml`.

> Never reuse an existing field ID or change the type of an existing field — this would corrupt data in any previously recorded `.fit` files.
