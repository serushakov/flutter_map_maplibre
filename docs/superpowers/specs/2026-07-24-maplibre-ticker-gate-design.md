# MapLibre basemap ticker gate — design

**Date:** 2026-07-24
**Branch:** `ticker-gate` (off `power-soak`, worktree `.claude/worktrees/maplibre-perf`)
**Scope:** `packages/flutter_map_maplibre` only (Dart; no native/FFI changes)

## Problem

`MapLibreBasemap` starts a Flutter `Ticker` at session create and never stops
it. An active `Ticker` requests a vsync frame every cycle, so the whole app
pipeline — build, raster, GPU submit — runs at the display's native rate
(120Hz on ProMotion) even when `tick()` decides `skipIdle` and does nothing.

The power-soak A/B (2026-07-23, iPhone15,2, 15-minute legs) measured the
cost. Settle phase, no input:

| renderer | idle fps | thermal after 15 min | battery |
|----------|----------|----------------------|---------|
| maplibre | 119.9    | 2 (serious)          | −10 %   |
| raster   | 16.1     | 0 (nominal)          | −5 %    |

Diagnostics from the maplibre leg: ~600 `skippedTicks` per 5-second sample
during settle — 120 wasted frames a second. The renderer's per-tick dedup is
already perfect; the ticker driving it is the whole problem.

## Decision

Park the ticker exactly on MapLibre's own idle signal (`MAP_IDLE`), restart
it whenever new work is created, and back both with a slow insurance pump.
Idle gating only — the active-interaction frame rate is untouched (a 60fps
cap was considered and deferred; it risks visible stutter on 120Hz displays
and the idle cost dominates).

## Why trusting MAP_IDLE is safe (research results)

- **Emission site** (`maplibre-native/src/mbgl/map/map_impl.cpp`,
  `onDidFinishRenderingFrame`): after every finished frame in continuous
  mode, if the frame needs no repaint, no camera transition is in flight,
  and the renderer is fully loaded (`RenderMode::Full`), the map fires
  `onDidBecomeIdle`. maplibre-native-ffi pushes it verbatim into the polled
  event queue as `MLN_RUNTIME_EVENT_MAP_IDLE` (`ffi/src/map/map.cpp`). It is
  precisely "the last frame I rendered was final", not a heuristic.
- **Failed tiles do not block it.** Upstream `tile.hpp` documents that a
  tile whose load errored still sets `loaded = true` and counts as complete
  in `TilePyramid::isLoaded()`. Offline or tile-server-down still reaches
  `RenderMode::Full`, so the map still idles and still parks.
- **On-device behaviour matches.** The maplibre soak leg observed 389
  `idleEvents` over 15 minutes: 1–3 fired right as each gesture's aftermath
  finished loading, then zero events/renders with `needsRepaint=false` for
  the rest of every settle stretch; during pan it re-fired ~6×/s, so the
  map re-idles quickly between gestures. Prompt, repeatable, no anomalies.
- **The one caveat:** `mln_runtime_run_once` is the only driver of
  MapLibre's owner-thread task queue — parked means fully frozen. Safe at
  MAP_IDLE (nothing in flight by definition), except HTTP tile expiry: a
  refresh coming due while parked simply doesn't run. Consequence is a
  stale basemap tile, bounded by the insurance pump below.

## Design

### Park rule

The renderer exposes `canSleep`: true when a `MAP_IDLE` event has been seen
since the last camera jump AND `updateAvailable` and `needsRepaint` are both
clear. Because `_pumpEvents()` fully drains the queue every tick, an update
queued behind the idle event vetoes the park in the same pump — no race.
The decision is a pure function alongside the existing `decideTick`,
testable without FFI. The widget checks `canSleep` after each `tick()` and
stops the `Ticker` when it is true.

### Unpark rule

Restart the `Ticker` (idempotent) whenever our side creates work:

- `render()` performed an actual camera jump. A same-camera early-return
  build (theme rebuild, unrelated setState) does not unpark.
- `setStyle` (light/dark swap).
- `create` (session start — current behaviour).

Camera changes always arrive through `build → render()`, including
flutter_map fling momentum and sheet-drag `visibleRect` shifts, so there is
no wake path outside these three. The idle latch clears on every camera
jump, so each park requires a fresh `MAP_IDLE`.

### Insurance pump

While parked, a periodic `Timer` (5 s) calls a renderer method that pumps
the event queue *without rendering* and reports whether work appeared
(`updateAvailable || needsRepaint`); if so, the widget restarts the ticker.
Timers schedule no frames, so parked cost is ~0.2 event pumps/second. This
bounds tile-expiry staleness at 5 s and backstops any mis-modelled event.
The timer runs only while parked: started on park, cancelled on unpark and
dispose.

### Observability

`diagnostics()` gains:

- `tickerActive` (bool) — current gate state.
- `parks` (int) — cumulative park transitions.

Both flow automatically into the soak overlay and JSONL samples via the
existing `maplibreDiagnostics` channel.

### Failure posture

- Never-parks bug → today's behaviour exactly; no regression possible.
- Parks-too-eagerly bug → bounded by the three unpark paths plus the 5 s
  pump; worst case a briefly-stale or late-fading tile, never a frozen map.

## Testing

- Pure-function tests for the sleep decision (idle latch × flag
  combinations), next to the existing `decideTick` tests.
- Fake-renderer widget tests: ticker stops after the fake reports
  `canSleep`; restarts on camera change, on style change, and when the
  insurance pump finds work; timer cancelled on unpark/dispose.
- Acceptance: re-run a 15-minute maplibre soak leg (script v2, same start
  camera) and compare with `tools/soak_report.dart`. Success = settle-phase
  fps drops from ~120 to raster-like (≤ ~20), thermal stays at 0–1, and
  `parks` > 0 in the JSONL. Interaction phases must still render (camera
  renders present, no blank-map reports).

## Out of scope

- Active-phase frame-rate capping (60fps) — possible follow-up.
- Any change under `ios/`, `lib/` (app side), or native/FFI code.
- The power-soak branch itself stays free of plugin changes; this work
  branches off it only to inherit the measurement harness.
