# flutter_map_maplibre

A natively-rendered MapLibre vector basemap for [`flutter_map`](https://pub.dev/packages/flutter_map),
composited as a Flutter texture underneath your existing layers.

**Status: working spike — iOS and Android, emulators only.** No physical device
has run this on either platform. Read "What's missing" before depending on it.

## Why

Every other MapLibre Flutter plugin gives you a native map that *owns* the
camera, which forces your markers into native land or leaves them sliding
against the basemap. This package inverts that: `flutter_map` keeps the camera
and every marker stays an ordinary Flutter widget. Only the basemap is native.

That buys the things raster tiles cannot do — true fractional zoom, rotation
with MapLibre's real label engine, runtime style swaps for dark mode, and
vector-tile bandwidth — without touching your overlay stack.

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

Pass `onDiagnostics` to receive render statistics once a second
(`renderMsAvgSteady`, `renderMsMaxSteady`, `frameCount`, style-load failures).

## How it works

The native renderer is always at least a frame behind the camera: Flutter moves,
then the camera is pushed over a method channel, then MapLibre renders. Showing
that frame as-is would make the basemap slide against your markers — the
artefact every platform-view map plugin suffers from.

Instead the stale frame is *placed correctly*. In Web Mercator, pan, zoom and
rotation are exact similarity transforms of the projected plane, so the
difference between the rendered camera and the live camera is a pure affine
transform:

```
screen_C(p) = k · R(θc − θr) · (screen_R(p) − half_R) + screen_C(R.center)
```

That is `residualTransform`, applied to the texture every Flutter frame. The
basemap lands correctly in the same frame as the markers; only symbol layout is
momentarily stale, so labels scale slightly during a fling and snap crisp when
the renderer catches up — the same behaviour MapLibre GL JS has between
re-layouts.

The maths is unit-tested against `flutter_map`'s own projection as the oracle,
including fractional zoom, rotation from a non-zero bearing, and the combined
fling case.

## Requirements

- **iOS 14.3+** — imposed by maplibre-native-ffi's Apple CMake presets.
- **arm64 only.** There is no x86_64 simulator slice, so consuming apps need
  `EXCLUDED_ARCHS[sdk=iphonesimulator*] = i386 x86_64`.
- A `MaplibreNativeC.xcframework` built from
  [maplibre-native-ffi](https://github.com/maplibre/maplibre-native-ffi). It is
  **not committed** — see
  `docs/superpowers/specs/2026-07-22-flutter-map-maplibre-ffi-spike.md` for the
  build recipe and the thirteen things that bite while doing it.

### Android

- **arm64-v8a only** in this spike, and **minSdk 24**.
- A static `libmaplibre-native-c.a` at
  `android/src/main/cpp/prebuilt/arm64-v8a/`, likewise **not committed** (63 MB
  stripped; it dead-strips to an 18.7 MB `libmln_jni.so` in the APK). Rust is
  mandatory for the Android FFI build, unlike Apple.
- **`patches/0001-android-webpki-roots.patch` must be applied to the FFI before
  building**, or no tile ever loads. `rustls-platform-verifier` rejects
  certificates that every other client on the device accepts and reports it as
  `invalid peer certificate: Revoked`. The patch selects the bundled webpki
  roots on Android only. Consequence: user-installed and enterprise CAs are
  ignored for map traffic, so debugging proxies cannot intercept tile requests.

## What's missing

Be honest with yourself about this list before shipping it:

- **Android surface loss.** The port (spec:
  `2026-07-25-flutter-map-maplibre-android-port.md`) renders and pans on a
  physical OnePlus 8 Pro, but a lost `SurfaceProducer` surface (backgrounding)
  only fails soft — in-place EGL window-surface recreation is still to do.
- **Debug builds feel slow on Android.** JIT Dart makes the per-gesture
  widget work dominate and reads as map lag. Judge performance only on
  `--profile` builds.
- **Physical iOS devices.** The iOS side has run on the simulator only, whose
  Metal is `MTLSimDriver`. maplibre-native-ffi's own CI never executes on an
  iOS device either.
- **Attribution.** `MLNMapView` provides MapLibre/OSM attribution for free; a
  texture has no view, so it must be re-implemented in Flutter. That is a
  licensing requirement, not a nicety.
- **Buffer rotation.** Single-buffered, so a torn frame is possible. Needs
  roughly 100 lines upstream (`mln_metal_borrowed_texture_set_texture`).
- **Resize** destroys and recreates the render session, because borrowed
  texture sessions cannot be resized in place. Fine for device rotation,
  wasteful for a continuously-dragging bottom sheet.
- **Offline and caching.** The runtime uses `:memory:` for its cache.
- **Error handling.** A failed style load surfaces in diagnostics; there is no
  fallback to raster tiles.

## Performance

iOS simulator, full-screen at device density, with the FFI's per-frame
`waitUntilCompleted()` stall left in place:

```
renderMsAvgSteady: 4.4–5.0    renderMsMaxSteady: 7.7–8.8
```

Comfortably inside a 16.7 ms budget, which suggests the async-completion change
upstream may not be needed at all. Unmeasured on real hardware.
