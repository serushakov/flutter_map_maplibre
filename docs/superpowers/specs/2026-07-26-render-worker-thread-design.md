# Render Worker Thread (Android) — Design

**Package:** `packages/flutter_map_maplibre` · **Branch:** `maplibre` (worktree `.claude/worktrees/maplibre-perf`) · **Date:** 2026-07-26

## Problem

On Android, every admitted vector render executes synchronously on the UI
thread inside the widget's build path. Measured on OnePlus 8 Pro (profile
build, Vedu osm-liberty style, soak-recorder frame timings):

| hard pan | raster tiles | maplibre |
|---|---|---|
| fps | ~98–118 | **~46** |
| UI build avg | ~2.9 ms | **12–14 ms** |
| UI build p95 | ~5 ms | **~27 ms** |

During a hard pan the admission gate admits ~19 renders/s and each costs
~10 ms (`renderMsAvg`) on the UI thread. Roughly every 2–3rd vsync at
120 Hz carries a build that blows the 8.3 ms budget; steady state lands at
~46 fps. Style pruning and admission rate caps shrink the stall but cannot
remove it; only moving the render off the UI thread restores raster-class
pan fps.

## Why not a Dart isolate

The mln C API is owner-thread affine: `MLN_STATUS_WRONG_THREAD` is checked
against the OS thread that created the runtime, and MapLibre core keeps
thread-local state (its RunLoop is bound to the owner thread). Dart
isolates have no fixed OS thread — the VM schedules isolate event-loop
turns on a shared thread pool, so a background isolate's second message
may run on a different thread than its first. mln calls from a background
isolate would fail intermittently. The root isolate only works today
because Flutter pins it to the UI thread.

Patching our maplibre-native-ffi fork to drop the check is rejected: the
check guards real invariants, removing it does not remove them.

**Therefore: a dedicated native worker thread (C++) owns runtime, map, and
render session.** Dart keeps choosing every camera and placing every
texture; the worker is a dumb executor.

## Scope

Android only. iOS keeps the current synchronous `FfiBasemapRenderer`
(validated same-frame present via pull-based `copyPixelBuffer`; no measured
need). The `BasemapRenderer` seam hides the difference; iOS can adopt the
worker later if profiling justifies it. `FfiBasemapRenderer` stays fully
functional on Android so the example app can A/B the two renderers.

## Sync contract (unchanged)

The property that keeps markers glued is: Dart chooses the camera for every
render, knows which camera each presented texture holds, and places the
texture with the residual transform against the current camera. The worker
changes *when* renders execute, never *what* is known about them.
Staleness note: today's hard-pan texture is refreshed only every 50–100 ms
(admits throttled by the choked UI thread); with the worker a presented
texture is ~25–30 ms stale but refreshed every ~12 ms — the leading edge
gets fill faster, not slower.

## 1. Worker protocol — `fmm_worker.cpp` (next to `mln_jni.cpp`)

One worker per renderer session: `std::thread` + `std::mutex` +
`std::condition_variable` + FIFO command queue. Completions post to the UI
isolate via `Dart_PostCObject_DL` on a `SendPort` handed over at worker
start. Vendor `dart_api_dl.c` (+ headers) from the Dart SDK into the
plugin's cpp dir; add to CMakeLists; Dart calls the init export once with
`NativeApi.initializeApiDLData`.

Commands, executed strictly in post order:

| command | payload | executes |
|---|---|---|
| `CREATE` | width, height, scale, styleUrl, presenterId | runtime create (`:memory:` cache), map create, `fmm_attach` — all on the worker thread, which thereby becomes the owner thread |
| `PUMP` | — | `mln_runtime_run_once` + drain `mln_runtime_poll_event` |
| `JUMP` | camera (lat, lng, zoom, bearing), generation | `mln_map_jump_to` + `mln_map_request_repaint` |
| `RENDER` | generation | `mln_render_session_render_update` + `fmm_present` |
| `SET_STYLE` | url | `mln_map_set_style_url` + request_repaint |
| `DESTROY` | — | destroy session/map/runtime, post `DESTROYED`, exit thread (detached) |

**Coalescing rule (the only scheduling logic):** when a `RENDER` reaches
the head of the queue and a newer `RENDER` sits behind it, the older one is
skipped and posts `SUPERSEDED{gen}`. `JUMP`s are cheap and all apply in
order. Latest-wins for the 10 ms op; a backed-up worker never renders a
stale camera.

Ordering preservation: the Dart facade posts the same triplet the sync code
executes per admission — `PUMP, JUMP, RENDER` — so the stale-MAP_IDLE drain
(pump before jump) holds by FIFO construction.

Completions: `CREATED{runtimeStatus, mapStatus, setStyleStatus,
attachStatus}`, `EVENTS{updateAvailable, idleSeen, needsRepaint,
drawCalls}`, `RENDERED{gen, renderMs, blitMs, status, presentRc}`,
`SUPERSEDED{gen}`, `DESTROYED`.

