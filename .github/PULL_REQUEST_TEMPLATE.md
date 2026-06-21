## Summary

<!-- Describe what this PR does and why. Link the issue it resolves if applicable. -->

Closes #

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / cleanup
- [ ] Documentation
- [ ] Other (describe below)

## Changes made

<!-- List the key files changed and what was changed in each. -->

- `source/...` — 
- `resources/...` — 

## Checklist

### Build & quality
- [ ] Project builds successfully at `typecheck=3` and `optimization=3z` with **zero errors and zero warnings**
- [ ] No `new` calls introduced in hot paths (`onUpdate`, `onPosition`, `tickFitMetrics`, or any method they call)
- [ ] No `switch`/`case` statements added — all dispatch uses `if`/`else if`
- [ ] No `Lang.Dictionary` used as a domain structure
- [ ] All nullable SDK types use the local-copy narrowing pattern (`var x = mNullable; if (x != null) { ... }`)

### Language
- [ ] All new code comments are in **English**
- [ ] All new on-watch UI strings are in **English**
- [ ] No Spanish (or other language) text added to `.mc` files or `strings.xml`

### Testing
- [ ] Simulated a full race in `monkeydo fr965` — WARMUP → all 8 cycles → FINISH
- [ ] Pause/resume tested if relevant to this change
- [ ] FIT fields register without error in the simulator output (if FIT-related change)
- [ ] No regression in unrelated states

### FIT fields (if adding/modifying)
- [ ] New field ID is unique and does not reuse an existing ID
- [ ] `FIT_ID_*` constant in `HybridFitSession.mc` matches `id` in `fitcontributions.xml`
- [ ] String resources added to `strings.xml` for title/label/unit
- [ ] `tickFitMetrics()` write uses the null-guard pattern and contains no `new`

## Screenshots / recordings (if UI change)

<!-- Paste simulator screenshots or describe what the UI looks like. -->
