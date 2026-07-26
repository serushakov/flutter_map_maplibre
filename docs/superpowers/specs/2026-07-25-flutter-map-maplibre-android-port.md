# flutter_map_maplibre: Android port of the FFI architecture

**Date:** 2026-07-25
**Status:** in progress
**Prerequisite reading:** `2026-07-22-flutter-map-maplibre-ffi-spike.md` — the
Android sections there (borrowed-texture fix, TLS/webpki patch) solved the two
hard problems this port builds on.

## Problem

The Dart side of the plugin moved to the FFI architecture during the iOS work:
`FfiBasemapRenderer` owns runtime/map/session via dart:ffi on the Dart UI
thread, the method channel only does texture lifecycle
(`createTextures`/`disposeTextures`), and presentation is one native
`fmm_present(presenterId)` call per frame. The Android platform layer was never
ported — it still implements the spike-era API (`runMap` + a Kotlin
Choreographer loop driving everything through JNI). Result: on Android the
first channel call throws `MissingPluginException` and the map never appears,
even though the underlying renderer was proven working on the emulator.

## Design

Android implements the same three seams iOS has, arranged for EGL:

### 1. `createTextures` (Kotlin, platform thread)

Creates the `SurfaceProducer` (sized in physical pixels), then hands its
`Surface` to native `nativePresenterCreate`, which builds the EGL
display/config/context/window-surface, the GL back texture MapLibre will
render into, and the fullscreen-triangle blit program — the same machinery the
spike's `nativeCreate` had, minus everything mln. The presenter is registered
in a native registry keyed by the Flutter texture id, and the context is
**unbound** from the platform thread before returning (it will live on the
Dart UI thread from then on; an EGL context can be current on only one
thread). Response: `{ok, textureId, backTexture: <GL texture name>}` — the
`backTexture` field satisfies the shared Dart contract; on Android it is a GL
name rather than an address and Dart never dereferences it.

### 2. Attach (native helper, Dart UI thread)

Unlike Metal's descriptor (one texture pointer), the OpenGL descriptor wants
`{EGLDisplay, EGLConfig, share_context, eglGetProcAddress, texture, target}` —
all process-global native handles that Dart would only shuttle back down
unchanged. So the descriptor never crosses into Dart: `libmln_jni.so` exports

```c
int32_t fmm_attach(int64_t map, int64_t presenter_id, int64_t* out_session);
```

which builds the descriptor from the presenter's stored EGL state, makes our
context current on the calling (Dart) thread, and calls
`mln_opengl_borrowed_texture_attach`. Called via FFI from
`FfiBasemapRenderer.create` in the Android branch, so owner-thread affinity is
satisfied by construction. The session pointer comes back through the
out-param; the return value is the mln status for diagnostics.

### 3. `fmm_present` (native, Dart UI thread)

`render_update` leaves the *session's* context current on the calling thread
(observed in the spike), so present re-makes ours current, syncs, blits the
borrowed texture to the window surface, and `eglSwapBuffers`. No hand-rolled
buffer ring: the `SurfaceProducer` BufferQueue is the swapchain, and
`eglSwapBuffers` publishes only completed frames — Android gets for free what
iOS needed the CVPixelBuffer triple ring for. Returns blit wall-clock ms, or a
negative error code (unknown id / makeCurrent failed / GL error / swap failed /
surface invalidated), feeding the same `MLNERR` failure-streak reporting as
iOS. `fmm_debug_fill` (clear the back texture via a scratch FBO) is ported too
— it isolates the presentation path from MapLibre exactly like the iOS
Checkpoint B probe.

### Symbol visibility and loading

- `System.loadLibrary` dlopens with `RTLD_LOCAL`, so `DynamicLibrary.process()`
  cannot see the symbols on Android. A shared loader (`mln_library.dart`)
  returns `DynamicLibrary.open('libmln_jni.so')` on Android and `process()`
  elsewhere; all four FFI call sites use it.
- After the old JNI loop is deleted, the only native references to most mln_*
  functions disappear, and `--gc-sections` would strip exactly the functions
  Dart calls. A keep-alive table in `mln_jni.cpp` (`__attribute__((used))`
  array of function pointers covering every Dart-looked-up symbol) pins them.
  Verified post-build with `llvm-nm -D`.

### Threading model

Everything mln lives on the Dart UI thread (owner-thread affine, owner =
whoever called `mln_runtime_create` = Dart). The Dart UI thread owns no other
GL state, so parking our EGL context there is safe. Steady-state frame:
`render_update` (session context becomes current) → `fmm_present` re-binds
ours → sync → blit → swap. Two `eglMakeCurrent` per frame — tens of µs.

Known hazard: `eglSwapBuffers` on a BufferQueue producer blocks when the queue
is full (compositor not draining). The render-admission design already
prevents presenting faster than the widget composites; swap time shows up in
`blitMs` diagnostics so a stall is visible.