## 2. Dart facade — `WorkerBasemapRenderer implements BasemapRenderer`

New file `lib/src/ffi/worker_basemap_renderer.dart`. Keeps the exact state
machine of `FfiBasemapRenderer` — flags, pending-camera FIFO, diagnostics —
but flag updates come from port messages instead of return values. All
pure logic (`decideTick`, `decideSleep`, `frameCapSatisfied`, admission,
settle, lead bias) stays in its current files with its current tests.

- `render(camera)`: posts `PUMP, JUMP(gen++), RENDER(gen)`, records
  `gen → camera`, returns `false` (never synchronously on screen — the
  Android widget path already assumes this via `syncPresent = false`). On
  `RENDERED{gen, ok}` the completion handler runs today's
  `_publishRendered` logic: pending-camera FIFO of depth
  `androidPresentLatencyFrames`, `_gapBeforePresent`/`_pipelineBusy`
  heuristic keyed on **completion arrival times**. Expect re-tuning with
  the example app's existing latency-cycle FAB.
- `tick()`: posts `PUMP` (plus `RENDER` when `decideTick` says render and
  the frame cap allows), returns "a `RENDERED` completion arrived since
  the last tick" so the widget rebuilds by polling — no interface
  addition; during pans there is a build every frame anyway.
- `canSleep` / `pumpWork()`: same `decideSleep` over the same flags, now
  updated by `EVENTS` messages. Insurance pump posts `PUMP` every 5 s.
- Frame cap: enforced in Dart before posting `RENDER`, exactly as today
  (`_sincePresent` measured post-to-post).
- Failure handling: `RENDERED` with a non-OK status feeds the existing
  `_noteFailure` streak accounting; the unpublished-jump sleep veto and
  tick retries already cover lost renders.
- `dispose()`: posts `DESTROY` and closes the `ReceivePort` when
  `DESTROYED` arrives (2 s fallback timer so a lost message never pins the
  isolate). **Amended from the original design:** no injected cleanup
  callback. The Kotlin plugin holds one presenter per engine and
  `createTextures` disposes the previous presenter itself, so a deferred
  callback could destroy a successor presenter on the resize path. The
  widget keeps today's call order (`dispose()` then `disposeTextures()`);
  destroying the presenter before the worker finishes tearing down the
  session is safe because mln's own GL context keeps the share group (and
  the back texture) alive, and a straggler `fmm_present` fails soft through
  the presenter-registry mutex. Create-after-dispose on the same facade
  instance (the widget's resize path) starts a fresh worker + port.
- New diagnostics: `rendersInFlight` (`RENDER`s posted minus
  `RENDERED`/`SUPERSEDED` processed), `superseded` (count),
  `completionLagMs` (facade stopwatch, `RENDER` post → `RENDERED`
  processed, EWMA + max).

### Interface change (the only one)

`BasemapRenderer.create()` becomes `Future<bool>`. `FfiBasemapRenderer`
returns a synchronously-completed future; iOS behavior is otherwise
untouched.

## 3. Widget changes — `maplibre_basemap.dart`

- `_create` awaits `_renderer.create(...)`.
- Default factory: `Platform.isAndroid ? WorkerBasemapRenderer.new :
  FfiBasemapRenderer.new`.
- `_settleForced` clears when the forced admission is **issued** (the
  facade accepted the render request), not when it lands. A lost render is
  covered by the unpublished-jump sleep veto and tick retries.
- Example app: FAB to flip between `WorkerBasemapRenderer` and
  `FfiBasemapRenderer` at runtime (recreates the session) for on-device
  A/B.

## 4. Risks

- **Geographic drift cannot return**: same cameras, same residual
  placement, `lastRenderedCamera` still written only after a real present.
- **Latch-depth mistuning**: the completion-arrival timing base is new;
  the existing latency-cycle tool and the dot-flick eyeball test cover
  re-tuning.
- **Completion starvation under load**: visible as `completionLagMs` /
  `queueDepth` in the stats wall.
- **Teardown races**: bounded by the presenter registry mutex built for
  the Kotlin surface-loss path; worst case is a soft-failed present
  (`MLNERR`, recovered-streak logging already in place).

## 5. Validation gate

- **Unit tests**: drive `WorkerBasemapRenderer` with a fake command sink +
  scripted completions: publish FIFO ordering, superseded bookkeeping,
  flag updates from `EVENTS`, frame-cap deferral, create/dispose
  lifecycle, create-after-dispose. Risk concentrates in Dart precisely
  because the worker is dumb.
- **On-device A/B** (same soak-rec protocol as the measurement above):
  hard-pan fps **≥ 90** with UI build avg back near ~3 ms (the raster
  thread becomes the ceiling); `underRenderPx` no worse than the sync
  renderer; flick-the-dot test after latch re-tuning.
