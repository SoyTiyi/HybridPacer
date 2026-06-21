# HybridPacer — Pacing Engine

This document is the definitive reference for `PacingEngine.mc` — how it works, why it works, and how to reason about edge cases.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [Algorithm: computeDynamicPaceTarget](#algorithm-computedynamicpacetarget)
3. [Worked Examples](#worked-examples)
4. [Algorithm: computePaceDeltaDeviation](#algorithm-computepacedeltadeviation)
5. [Algorithm: computeCurrentPaceSec](#algorithm-computecurrentsec)
6. [EMA Speed Smoothing](#ema-speed-smoothing)
7. [Edge Cases](#edge-cases)
8. [Constants Reference](#constants-reference)

---

## The Problem

A HYROX race has **8 km of running** split into 8 rounds, interleaved with **8 functional workout stations**. Your total race time includes both running time and station time, but you can only control your **running pace**.

If you target a 90-minute finish and your stations take an average of 3 minutes each, those 24 total minutes of station time leave only 66 minutes for running — meaning your effective running pace must be faster than a naïve 90 min / 8 km = 11:15/km.

Furthermore, stations are not equal. If early stations are slow, the pace needed for the remaining runs must increase to compensate. **The pacing engine solves this dynamically after every station**, using the actual accumulated rest time to project forward.

---

## Algorithm: computeDynamicPaceTarget

**Called by:** `FSMController.attemptTransition()` on every entry to `STATE_RUN` (WARMUP→RUN and ROXZONE_OUT→RUN).  
**Never called at 1 Hz** — recalculation only happens on state transitions.

### Inputs

| Parameter | Source | Description |
|---|---|---|
| `targetTimeMs` | `app.mTargetTimeMs` | Athlete's goal total race time (ms) |
| `elapsedTotalMs` | `app.mWorkMs + app.mRestMs` | Time committed so far (ms) |
| `distanceCompletedKm` | `app.mHyroxCycle` | Number of 1 km segments already completed |

### Steps

```
1. distanceRemainingKm = 8.0 − distanceCompletedKm
   → if ≤ 0.0, return 0.0f  (race over or distance exceeded)

2. cyclesDone = app.mHyroxCycle
   avgRestMs  = mRestMs / cyclesDone      (integer division; 0 if cyclesDone == 0)

3. cyclesRemaining  = 8 − cyclesDone
   projectedRestMs  = avgRestMs × cyclesRemaining

4. runTimeRemainingMs = targetTimeMs − elapsedTotalMs − projectedRestMs
   → if ≤ 0, return 0.0f  (athlete is off-plan → UI shows --:-- in red)

5. return (runTimeRemainingMs / 1000.0f) / distanceRemainingKm
```

### Why average historical rest?

Using the mean of past station times as a predictor of future station times is a simple, robust heuristic that:
- Starts conservative on Run 1 (no history → projected rest = 0, so the full target time is divided over all 8 km).
- Adapts mid-race as real station times are observed.
- Does not require any prior knowledge of the athlete's ability at specific exercises.

A more sophisticated model could weight recent stations more heavily, or look up expected times per exercise, but the simple mean performs well in practice and adds no runtime cost.

---

## Worked Examples

### Example 1 — Race start (Run 1, 90-minute goal)

```
targetTimeMs        = 5,400,000 ms  (90 min)
elapsedTotalMs      = 0             (just started)
distanceCompleted   = 0             (no km done yet)
mRestMs             = 0
cyclesDone          = 0

distanceRemaining   = 8.0 km
avgRestMs           = 0  (no cycles done)
projectedRest       = 0
runTimeRemaining    = 5,400,000 ms = 5,400 s

pace_target = 5,400 / 8.0 = 675 s/km = 11:15 / km
```

### Example 2 — Run 4, moderate stations (~3 min each)

```
targetTimeMs        = 5,400,000 ms  (90 min)
cyclesDone          = 3             (3 km done, entering km 4)
mWorkMs             = 2,100,000 ms  (35 min running)
mRestMs             = 540,000 ms    (3 stations × 3 min = 9 min total)
elapsedTotalMs      = 2,640,000 ms

distanceRemaining   = 5.0 km
avgRestMs           = 540,000 / 3 = 180,000 ms (3 min average)
projectedRest       = 180,000 × 5 = 900,000 ms (15 min ahead)
runTimeRemaining    = 5,400,000 − 2,640,000 − 900,000 = 1,860,000 ms = 1,860 s

pace_target = 1,860 / 5.0 = 372 s/km = 6:12 / km
```

The target pace tightened from 11:15 to 6:12/km because 9 minutes of station time have been committed and the engine projects another 15 minutes.

### Example 3 — Run 7, slow stations (~4 min each)

```
targetTimeMs        = 5,400,000 ms
cyclesDone          = 6
mWorkMs             = 2,280,000 ms  (38 min running)
mRestMs             = 1,440,000 ms  (6 × 4 min = 24 min rest)
elapsedTotalMs      = 3,720,000 ms

distanceRemaining   = 2.0 km
avgRestMs           = 1,440,000 / 6 = 240,000 ms (4 min avg)
projectedRest       = 240,000 × 2 = 480,000 ms
runTimeRemaining    = 5,400,000 − 3,720,000 − 480,000 = 1,200,000 ms = 1,200 s

pace_target = 1,200 / 2.0 = 600 s/km = 10:00 / km
```

### Example 4 — Off-plan (athlete over budget)

```
targetTimeMs        = 5,400,000 ms
cyclesDone          = 5
mWorkMs             = 2,700,000 ms  (45 min running, very slow)
mRestMs             = 2,100,000 ms  (5 stations × 7 min = 35 min rest!)
elapsedTotalMs      = 4,800,000 ms

projectedRest       = (2,100,000/5) × 3 = 1,260,000 ms
runTimeRemaining    = 5,400,000 − 4,800,000 − 1,260,000 = −660,000 ms  (negative!)

→ returns 0.0f   UI renders "--:--" in red
```

This is the honest signal: the goal is no longer achievable at any pace. The athlete can still finish, but the target time has been missed.

---

## Algorithm: computePaceDeltaDeviation

**Called by:** `HyroxFitSession.tickFitMetrics()` at ~1 Hz.  
Written to FIT field `pace_delta_deviation` (ID 5).

```
if currentSpeedMps > PACE_MIN_SPEED (0.5 m/s):
    paceNow = 1000.0 / currentSpeedMps    (m/s → s/km)
    return paceNow − paceTargetSecPerKm   (δ vs. dynamic target)
else:
    return 0.0f                           (stopped / no fix)
```

**Interpretation:**
- `δ > 0` — athlete is **slower** than target (positive = deficit).
- `δ < 0` — athlete is **faster** than target (negative = surplus).
- `δ = 0` — at or below minimum speed threshold.

Note: this uses **instantaneous** speed (`getSpeedMs()`), not the EMA-smoothed speed, because the FIT record captures the raw GPS signal. The on-screen pace display uses the smoothed value.

---

## Algorithm: computeCurrentPaceSec

**Called by:** `HyroxPacerView.drawRun()` at ~1 Hz (render callback).  
Used for the large on-screen pace display.

```
if currentSpeedMps > PACE_MIN_SPEED (0.5 m/s):
    return 1000.0 / currentSpeedMps    (m/s → s/km)
else:
    return 0.0f                        (view renders "--:--")
```

Always pass the **EMA-smoothed** speed (`getAvgSpeedMs()`) to avoid the display flickering by several seconds per km between GPS samples.

---

## EMA Speed Smoothing

**Location:** `GpsSessionManager.onPosition()`, called at ~1 Hz.

```
mSpeedAvg += SPEED_SMOOTHING_ALPHA × (mSpeed − mSpeedAvg)
```

| Constant | Value | Meaning |
|---|---|---|
| `SPEED_SMOOTHING_ALPHA` | `0.25f` | Blending factor per sample |
| Effective time constant | ~4 s | At 1 Hz, takes ~4 samples to respond to a step change |

The EMA filter is a single multiply and add — perfectly safe for the 1 Hz hot path with no dynamic allocation.

**Why α = 0.25?**  
Raw GPS speed fluctuates by ±1–2 m/s between samples at running pace, which translates to jumps of ±30–60 s/km on the display. An α of 0.25 damps this to imperceptible while still tracking real pace changes within about 4 seconds — a good balance for race use.

---

## Edge Cases

| Scenario | Behavior |
|---|---|
| `cyclesDone == 0` on Run 1 | `avgRestMs = 0`, `projectedRest = 0` — target divides full time over all 8 km. Conservative (assumes fast stations). |
| `distanceRemainingKm <= 0` | Returns `0.0f`. Should not be reachable (ROXZONE_OUT→FINISH stops after cycle 8), but guarded defensively. |
| `runTimeRemainingMs <= 0` | Returns `0.0f`. UI renders `--:--` in red — goal is no longer achievable. |
| `currentSpeedMps <= PACE_MIN_SPEED` | Both pace functions return `0.0f`. View renders `--:--`; FIT writes `0.0f`. |
| `mRestMs == 0` and `cyclesDone > 0` | `avgRestMs = 0`. This would mean zero rest time recorded, which cannot happen after a full STATION cycle. Benign: projects no future rest, giving a generous target. |
| Paused during RUN | Pause does not trigger `computeDynamicPaceTarget`. Target pace is not recalculated until the next RUN entry (ROXZONE_OUT→RUN). Paused time is excluded from `mWorkMs` and `mRestMs` via `mPausedMs`, so the accumulators remain accurate. |

---

## Constants Reference

Defined in `source/HyroxFitSession.mc` and `source/GpsSessionManager.mc`:

| Constant | Value | Description |
|---|---|---|
| `HYROX_TOTAL_KM` | `8.0f` | Total running distance in a HYROX race |
| `HYROX_TOTAL_CYCLES` | `8` | Number of run+station cycles |
| `TARGET_PACE_SEC_PER_KM` | `300` | Baseline reference pace (5:00/km) — used only as a conceptual reference in comments; the engine uses the dynamic target |
| `PACE_MIN_SPEED` | `0.5f` | Minimum speed in m/s to compute a valid pace (guards division by zero) |
| `SPEED_SMOOTHING_ALPHA` | `0.25f` | EMA blending factor for GPS speed smoothing |
