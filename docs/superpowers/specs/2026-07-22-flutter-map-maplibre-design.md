# flutter_map_maplibre — native vector basemap for flutter_map

Date: 2026-07-22
Status: design approved; spike scope revised after research — see "Research
findings" below. Implementation plan:
`docs/superpowers/plans/2026-07-22-flutter-map-maplibre-probes.md`

## Problem

The map renders raster tiles through `flutter_map`'s `TileLayer`, served from a
self-hosted tileserver-gl instance at `tiles.example.com`. Two costs
motivate changing this:

- **Visual quality.** Raster tiles are fixed-zoom bitmaps. Zoom is stepped
  rather than continuous, intermediate zoom levels are upscaled and soft, and
  labels tilt with the map when it rotates.
- **Performance and bandwidth.** A raster pyramid at @2x/@3x is heavy on the
  wire, needs a 512 MB on-device cache, and costs decode work on the raster
  thread — which already runs over budget on Android.

Styling control and tile-serving cost are explicitly *not* motivations.

## Constraints from the existing app

The map is `MainMapMapView` (`lib/screens/main_map/main_map_map_view/`). Only
the basemap comes from tiles; **everything else is Flutter**:

- Transport markers with tweened positions, gesture detectors and long-press
- Stop markers with tooltips, route stops, favourite-location dots, start/end
  pins, scooter markers, user-location marker
- Polylines, and a zoom-threshold-driven z-order flip between marker layers
- Camera owned by `AnimatedMapController`, with focus modes
  (`MapFocusMode.user`, `userDirection`, `boarding`), rotation, and
  padding-aware fitting
- The whole `FlutterMap` sits in an `OverflowBox` that is resized every frame
  as the bottom sheet drags

Any design that disturbs this overlay stack carries large, diffuse risk. The
chosen design disturbs none of it.

## Options considered

**A. On-device tile producer.** MapLibre's `MapSnapshotter` renders vector
tiles into raster tiles on-device, behind a custom `TileProvider`. Zero
architectural risk, big bandwidth win, works offline.

*Rejected.* It reproduces the existing tileserver-gl setup locally without
changing the *feel*: zoom stays stepped and labels still tilt, because an XYZ
tile is a north-up square that `flutter_map` rotates wholesale. Label seams at
tile boundaries are also a known defect of tile-mode rasterization
(maplibre-native#284, #644, tileserver-gl#344), only partly mitigated by the
`tileMargin: 64` over-render that production already uses. The upside was real
but did not include the thing actually wanted.

**B. Native map owns camera and overlays.** Move markers and polylines to
MapLibre style layers. Perfect fidelity and sync, but the largest possible
rewrite of the overlay stack, and it discards the Flutter widget markers
entirely. Rejected on cost.

**C. Native basemap in a Flutter texture, Dart owns the camera.** *Chosen.*
Detailed below.

## Chosen design

`NativeBasemapLayer`, a drop-in replacement for `MapTileLayer` inside the
existing `FlutterMap`. `AnimatedMapController`, the focus modes, every marker
layer and the `OverflowBox` behaviour are untouched.

### Why a texture, not a platform view

The basemap is not interactive — Flutter already owns every gesture, tap,
long-press and the camera itself. Flutter's external-texture path is the
documented fit for non-interactive graphics streams with Flutter widgets
composited on top. A `PlatformView` would be heavier and would invert camera
ownership.

### Native side

A headless MapLibre renderer with a continuous render loop, drawing into a
Flutter-registered texture, pointed at the existing
`tiles.example.com/styles/osm-liberty/style.json`. Glyphs, sprites and
`/data/estonia-vector/{z}/{x}/{y}.pbf` resolve through the style exactly as
they do server-side today — no new hosting.

- **Android:** `TextureRegistry.SurfaceTextureEntry` → `Surface`.
- **iOS:** `FlutterTexture` with `copyPixelBuffer`, backed by an
  IOSurface-backed `CVPixelBuffer` via `CVMetalTextureCache`, so MapLibre's
  Metal renderer writes with no CPU copy.

### Dart side, and the sync mechanism

Camera updates stream from Dart to native. Native returns each frame **stamped
with the camera it was rendered at**.

Flutter never displays a frame naively. It applies a residual affine transform
derived from `(renderedCamera → currentCamera)`. In Web Mercator, pan, rotate
and zoom are *exact* affine transforms of the rendered image, so the basemap
stays geometrically correct and pinned to the markers **within the same Flutter
frame**, despite its pixels being one or two frames stale. Only symbol layout
is momentarily stale: labels scale slightly during a fling and snap crisp as
the render loop catches up — the same behaviour MapLibre GL JS exhibits between
re-layouts, so it reads as normal vector-map behaviour rather than as lag.

Because native renders continuously rather than on-settle, the residual only
ever covers a frame or two of motion, so the over-render margin is ~10% rather
than the ~40% a settle-based design would need.

This is the crux of the design. It is what makes a Dart-owned camera and a
natively-rendered basemap coexist without the marker/basemap divergence that
platform-view map plugins suffer.

### What this buys

True fractional zoom; rotation handled by MapLibre's real label engine (upright
text, street labels flipping to read left-to-right); runtime dark mode via style
swap rather than a second tile pyramid; and vector-tile bandwidth in place of a
raster pyramid.

