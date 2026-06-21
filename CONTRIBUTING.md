# Contributing to HybridPacer

Thank you for your interest in contributing! This guide covers everything you need to set up your environment, understand the codebase conventions, and submit a quality pull request.

---

## Table of Contents

1. [Development Setup](#development-setup)
2. [Monkey C Coding Conventions](#monkey-c-coding-conventions)
3. [Project Architecture Overview](#project-architecture-overview)
4. [Testing & Verification](#testing--verification)
5. [Submitting a Pull Request](#submitting-a-pull-request)
6. [Commit Style](#commit-style)
7. [Issue Reporting](#issue-reporting)

---

## Development Setup

### Requirements

| Tool | Version / Notes |
|---|---|
| [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) | API Level ≥ 4.0.0 |
| [VS Code](https://code.visualstudio.com/) | Recommended IDE |
| [Monkey C VS Code extension](https://marketplace.visualstudio.com/items?itemName=garmin.monkey-c) | Provides build, simulate, and typecheck |
| Garmin Developer Key | Generate once via the VS Code extension |

### Clone & build

```bash
git clone https://github.com/SoyTiyi/HybridPacer.git
cd HybridPacer
# Open in VS Code, then: Monkey C: Build Current Project
```

The compiled output lands in `bin/`. The build config (`monkey.jungle`) sets:

```
project.typecheck = 3        # Strictest nullable checking — enforced for all PRs
project.optimization = 3z    # Aggressive size optimization for constrained flash
```

---

## Monkey C Coding Conventions

These rules are **non-negotiable** and will block PR merge if violated. They exist to ensure correctness and predictable performance on Garmin's constrained runtime.

### 1. No dynamic allocation in hot paths

**Rule:** Never use `new` inside `onUpdate()`, `onPosition()`, `tickFitMetrics()`, or any method called at 1 Hz.

**Why:** Garmin's Monkey C VM has no generational GC. Allocations in tight loops cause pauses or out-of-memory crashes mid-race.

**Pattern:**
```monkey-c
// ✅ Good — allocated once in initialize() or onShow()
var mTimer as Timer.Timer? = null;
function onShow() as Void {
    var t = new Timer.Timer();   // new is fine here — not a hot path
    mTimer = t;
}

// ❌ Bad — new in render callback
function onUpdate(dc as Dc) as Void {
    var label = new Lang.String("hello");  // NEVER do this
}
```

### 2. No `switch`/`case`

**Rule:** Use `if`/`else if` chains for all state dispatch.

**Why:** Consistency, and to avoid edge cases with Monkey C's switch fall-through semantics across SDK versions.

```monkey-c
// ✅ Good
if (state == STATE_RUN) {
    drawRun(dc, app, fg);
} else if (state == STATE_STATION) {
    drawStation(dc, app, fg);
}

// ❌ Bad
switch (state) {
    case STATE_RUN: drawRun(dc, app, fg); break;
}
```

### 3. No `Lang.Dictionary` as a domain structure

**Rule:** Do not use `Dictionary` to hold domain data (race state, accumulators, config). Use typed class members instead.

**Why:** Dictionaries bypass typecheck=3 and make nullable narrowing impossible, leading to runtime errors that the compiler cannot catch.

### 4. Typecheck=3 nullable-narrowing pattern

The SDK returns many nullable types (`Position.Location?`, `ActivityRecording.Session?`, `FitContributor.Field?`). Always use the local-copy pattern:

```monkey-c
// ✅ Correct — compiler narrows the local copy's type
var s = mSession;          // inferred: ActivityRecording.Session?
if (s != null) {
    s.start();             // type narrowed to Session — safe
}

// ❌ Wrong — compiler cannot narrow mSession between the check and the call
if (mSession != null) {
    mSession.start();      // typecheck=3 error: still nullable
}
```

Apply this pattern to every nullable member before calling SDK methods on it.

### 5. Language: English only

All code comments and on-watch UI strings **must be in English**. This is a worldwide app. Do not add Spanish (or any other language) comments or hardcoded strings.

```monkey-c
// ✅ Good
// Accumulate elapsed time into the work accumulator.
app.mWorkMs = app.mWorkMs + elapsed;

// ❌ Bad
// Acumula el tiempo transcurrido en el acumulador de trabajo.
```

### 6. Single state owner

All race state lives in `HybridPacerApp`. Engine classes (`FSMController`, `PacingEngine`, `GpsSessionManager`, `HybridFitSession`) are **stateless mutators** — they read and write through `getApp()`, never hold their own copies of race data.

### 7. `FSMController` is the sole FSM mutator

Do not mutate `mFsmState`, `mRaceCycle`, `mLastTransitionMs`, `mWorkMs`, `mRestMs`, or `mTransitionTotalMs` from any file other than `FSMController.mc`.

---

## Project Architecture Overview

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full component map and data-flow diagrams. A quick summary:

```
HybridPacerApp (singleton, owns all state)
├── FSMController    — state transitions, duration accounting
├── GpsSessionManager — GPS + FIT session lifecycle, EMA smoothing
├── HybridFitSession  — 7 FIT developer fields, 1 Hz writer
└── PacingEngine     — dynamic pace target, pace delta, speed conversion
```

---

## Testing & Verification

There is no automated test suite yet (Connect IQ SDK does not support unit testing outside the simulator). Before submitting a PR:

1. **Build must pass** at `typecheck=3` and `optimization=3z` with zero errors and zero warnings.
2. **Simulate the full race** in the Garmin simulator (`monkeydo bin/HybridPacer.prg fr965`):
   - WARMUP screen shows target time and GPS status.
   - START transitions to RUN with pace display.
   - BACK/LAP cycles through TRANSITION_IN → STATION → TRANSITION_OUT → RUN (×8 cycles).
   - Pause/resume with START/STOP preserves all timers.
   - FINISH shows total time and W/R ratio.
   - Long-press UP in WARMUP opens the target-time menu; selection persists after restart.
3. **No Spanish strings** remain in `.mc` files or `strings.xml` — grep to confirm:
   ```bash
   grep -rn "comenzar\|seguir\|salir\|buscando\|objetivo\|Fase\|ritmo\|tiempo\|Atleta\|PAUSA\|reanudar\|ESTACION" source/ resources/
   ```
4. **FIT fields** all register without error in the simulator's `.fit` output.

---

## Submitting a Pull Request

1. Fork the repository and create a feature branch from `main`.
2. Make your changes following the conventions above.
3. Fill in the [pull request template](.github/PULL_REQUEST_TEMPLATE.md) — every checkbox must be ticked.
4. Keep PRs focused: one feature or bug fix per PR. Large changes should be discussed in an issue first.

---

## Commit Style

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add named station display for all 8 race exercises
fix: prevent pace display flicker when GPS fix is lost
docs: expand pacing engine worked examples
refactor: extract formatDuration helper from HybridPacerView
```

---

## Issue Reporting

Use the [bug report](.github/ISSUE_TEMPLATE/bug_report.md) or [feature request](.github/ISSUE_TEMPLATE/feature_request.md) templates. Always include:
- Garmin device model and firmware version
- Connect IQ SDK version used to build
- Steps to reproduce (for bugs)
