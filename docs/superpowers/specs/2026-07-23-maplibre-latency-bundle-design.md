# MapLibre Basemap Latency Bundle — Design

Date: 2026-07-23. Branch: `maplibre-perf` (off `2026.7.0`). Follows the spike
spec `2026-07-22-flutter-map-maplibre-ffi-spike.md` and the on-device
measurement session of 2026-07-22/23.

## Why this, why now

On-device measurement (iPhone 16 Pro, profile build) settled the pipeline
question: the render itself costs 3.5–5.7 ms average, 9.2 ms worst single
frame, at a sustained 120 fps. The render is never the bottleneck, so
double-buffering was dropped. What remains — and what is visible on the
phone as markers sliding against the basemap, worse in power-saving mode —
is **pipeline latency**: the camera-to-texture path is ~2–3 frames deep, and
the Dart bookkeeping (`_rendered`) claims the texture is fresher than it is,
so the residual transform systematically under-corrects.

The camera-to-texture chain today:

1. Build — flutter_map updates the camera (t = 0)
2. Post-frame callback — the push waits for the Flutter frame to end (~+1 frame)
3. Method-channel hop — `jump_to` on the platform thread (+~1 ms);
   **`_rendered` is stamped here, dishonestly**
4. Display-link wait — render happens at the next tick (up to +1 frame)
5. Render — ~4 ms, texture updated
6. Raster sampling — Flutter's raster thread picks up the texture at its next
   frame (up to +1 frame)

That is 17–25 ms at 120 Hz, doubling at 60 Hz — which is exactly why
power-saving mode makes the slip obvious.

Separately, the map renders ~120×/sec while completely stationary (~420 ms
of GPU work per second doing nothing) — measured via the
`rendersWithoutUpdate` / `idleEvents` counters.

## Goal

On the current method-channel architecture, without new native→Dart
plumbing:

- Cut camera-to-texture latency from ~2–3 frames to ~1 frame + ~5 ms
  (remove steps 2 and 4).
- Make the residual transform exact: `_rendered` may only be stamped with a
  camera that is actually in the texture (honest staleness).
- Stop rendering while idle (battery).
- Measure all of it: pipeline latency and render cadence become numbers in
  the diagnostics overlay / MLNDIAG log line, validated on device
  before/after.

## Decisions taken during brainstorm

- **Scope:** the latency bundle on the current architecture. `dart:ffi`
  same-frame rendering remains the endgame (upstream PR
  maplibre/maplibre-native-ffi#187 — closed unmerged — is the reference when
  we get there), justified later by the measured baseline this work
  produces.
- **Extras deferred:** camera prediction and a small over-render margin are
  out until `pushToTextureMs` says what they would need to cover. (The
  over-render 1.3 experiment was a measured net loss when tuned blind.)
- **Architecture:** merge honest staleness and on-demand rendering into one
  mechanism — render inside the `setCamera` handler and reply after — rather
  than keeping display-link cadence with a sequence echo. The reply itself
  becomes the proof the frame landed.
- **Branching:** all map work from here lives on `maplibre-perf`, based on
  `2026.7.0`.

## Design

### 1. Native: render inside `setCamera` (iOS)

`MLNBridge` gains a combined operation used by the `setCamera` method-channel
handler:

`jump_to` → `request_repaint` → render core (event drain + `render_update` +
stats) → reply.

- The render core is the existing `renderTick` body, factored so both the
  handler and the display-link tick share it.
- The reply carries `rendered: true/false` (the `render_update` status), so
  Dart knows whether the texture actually changed.
- The probe must fire `textureFrameAvailable` (the `onFrame` callback) on
  this path too — otherwise Flutter never re-samples the texture. This is
  the easy-to-miss detail.
- Threading: the channel handler and the display link both run on the main
  thread, so there is no concurrency between the two render paths and no
  locking. The ~4 ms render moves from the tick into the handler; total
  main-thread load is unchanged. Both paths rendering within one display
  interval occasionally is harmless at ~4 ms.

