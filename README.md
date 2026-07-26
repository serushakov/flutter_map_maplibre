# flutter_map_maplibre

A natively-rendered MapLibre vector basemap for [`flutter_map`](https://pub.dev/packages/flutter_map),
composited as a Flutter texture underneath your existing layers.

`flutter_map` keeps the camera. Every marker, polyline and overlay stays an
ordinary Flutter widget. Only the basemap is native.

**Private package.** Not published to pub.dev; consumed as a git dependency
(see [Install](#install)).

## Status

Working spike. Both platforms render real vector tiles and have run on
physical hardware in profile builds.

| | iOS | Android |
|---|---|---|
| Backend | Metal, borrowed texture | EGL/GLES3 → `SurfaceProducer` |
| Renderer | `FfiBasemapRenderer` (synchronous, same-frame) | `WorkerBasemapRenderer` (native worker thread) — default since 2026-07-26 |
| Device-validated | iPhone 14 Pro, profile: sync, in budget, all three phases pass | OnePlus 8 Pro, profile: renders and pans (sync renderer) |
| Architectures | arm64 only (device + simulator) | arm64-v8a only |
| Minimum OS | iOS 14.3 | minSdk 24 |

The one thing to know before trusting the table: **the Android worker
renderer is the default but has not been through its own on-device gate.**
Its predecessor was measured at ~46 fps on hard pan against raster's
~98–118; the worker exists to close that and its target is ≥ 90 fps, but
that A/B was never run. See [Not done yet](#not-done-yet).

Screenshots: [`maplibre-ios-simulator.png`](maplibre-ios-simulator.png),
[`maplibre-android-emulator.png`](maplibre-android-emulator.png).

## Why

Every other MapLibre Flutter plugin gives you a native map that *owns* the
camera, which forces your markers into native land or leaves them sliding
against the basemap. This package inverts that.

That buys the things raster tiles cannot do — true fractional zoom, rotation
with MapLibre's real label engine, runtime style swaps for dark mode, and
vector-tile bandwidth — without touching your overlay stack.

## Install

```yaml
dependencies:
  flutter_map_maplibre:
    git:
      url: https://github.com/serushakov/flutter_map_maplibre.git
      ref: <full commit SHA>
```

Pin a full SHA, not a branch: the native prerequisites below are version-coupled
to the Dart bindings.

### Native prerequisites

Two artifacts are built from
[maplibre-native-ffi](https://github.com/maplibre/maplibre-native-ffi) and are
**not committed** — they total ~1.5 GB, so a fresh clone cannot build until
they are in place:

| path | what | size |
|---|---|---|
| `ios/MaplibreNativeC.xcframework` | `ios-arm64` + `ios-arm64-simulator` static slices, with headers and a `module.modulemap` | 1.4 GB |
| `android/src/main/cpp/prebuilt/arm64-v8a/libmaplibre-native-c.a` | complete static archive | 60 MB |

`android/src/main/cpp/prebuilt/include/` (the C headers) **is** tracked.

The build recipes live in the podspec and `android/src/main/cpp/CMakeLists.txt`
next to the paths they produce. The long version — and the thirteen distinct
things that bite while doing it — is
[`docs/superpowers/specs/2026-07-22-flutter-map-maplibre-ffi-spike.md`](docs/superpowers/specs/2026-07-22-flutter-map-maplibre-ffi-spike.md).

Short form:

```bash
# iOS (no Rust needed)
cmake --preset ios-simulator-arm64-metal
cmake --build --preset ios-simulator-arm64-metal
xcodebuild -create-xcframework -library libmaplibre-native-c.a \
  -headers <include dir with module.modulemap> -output MaplibreNativeC.xcframework

# Android (Rust is mandatory here)
ANDROID_HOME=~/Library/Android/sdk \
MLN_FFI_ANDROID_NDK_VERSION=28.2.13676358 \
cmake --preset android-arm64-egl && cmake --build --preset android-arm64-egl
```

### Android: the certificate patch is not optional

**Apply [`patches/0001-android-webpki-roots.patch`](patches/0001-android-webpki-roots.patch)
to maplibre-native-ffi before building it, or no tile will ever load.**
`rustls-platform-verifier` rejects certificates every other client on the
device accepts, reporting `invalid peer certificate: Revoked`. The patch
selects the bundled webpki roots on Android only.

Consequence: user-installed and enterprise CAs are ignored for map traffic,
so a debugging proxy cannot intercept tile requests.

### iOS build settings

The podspec handles the awkward parts itself — static framework, per-SDK
header and library search paths into the xcframework, `STRIP_STYLE =
non-global` so `dlsym` can still find statically-linked globals,
`-u _mln_ffi_symbol_keeper` to force the keeper object in, and
`EXCLUDED_ARCHS[sdk=iphonesimulator*] = i386 x86_64` on **both** the pod and
the app target (there is no x86_64 simulator slice upstream).

A host app normally needs nothing. Do check those settings survive any
Podfile `post_install` hook that rewrites build settings wholesale.

## Usage

```dart
FlutterMap(
  options: const MapOptions(initialCenter: ..., initialZoom: 13),
  children: [
    MapLibreBasemap(
      styleUrl: isDark ? darkStyleUrl : lightStyleUrl,
    ),
    MarkerLayer(markers: ...),   // ordinary Flutter widgets, unchanged
    PolylineLayer(polylines: ...),
  ],
)
```

Changing `styleUrl` swaps the style in place — no renderer teardown, and
sources shared between the two styles are not re-downloaded.

### Knobs

| parameter | default | what it is for |
|---|---|---|
| `styleUrl` | required | MapLibre style JSON URL. Swapped in place on change. |
| `onDiagnostics` | `null` | Render statistics, once a second. See [Diagnostics](#diagnostics). |
| `frameCap` | `null` (uncapped) | Minimum interval between presented native frames. Caps the native render rate only; the Flutter ticker and gestures are untouched. |
| `renderScale` | `1.0` | Fraction of device pixel ratio to render at. On a 3.5 dpr panel 0.7–0.85 is hard to tell apart and cuts fragment work by the square. Camera maths is unaffected. |
| `overRenderFactor` | `1.0` | Render this much larger than the viewport, per axis. Margin for the leading edge during flings; the example uses 1.1. |
| `admissionGuardPx` | `16.0` | Admit a camera-driven render once the viewport comes within this many logical px of the rendered canvas's edge. |
| `admissionZoomQuantum` | `0.05` | Zoom drift that admits a render on its own. Zooming in never bares the canvas, so without this labels would blur indefinitely. |
| `fixedViewport` | `null` | Pin the texture viewport, so layout-size changes never recreate the session. For layers deliberately laid out larger than what is visible. |
| `viewportAlignment` | `Alignment.bottomCenter` | Where the fixed viewport sits inside the larger layer. |
| `applyResidualTransform` | `true` | Debugging escape hatch. False draws failed renders uncorrected. Never ship it false. |
| `rendererFactory` | platform default | Test/A-B seam. Android → `WorkerBasemapRenderer`, iOS → `FfiBasemapRenderer`. |

## How it works

### The stale frame is placed, not hidden

The native renderer can be a frame behind the camera: Flutter moves, the
camera reaches the renderer, MapLibre renders. Showing that frame as-is makes
the basemap slide against your markers — the artefact every platform-view map
plugin suffers from.

In Web Mercator, pan, zoom and rotation are exact similarity transforms of the
projected plane, so the difference between the rendered camera and the live
camera is a pure affine transform:

```
screen_C(p) = k · R(θc − θr) · (screen_R(p) − half_R) + screen_C(R.center)
```

That is `residualTransform`, applied to the texture every Flutter frame. The
basemap lands correctly in the same frame as the markers; only symbol layout
is momentarily stale, so labels scale slightly during a fling and snap crisp
when the renderer catches up — the same behaviour MapLibre GL JS has between
re-layouts.

The maths is unit-tested against `flutter_map`'s own projection as the oracle,
including fractional zoom, rotation from a non-zero bearing, and the combined
fling case.

### Render admission

Because the residual transform is *exact* under translation, a rendered frame
stays usable while the viewport is still inside it. So a camera change does not
imply a render: one is admitted only when the viewport comes within
`admissionGuardPx` of the rendered canvas's edge, or zoom drifts past
`admissionZoomQuantum`. A one-shot settle render fires after motion stops
off-quantum, so a rest position is always crisp.

GPS-follow at ~11 px/s previously held ~118 renders/s, redrawing an almost
identical frame each time. Under admission it is one render every 8–10 s.

`overRenderFactor` gives each frame runway, and the rendered camera is
lead-biased along the estimated velocity so the margin sits ahead of motion
rather than being split evenly around it — the trailing half was pure waste.
`underRenderPx` reports when the leading edge is bared anyway.

### The ticker parks

An always-on Flutter `Ticker` requests a vsync frame every cycle, so the whole
app pipeline runs at the display's native rate even when the renderer decides
to do nothing. Measured on an iPhone 14 Pro over 15-minute soak legs, settled
and with no input:

| | idle fps | thermal after 15 min | battery |
|---|---|---|---|
| maplibre (always-on ticker) | 119.9 | 2 (serious) | −10 % |
| raster tiles | 16.1 | 0 (nominal) | −5 % |

So the ticker is parked on MapLibre's own `MAP_IDLE` signal and restarted on
camera change, style change, or when a 5-second insurance pump finds work.
Parked means fully frozen — no vsync requests, ~0.2 event pumps/second.

### Android renders off the UI thread

Every admitted render used to execute synchronously inside the widget's build
path. On a OnePlus 8 Pro at 120 Hz, admitted renders cost ~10 ms each at ~19/s,
so roughly every second or third vsync blew the 8.3 ms budget:

| hard pan | raster tiles | maplibre (sync renderer) |
|---|---|---|
| fps | ~98–118 | ~46 |
| UI build avg | ~2.9 ms | 12–14 ms |
| UI build p95 | ~5 ms | ~27 ms |

`WorkerBasemapRenderer` moves the work to a dedicated **native** worker thread
that owns the runtime, map and render session, driven by a FIFO command queue
with completions posted back over `Dart_PostCObject_DL`. Not a Dart isolate:
the mln C API is owner-thread affine (`MLN_STATUS_WRONG_THREAD`) and the Dart
VM does not pin an isolate to one OS thread.

Dart still chooses the camera for every render, knows which camera each
presented texture holds, and places it with the residual transform. The worker
only changes *when* renders execute, never what is known about them. A
presented texture is ~25–30 ms stale but refreshed every ~12 ms, versus every
50–100 ms when the UI thread was choking.

iOS keeps the synchronous path — same-frame present via pull-based
`copyPixelBuffer` is validated and there is no measured need.

## Diagnostics

`onDiagnostics` fires once a second with the active renderer's counters merged
with the widget's:

- **Volume** — `frameCount`, `cameraRenders`, `linkRenders`, `drawCalls`,
  `admits`, `admissionSkips`, `skippedTicks`, `cappedTicks`, `idleEvents`
- **Timing** — `renderMsAvgSteady`, `renderMsMaxSteady`, `renderMsMax`,
  `blitMs`, `pumpMs`, `jumpMs`
- **State** — `tickerActive`, `parks`, `needsRepaint`, `underRenderPx`
- **Worker only** — `rendersInFlight`, `superseded`, `completionLagMs`,
  `completionLagMsMax`
- **Failures** — style-load and attach status codes

## Measured performance

iOS, iPhone 14 Pro, profile build, all three phases pass:

| phase | render (inline) | blit |
|---|---|---|
| fling @ 120 Hz | 2.2–4.7 ms | 1.0–1.9 ms |
| Low Power @ 60 Hz | 4–6 ms (one 9.9 ms spike at the mode switch) | 1.6–3.3 ms |
| idle | zero frames rendered | — |

Human verdict from that session: markers, polylines and basemap move as one
surface; nothing leads or trails, in any power mode.

Android numbers are the sync-renderer table under
[Android renders off the UI thread](#android-renders-off-the-ui-thread). The
worker's are not measured yet.

## Not done yet

Read this list before shipping it.

- **The Android worker's on-device gate was never run.** Target: hard-pan
  fps ≥ 90 with UI build avg back near ~3 ms, `underRenderPx` no worse than
  the sync renderer, and the present-latency latch re-tuned by feel (the
  example's `latency` FAB cycles it live). The unit tests pass; the phone has
  not judged it.
- **Attribution.** `MLNMapView` provides MapLibre/OSM attribution for free; a
  texture has no view, so it must be re-implemented in Flutter. That is a
  licensing requirement, not a nicety.
- **Android surface loss.** A lost `SurfaceProducer` surface (backgrounding)
  only fails soft. In-place EGL window-surface recreation is still to do.
- **Buffer rotation.** Single-buffered, so a torn frame is possible. Roughly
  100 lines upstream (`mln_metal_borrowed_texture_set_texture`).
- **Resize** destroys and recreates the render session, because borrowed
  texture sessions cannot be resized in place. Fine for device rotation;
  `fixedViewport` is the answer for a continuously-dragging bottom sheet.
- **Offline and caching.** The runtime uses `:memory:` for its cache.
- **Error handling.** A failed style load surfaces in diagnostics; there is no
  fallback to raster tiles.
- **Debug builds mislead on Android.** JIT Dart makes per-gesture widget work
  dominate and it reads as map lag. Judge performance on `--profile` only.
- **Platform coverage.** No x86_64, no armeabi-v7a, no desktop, no web.

## Development

Flutter is pinned in [`.fvmrc`](.fvmrc) — prefix commands with `fvm`.

```bash
fvm flutter pub get
fvm flutter test              # 112 tests, no native artifacts required
fvm dart format <path>        # after editing any .dart file
fvm flutter analyze
```

The Dart logic is deliberately testable without native code: projection maths,
the admission gate, lead bias, the tick/sleep decision and the worker facade
(driven by a fake command sink with scripted completions) are all pure or
fake-injectable.

### Example app

[`example/`](example/lib/main.dart) is the manual test bench —
OpenFreeMap tiles, no API key, a marker over Tallinn, a live stats wall, and
FABs for dark mode, an auto-pan/zoom/rotate ticker (the condition the residual
transform exists for), the present-latency latch, the render-scale ladder, and
`wkr`/`ffi` to A/B the two renderers at runtime.

```bash
cd example && fvm flutter run --profile
```

### Regenerating FFI bindings

```bash
fvm dart run ffigen --config ffigen.yaml
```

Bindings are generated from the **iOS** xcframework headers
(`ffigen.yaml` entry point), so that artifact must be present. Android uses the
same generated bindings against `libmln_jni.so`, opened by name because
`System.loadLibrary` dlopens with `RTLD_LOCAL` and
`DynamicLibrary.process()` cannot see it.

### Layout

```
lib/src/
  maplibre_basemap.dart      the flutter_map layer widget
  residual_transform.dart    the affine placement maths
  render_admission.dart      when a render is worth doing
  lead_bias.dart             where to aim the over-render margin
  under_render.dart          uncovered-viewport metric
  viewport_crop.dart         fixed-viewport camera adjustment
  camera_conventions.dart    flutter_map ↔ MapLibre camera translation
  ffi/                       bindings, the two renderers, worker link
android/src/main/cpp/        mln_jni.cpp, fmm_worker.cpp, vendored dart_api_dl
android/src/main/kotlin/     plugin + SurfaceProducer presenter registry
ios/flutter_map_maplibre/    Swift plugin, Metal probe, texture presenter
```

## Design record

[`docs/superpowers/`](docs/superpowers/) holds 11 design specs and 8 execution
plans, in date order — the probes, the FFI spike, the same-frame render, the
fixed viewport, the latency bundle, lead-biased over-render, drift-threshold
admission, the ticker gate, the Android port, and the render worker thread.
Each spec states the problem with the measurement that motivated it, so they
read as the reasoning behind the code rather than as documentation of it.

Note: those documents were written while the package lived inside a host app's
repository, and still refer to paths like `packages/flutter_map_maplibre/…`.
Read them as repo-relative.

## License

MIT — see [`LICENSE`](LICENSE). The repository is private; the license governs
the code if and when it is distributed.

The native stack it links is permissively licensed throughout, so nothing
upstream constrains that choice:

- maplibre-native-ffi and MapLibre Native — BSD 2-Clause. Linked, not vendored
  here. Their own bundled dependencies contain no reciprocal licenses.
- `android/src/main/cpp/dart_include/` — Dart SDK headers and `dart_api_dl.c`,
  BSD-3-Clause, vendored as upstream intends and carrying their own notices.

Attribution is a separate obligation from licensing: tile and style
attribution belongs to the consuming app, and this package does not yet make
it possible. See [Not done yet](#not-done-yet).