### Package structure

Strictly independent — no app dependencies, extractable and publishable.

```
packages/flutter_map_maplibre/
  lib/           NativeBasemapLayer, camera bridge, controller
  ios/           Swift — FlutterTexture + MapLibre Metal renderer
  android/       Kotlin — SurfaceTextureEntry + MapLibre renderer
  example/       standalone harness, no host-app dependencies
```

Named for the `flutter_map_<capability>` convention used across the plugin
ecosystem (`flutter_map_marker_cluster`, `flutter_map_location_marker`,
`flutter_map_tile_caching`, `flutter_map_animations`). The bare `maplibre_*`
namespace is avoided: it collides with `maplibre_gl` and `maplibre`, which
provide a native map that *owns* the camera — the opposite of this package.

MapLibre Native, not Mapbox GL Native: same style spec and vector tiles, no
per-MAU billing, and it matches the existing self-hosted setup.

## Research findings (2026-07-22, post-approval)

Source-level research into MapLibre Native on both platforms changed the spike's
shape. The architecture above still stands; how we get there does not.

**iOS — the graphics path is real.** `mbgl::mtl::RenderableResource` is a clean
seam, and MapLibre derives its Metal pipeline colour format from whatever
texture is attached (`src/mbgl/shaders/mtl/shader_program.cpp`), so a BGRA8Unorm
texture from `CVMetalTextureCache` works with no swizzle and no blit. True
zero-copy. `MLNMapSnapshotter` is confirmed dead for per-frame use — full CPU
readback via `MTLTexture::getBytes`.

**Android — blocked at the map-object level.** `MapRenderer.onSurfaceCreated`
accepts an arbitrary `Surface`, and the OpenGL backend discards the window
entirely, so the renderer half is fine. But `MapLibreMap`, `Transform`,
`Projection` and `CameraChangeDispatcher` are package-private and require a
concrete `MapView`. MapLibre's own View-free rendering attempt (PR #3333, 2238
lines) is an abandoned draft. The public-API workaround is `VirtualDisplay` +
`Presentation`, which costs a SurfaceFlinger composite hop — aimed directly at
an Android frame budget that is already over.

**`maplibre-native-ffi` is the right destination, and is not shipped.** It is a
C ABI over `mbgl` that bypasses both platform SDKs, dissolving the Android
blocker and unifying both platforms under one Dart-owned camera model. Android
is a first-class CMake target with EGL and Vulkan backends, and
`mln_opengl_surface_attach` takes an `EGLSurface` created from any `Surface`.
But: no prebuilt artifacts for iOS or Android, nothing published to Maven, an
unwritten installation guide, pre-1.0 with an explicitly unstable ABI
(`mln_c_version() == 0`), Android built-but-never-tested in its own CI, and
`arm64-v8a`/`x86_64` only — adopting it forces dropping `armeabi-v7a`.