### 2. Native: display link demotes to animation-only (idle gating)

The display-link tick keeps draining the event queue but calls
`render_update` only when `_updateAvailable || _needsRepaint`. That covers
everything that changes the map without a camera push: tile arrivals, label
fade animations, style swaps. Camera-driven frames no longer depend on the
tick at all.

Known anomaly to resolve on device: at idle, ~90 of 120 ticks reported an
update available (`rendersWithoutUpdate` climbed only ~30/poll). Hypothesis:
rendering every tick was itself generating the next update event, so gating
breaks the loop and idle renders drop to ~0. The counters confirm or refute
this. **Fallback** if gating visibly freezes the map (events not firing as
documented): gate on `_needsRepaint` only.

### 3. Dart: push at build, bookkeeping unchanged

- `_pushCamera(camera)` is called directly from `build` instead of from a
  post-frame callback. flutter_map rebuilds this widget in the same frame
  the gesture moves the camera, so this removes ~1 frame of latency by
  itself. The send is fire-and-forget async — no setState-during-build
  hazard (`whenComplete` fires later). `_sameCamera` already suppresses
  redundant pushes from unrelated rebuilds; `_pushInFlight` + hold-newest
  already serialises pushes now that the reply takes ~5 ms.
- The stamping code is unchanged in shape — `_rendered = camera` on reply —
  but is now honest, because the reply happens after the render.
- Refinement: stamp only when the reply says `rendered: true`. A failed
  render (e.g. mid style-load) leaves `_rendered` on the old camera, keeping
  the transform correct relative to what the texture actually shows — a
  correctness improvement over today's behaviour.

### 4. Diagnostics: prove it

The diagnostics map (overlay + MLNDIAG log line) gains:

- `pushToTextureMs` — Dart-side rolling average of `_pushCamera` call →
  reply. This is the pipeline latency as a single number, and later the
  sizing input for any prediction/margin work.
- `cameraRenders` / `linkRenders` / `skippedTicks` — the render-cadence
  split. Idle success criterion: `linkRenders` flat while `skippedTicks`
  climbs.

Device validation protocol (same MLNDIAG streaming setup as the measurement
session):

1. Idle: `linkRenders` ≈ 0/sec after settling; map still completes tile
   loads and fades (gating fallback check).
2. Fling: slip between markers and basemap visibly reduced vs. the current
   build.
3. **Falsifiable test:** power-saving mode (60 Hz) should now look close to
   normal mode. The old bookkeeping error doubled in screen-space at 60 Hz;
   honest stamping removes exactly that term. If power-saving mode is still
   dramatically worse, the diagnosis was wrong somewhere.

### 5. Scope boundaries

- iOS only this round — the validated device path. The handler-renders
  design ports to Android later, but Android renders on a GL thread, so the
  "handler and render share the main thread" property does not carry over
  unchanged; that is part of the existing Android backlog item (surface
  lifecycle + EGLSync fence).
- No `dart:ffi` in this round.
- No prediction, no over-render margin (deferred, see above).
- Bottom-sheet-resize session recreation behaviour is unchanged.

### 6. Testing

- Dart widget tests with a mocked method channel:
  - `_rendered` is stamped only after the reply resolves, and only when the
    reply says `rendered: true`.
  - Pending-camera coalescing under slow replies (hold-newest still sends
    the final camera).
  - The push happens during build, not in a post-frame callback.
- Native side is validated by the device protocol in §4 — no new native test
  harness for a spike package.
- Existing `camera_conventions_test.dart` continues to pin the unit
  conversions.

## Risks

- **Event contract:** gating relies on `MAP_RENDER_UPDATE_AVAILABLE` /
  `needs_repaint` behaving as documented. Mitigated by the counters already
  in place and the `needsRepaint`-only fallback.