### Sync

v1 keeps the spike's `glFinish` (empirically sufficient); follow-up replaces
it with a `glFenceSync` created after `render_update` and waited on in
present, which is the formally correct cross-context ordering.

### Surface lifecycle (MVP)

`SurfaceProducer` callbacks mark the presenter invalid; `fmm_present` then
returns an error and the Dart failure-streak path surfaces it. In-place EGL
window-surface recreation is a follow-up (needs a platform-thread/Dart-thread
lock). Resize is already handled above this layer: the widget disposes and
recreates, same as iOS.

### Deleted

`runProbe`/`runMap`/`setCamera`/`setStyle`/`mapDiagnostics`/`disposeMap`
handlers, `MapLibreRenderer.kt`, `EglProbe.kt`, and their JNI entry points.
`nativeAndroidInit` stays (rustls needs the Android context before any HTTP),
as does the vendored verifier jar and the webpki-roots patch.

## Present latency (2026-07-25, after first device testing)

On device, the basemap visibly trailed the marker layers during pans. Two
compounding causes, both rooted in the same iOS assumption:

1. **Presentation is not same-frame on Android.** iOS's texture contract is
   pull-based — the engine calls `copyPixelBuffer()` while rasterizing the
   current frame, so a presented frame is on screen in that same frame
   (verified by the spike's Checkpoint B). Android is push-based:
   `eglSwapBuffers` queues into a BufferQueue the engine latches later.
   Measured empirically on the OnePlus 8 Pro by feel-tuning a live knob:
   **exactly one frame** (`FfiBasemapRenderer.androidPresentLatencyFrames`,
   default 1; the example app has a FAB cycling 0–3 — the setting where the
   marker locks to the map is the true depth). The renderer holds each
   presented camera in a FIFO of that depth and publishes
   `lastRenderedCamera` as entries fall off; tick skip-branches drain one
   entry per tick so a gesture's final frame still promotes.

2. **The widget's identity shortcut assumed same-frame presents.** On a
   successful unbiased render, build placed the texture at identity —
   "the front buffer shows this camera now" — bypassing the residual
   transform entirely, so the renderer-side correction was invisible on
   exactly the frames that mattered. On Android every frame now goes through
   the residual transform against the latency-corrected `shown` camera; iOS
   keeps the shortcut.

Consequence of correct placement: during fast flicks the on-screen frame is
one frame old, so a `velocity × 8.3ms` strip at the leading edge is bared
(~17 logical px at 2000 px/s, 120 Hz). Mitigation if it ever matters: an
`overRenderFactor` margin plus the existing lead-bias machinery, which
activates automatically once a margin exists.

Also measured while investigating (uncapped, full-screen 1440×3168):
~10–13 ms per render_update on the UI thread regardless of scene content,
28–46 ms spikes on tile-upload frames, `building-3d` fill-extrusion only
~0.6 ms at mid-zoom. A 30 fps frameCap without margin felt far worse than
uncapped (33 ms placement error before the fixes above + bared edges) and
was reverted.

Follow-up wins, in order applied:

- **Fence instead of glFinish** in fmm_present: steady render avg ~9–10 →
  ~7.2 ms, steady max 28–46 → ~11.5 ms. The glFinish drained the pipeline
  every frame and killed cross-frame GPU/CPU overlap; the fence is created
  in the session's context (still current after render_update) and waited
  server-side in ours.
- **overRenderFactor 1.1** in the example so the lead bias keeps the
  leading edge covered during flicks (the placed frame is one present old
  on Android) — confirmed by feel to remove the bared strip.
- **`renderScale`** widget parameter: render below native dpr and let the
  compositor upscale. 0.7 was visually detectable on the 3.5-dpr panel;
  kept at 1.0 by default, available as a fill-rate lever.
- **The dominant "lag" was debug-mode overhead.** All along the example was
  a debug (JIT) APK; the `--profile` build with margin at native resolution
  was judged "much better" on the same device. Android perf verdicts count
  only from profile builds.

## Checkpoints

1. **Symbols** — `llvm-nm -D libmln_jni.so` shows `mln_*` + `fmm_*`;
   `probeMaplibreFfi()` returns ok on device.
2. **Presentation without MapLibre** — `FfiPresentProbe` hue sweep via
   `fmm_debug_fill`/`fmm_present` renders smoothly in a `Texture` widget.
3. **Full map** — example app on the OnePlus 8 Pro: `attachStatus: 0`,
   `styleLoaded: true`, tiles visible (OpenFreeMap liberty), manual pan +
   `adb input swipe` + auto-pan all move the map.
4. **Physical-device unknowns** — first real hardware for this renderer:
   Adreno 650 EGL behavior, webpki TLS on a real network, pan performance.