**No prior art exists.** Both `flutter-maplibre-gl` and `josxha/flutter-maplibre`
are pure `PlatformView` on both platforms, with zero `TextureRegistry` usage;
their "textureMode" is MapLibre's own `TextureView`-vs-`SurfaceView` flag and is
unrelated to Flutter external textures.

Two further constraints surfaced:

- **Attribution is a legal requirement** that `MLNMapView` currently provides
  for free. A texture-based basemap has no view, so it must be re-implemented
  in Flutter.
- Both MapLibre's offscreen path and the FFI call `waitUntilCompleted()` per
  frame, serialising CPU-record against GPU-execute. Replacing it with
  `addCompletedHandler` is trivial and mandatory.

### Revised spike

Both research passes converged on the same load-bearing unknown, and it is the
same one under *every* candidate architecture:

- Android: does `eglCreateWindowSurface` succeed on Flutter's
  `ImageFormat.PRIVATE` ImageReader surface?
- iOS: does a `CVMetalTextureCache`-derived texture report
  `MTLTextureUsage.renderTarget`?

Neither involves MapLibre. So the spike is reduced to **two probes of ~50 lines
each** that answer these directly, deferring the architecture choice until
there is data. This supersedes the three-leg spike described below, which
assumed the architecture was already settled.

## The spike (superseded — retained for rationale)

The spike's purpose is to kill or confirm the riskiest assumption quickly. That
assumption is **not** "can MapLibre render vector tiles" — tileserver-gl already
proves it — but:

> Can MapLibre's rendered frames reach a Flutter `Texture` on both platforms at
> 60fps, with the residual transform holding markers visually pinned during a
> fling?

Everything else in the design is downstream of that answer.

Built in `packages/flutter_map_maplibre/example/`, at throwaway quality.

1. **iOS first**, as the riskiest leg. `FlutterTexture` + IOSurface-backed
   `CVPixelBuffer` + `CVMetalTextureCache`, rendering the live `osm-liberty`
   style. Success: a moving map in a `Texture` widget with no CPU-side copies.
2. **Android second.** `SurfaceTextureEntry`, same style. Cheaper leg; mainly
   confirms the abstraction is not iOS-shaped.
3. **Camera bridge and residual transform**, driven from a real `FlutterMap`
   with a handful of dummy markers. Fling it. Markers must stay welded to the
   basemap. This is the decisive test.

### Measurements

On a physical device per platform, against the current raster-tile baseline
(the existing `perf.sh` harness):

- Frame build and raster times
- GPU memory
- Thermals over a sustained pan session
- Bytes on the wire, vector vs raster, for an identical pan/zoom session

### Kill criteria

Agreed in advance so the spike can fail honestly:

- No zero-copy path on iOS without private API
- Raster-thread cost worse than the current baseline (Android already runs over
  16 ms)
- Marker/basemap divergence during a fling that the residual transform cannot
  close

### Explicit non-goals for the spike

Caching, offline support, dark-mode style swap, Remote Config gating, error and
fallback paths, rotation label handling, and public API design. All deferred.
The spike answers one question.

The ~10% over-render margin *is* in scope, since the residual transform cannot
be evaluated without it. (This is unrelated to tileserver-gl's `tileMargin: 64`,
which addresses per-tile label seams — a problem the frame-based design does not
have.)

## Deferred to post-spike

- Public API design and the `flutter_map` layer contract
- Vector tile caching and offline behaviour (MapLibre's ambient cache vs the
  existing 512 MB `BuiltInMapCachingProvider`)
- Dark mode via style swap, replacing the current dual-URL approach in
  `map_tile_layer.dart`
- Remote Config gating and fallback to the existing raster `TileLayer`, matching
  the established flag pattern
- Migration of `zoomOffset` / `{density}` handling
- Publishing to pub.dev

## Open questions

- Whether MapLibre Native's Android renderer can be driven into an
  externally-owned `Surface` without forking it, or whether the supported entry
  point is `MapRenderer`.
- Whether the iOS renderer can be pointed at a caller-supplied Metal texture, or
  whether an intermediate blit is unavoidable — the latter would weaken but not
  necessarily kill the zero-copy goal.
- Behaviour of the residual transform across the `OverflowBox` resize while the
  sheet drags, since the viewport changes size every frame there.