- **Channel reply latency:** replies now take ~5 ms + hop. `_pushInFlight`
  + hold-newest caps the effective push rate around 100–150 Hz, which is at
  or above the display rate; no user-visible cost expected. The
  `pushToTextureMs` metric watches this.
- **Double rendering:** a camera push and a gated link tick can both render
  in one display interval. At ~4 ms per render this is affordable; if the
  counters show it happening constantly, the link tick can additionally skip
  when a camera render already happened this interval.

## Device validation results (2026-07-23, iPhone 14 Pro, profile build)

Instrumentation for the session: a settings tile duplicating the basemap
toggle (the debug menu is blessed-user-gated in profile builds) and
on-screen phase chips (`log off / idle / fling / low-power`) that label the
MLNDIAG stream, so the person on the phone marks what each stretch of lines
measures.

### Round 1 — the bundle as merged

- **Idle: PASS.** `skip` +120/sec, `cam`/`link` flat, `repaint=false`; tile
  loads and fades still completed. The spec §2 anomaly resolved in favour of
  the hypothesis: rendering every tick was itself generating the next
  update event; gating broke the loop. Idle renders are ~0 (was ~120/sec).
- **Latency: PASS.** `push` (camera push → frame in texture) settled at
  1.9–3.9 ms during motion, vs ~17–25 ms (2–3 frames) before the bundle.
  Render cost on the 14 Pro: ~2 ms avg, 10.8 ms worst.
- **Fling: FAIL — new stutter.** Markers glided while the basemap juddered.
  Two causes found in the numbers and the frame math:
  1. `cam` +100/sec *and* `link` +120/sec during gestures — `needs_repaint`
     stays true while tiles load, so the "occasional" double render was
     constant during motion (~220 renders/sec on the main thread).
  2. Reply-time stamping makes the residual transform assume a camera one
     frame older than what the texture (updated mid-frame by the handler)
     actually shows at composite; the sign of the error flips with reply
     timing, and oscillation reads as stutter where the old pipeline's
     consistent lag read as slip.
- **Low-power: FAIL, worse** — consistent with the oscillation scaling by
  frame duration (16.7 ms at 60 Hz) and `push` rising to 5–7.6 ms throttled.

### The round-2 fixes (commit 13a0e8e)

- **Send-time stamping:** `_rendered` is stamped when the push is *sent*
  (the handler renders before replying, so send-time is the best estimate
  of texture content at composite), rolled back and retried on a failed
  render. Build order changed so the pushing frame's transform uses the
  stamp.
- **Double-render suppression:** the link tick skips when a camera render
  happened within 7 ms.

### Round 2 — after the fixes

- **Idle: PASS** (unchanged): `skip` +120/sec, all render counters frozen.
- **Fling at 120 Hz: PASS.** `cam` at frame rate, `link` near-silent
  (suppression works), `push` 2.4–5 ms. User verdict: "so much better — no
  unrendered edges when zooming, stutter almost if not fully gone." The
  zoom-edge artefact was the transform aiming at the wrong camera, not a
  missing over-render margin.
- **Low-power 60 Hz: PARTIAL.** Still "stuttery and lags behind the
  viewport, mainly when flicking and letting the map come to rest."
  Contributing: the 7 ms suppression window is shorter than the 16.7 ms
  interval, so double-rendering returns at 60 Hz (`cam` +60/sec, `link`
  +54/sec); throttled pushes (`push` 4–7 ms) lose the composite race more
  often, and each loss is a full 16.7 ms of pan distance.

### Follow-ups selected by this data

1. Make the link-suppression window adaptive to the actual display-link
   interval (~0.8×interval) instead of a fixed 7 ms.
2. Low-power residual: the composite race (texture landing vs raster
   sampling) is the remaining error source; candidates are vsync-aligned
   presentation or the dart:ffi same-frame render, judged against how much
   the adaptive window alone recovers.
3. The `_create`-does-not-reset-`_rendered` follow-up from the final review
   stands (session recreate with a stationary camera renders the style
   default until the camera moves).
