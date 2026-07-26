# MapLibre Fixed-Viewport Render — Design

**Date:** 2026-07-23
**Branch:** maplibre-perf
**Status:** Approved (user: "LGTM")
**Builds on:** `2026-07-23-maplibre-ffi-same-frame-render-design.md` (the "New finding: sheet-resize flash" section; this spec supersedes the debounce + keep-old-texture direction sketched there)

## Problem

Dragging the main-map bottom sheet makes the basemap go transparent and
re-render from scratch. Cause, in two parts:

1. **The app resizes the map widget on purpose.** In
   `lib/screens/main_map/main_map_map_view/main_map_map_view.dart` the
   `FlutterMap` is laid out at `screenHeight + sheetHeight` inside an
   `OverflowBox` aligned bottom-center. The extra height hangs **above the
   top of the screen** and is clipped — it exists only to push the camera
   center up into the visible strip above the sheet (flutter_map has no
   native padding). The *visible* viewport is always exactly the phone
   screen; only the widget's layout size changes.

2. **The package treats layout size as viewport size.** `MapLibreBasemap`
   sizes its texture to the layout size and, on a >1px change, disposes the
   session + textures and creates new ones. The gap until the new session's
   first styled frame is the transparent flash. (This recreation was
   previously masked by a `_creating`-never-reset bug that silently disabled
   it; the FFI rewrite fixed that bug and exposed the flash.)

## Insight

The visible viewport never changes. Therefore the session, the GPU
textures, and the MapLibre map never need to change. Only the *camera*
handed to the renderer needs to account for which part of the oversized
layer is visible. As a bonus, the offscreen strip above the screen — which
today is rendered every frame and can approach a full extra screen of fill
when the sheet is tall — stops being rendered at all.

## Design

### 1. Package API (`MapLibreBasemap`)

Two new optional parameters:

- `fixedViewport: Size?` — when set, the texture is created at this size
  (× `overRenderFactor`) and layout size changes never trigger recreation.
  When null: current behavior, unchanged (the example app is untouched).
- `viewportAlignment: Alignment = Alignment.bottomCenter` — where the
  fixed viewport sits inside the (possibly larger) layer.
  `viewportAlignment.inscribe(fixedViewport, Offset.zero & layoutSize)`
  yields the visible rect; no per-alignment special cases.

App wiring is one line in `MaplibreBasemapLayer`:
`fixedViewport: MediaQuery.sizeOf(context)`. Screen `size` is unaffected
by the keyboard (that's `viewInsets`), so no keyboard edge case.

### 2. Camera crop (new pure function, `lib/src/viewport_crop.dart`)

```dart
MapCamera cropCamera(MapCamera full, Rect visibleRect) => full
    .withNonRotatedSize(visibleRect.size)
    .withPosition(center: full.screenOffsetToLatLng(visibleRect.center));
```

Same zoom and bearing; only the center moves to the visible rect's center.
`screenOffsetToLatLng` is the exact bearing-aware inverse of the projection
`residualTransform` is built on, so the crop composes with all existing
math. The renderer receives the cropped camera; it needs no changes.

### 3. Widget placement & transform

In `build()`, when `fixedViewport` is set:

- `visibleRect = viewportAlignment.inscribe(fixedViewport, Offset.zero & layoutSize)`
- render `cropCamera(camera, visibleRect)` instead of `camera`
- success-path transform: pure translation by `visibleRect.topLeft`
  (replaces `Matrix4.identity()`; it *is* identity when the rect sits at
  the origin, so the null-`fixedViewport` path is the same code)
- failure-path transform: `residualTransform(rendered: lastRenderedCamera
  (already the cropped camera), current: fullCamera)` — the formula
  already places a smaller-camera texture correctly in the full layer's
  frame; no extra translate.

`lastRenderedCamera` naturally becomes the cropped camera. No renderer or
native changes.

### 4. Recreation policy

With `fixedViewport` set, `needsCreate` compares the session's viewport
against `fixedViewport` instead of the layout size. Recreation then happens
only on first build or when the fixed viewport itself changes (device
rotation, split-screen) — where a flash is acceptable because the whole UI
relayouts. The existing >1px tolerance stays. Sheet drags: zero
recreations by construction.

## Testing

- **Pure Dart** (`test/viewport_crop_test.dart`): identity when the rect
  equals the full viewport; unrotated bottom-aligned crop moves the center
  south by the projected offset; bearing 90° moves it east instead; zoom
  and rotation preserved.
- **Widget tests** (existing fake-renderer seam in
  `test/maplibre_basemap_test.dart`): with `fixedViewport` set, a layout
  height change causes no recreate and `render` receives the cropped
  camera; a `fixedViewport` change causes a recreate; null `fixedViewport`
  preserves today's behavior.
- **Device validation**: drag the sheet through its full range — no flash;
  session create count stays 1 while `cameraRenders` ticks; markers stay
  glued to the basemap during the drag (the drag itself live-verifies the
  crop math, since the cropped center shifts every frame).

## Out of scope

- The debounce + keep-old-texture-swap machinery from the previous spec's
  sketch — unnecessary once recreation stops happening; can return later if
  a genuinely-resizing embedding appears.
- The general pan/fling stutter synchronized with Flutter frame pacing —
  separate problem, explicitly deferred by the user.
- Android.

## Scope of change

One package file edited (`lib/src/maplibre_basemap.dart`), one new small
file (`lib/src/viewport_crop.dart` + export), one-line app wiring in
`lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`,
tests. No native/FFI changes.
