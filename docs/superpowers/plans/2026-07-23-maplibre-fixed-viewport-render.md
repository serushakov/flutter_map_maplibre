# MapLibre Fixed-Viewport Render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the basemap texture from being destroyed and recreated when the bottom sheet resizes the map widget — the visible viewport is always the phone screen, so the session is created once at screen size and each frame renders a camera cropped to the visible strip.

**Architecture:** A pure function `cropCamera` derives the visible-strip camera from the full flutter_map camera (same zoom/bearing, center moved to the visible rect's center via `screenOffsetToLatLng`). `MapLibreBasemap` gains `fixedViewport`/`viewportAlignment` params: when set, session size is pinned, the success-path transform becomes a pure translation onto the visible rect, and layout changes never recreate. Vedu passes `MediaQuery.sizeOf(context)`.

**Tech Stack:** Dart only — flutter_map ^8.3.1 `MapCamera` math, existing `BasemapRenderer` seam. **No native, FFI, or renderer changes.**

**Spec:** `docs/superpowers/specs/2026-07-23-maplibre-fixed-viewport-render-design.md`

## Global Constraints

- Work in the worktree: `/Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf` (branch `maplibre-perf`). All paths below are relative to it; run git from its root.
- All Flutter/Dart commands prefixed with `fvm`. Package commands run from `packages/flutter_map_maplibre/`.
- After editing any `.dart` file, run `fvm dart format <files>` on every touched file (one invocation).
- Commit **only** the exact files each task names. NEVER commit `ios/Runner.xcodeproj/project.pbxproj`, `ios/Runner.app.dSYM.zip`, `.env`, or anything under a `Frameworks/` / xcframework path (the worktree carries local-only signing edits).
- No changes under `packages/flutter_map_maplibre/ios/` or `packages/flutter_map_maplibre/lib/src/ffi/` — this feature is pure widget/camera-math Dart.
- Default `viewportAlignment` is exactly `Alignment.bottomCenter` (spec value).
- The >1px recreation tolerance stays exactly as-is.

---

### Task 1: `cropCamera` pure function

**Files:**
- Create: `packages/flutter_map_maplibre/lib/src/viewport_crop.dart`
- Modify: `packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart`
- Test: `packages/flutter_map_maplibre/test/viewport_crop_test.dart`

**Interfaces:**
- Consumes: `MapCamera` from flutter_map (`withNonRotatedSize`, `withPosition`, `screenOffsetToLatLng`).
- Produces: `MapCamera cropCamera(MapCamera full, Rect visibleRect)` — Task 2 calls this in `build()`. Returns `full` itself (identical) when `visibleRect` covers the whole viewport.

- [ ] **Step 1: Write the failing test**

Create `packages/flutter_map_maplibre/test/viewport_crop_test.dart`:

```dart
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/src/viewport_crop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

MapCamera cameraAt({
  LatLng center = const LatLng(59.437, 24.7536),
  double zoom = 13,
  double rotation = 0,
  Size size = const Size(400, 800),
}) => MapCamera(
  crs: const Epsg3857(),
  center: center,
  zoom: zoom,
  rotation: rotation,
  nonRotatedSize: size,
);

/// The property the whole design rests on: the cropped camera's screen is
/// the full camera's screen shifted by the rect origin, for every point on
/// earth. flutter_map's own projection is the oracle — nothing here
/// re-derives it.
void expectCropMatchesProjection(MapCamera full, Rect rect) {
  final cropped = cropCamera(full, rect);

  const samples = <LatLng>[
    LatLng(59.437, 24.7536), // Tallinn
    LatLng(59.4, 24.6), // south-west of centre
    LatLng(59.5, 24.9), // north-east of centre
    LatLng(58.38, 26.72), // Tartu — far off-screen
  ];

  for (final point in samples) {
    final actual = cropped.latLngToScreenOffset(point);
    final expected = full.latLngToScreenOffset(point) - rect.topLeft;
    expect(
      (actual - expected).distance,
      lessThan(0.01),
      reason: 'point $point: cropped gave $actual, expected $expected',
    );
  }
}

void main() {
  test('returns the same camera when the rect is the whole viewport', () {
    final full = cameraAt();
    expect(
      identical(cropCamera(full, const Rect.fromLTWH(0, 0, 400, 800)), full),
      isTrue,
      reason:
          'the unpinned path must not round-trip the center through the '
          'projection — an epsilon there would defeat the renderer\'s '
          'same-camera dedup and re-render on every rebuild',
    );
  });

  test('bottom-aligned crop matches the projection', () {
    expectCropMatchesProjection(
      cameraAt(),
      const Rect.fromLTWH(0, 200, 400, 600),
    );
  });

  test('crop matches the projection under bearing', () {
    expectCropMatchesProjection(
      cameraAt(rotation: 37),
      const Rect.fromLTWH(0, 200, 400, 600),
    );
    expectCropMatchesProjection(
      cameraAt(rotation: 90),
      const Rect.fromLTWH(0, 200, 400, 600),
    );
  });

  test('crop matches the projection under zoom and bearing together', () {
    expectCropMatchesProjection(
      cameraAt(zoom: 16.4, rotation: 213),
      const Rect.fromLTWH(0, 350, 400, 450),
    );
  });

  test('unrotated bottom crop moves the center straight south', () {
    final full = cameraAt();
    final cropped = cropCamera(full, const Rect.fromLTWH(0, 200, 400, 600));
    expect(cropped.nonRotatedSize, const Size(400, 600));
    expect(cropped.center.latitude, lessThan(full.center.latitude));
    expect(cropped.center.longitude, closeTo(full.center.longitude, 1e-9));
  });

  test('preserves zoom and rotation', () {
    final cropped = cropCamera(
      cameraAt(zoom: 15.3, rotation: 42),
      const Rect.fromLTWH(0, 100, 400, 700),
    );
    expect(cropped.zoom, 15.3);
    expect(cropped.rotation, 42);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `packages/flutter_map_maplibre/`): `fvm flutter test test/viewport_crop_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'flutter_map_maplibre/src/viewport_crop.dart'` (file doesn't exist).

- [ ] **Step 3: Write the implementation**

Create `packages/flutter_map_maplibre/lib/src/viewport_crop.dart`:

```dart
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';

/// The camera whose viewport is [visibleRect] of [full]'s screen.
///
/// Same zoom and bearing; only the center moves to [visibleRect]'s center.
/// `screenOffsetToLatLng` is the exact bearing-aware inverse of the
/// projection `residualTransform` is built on, so for every point on earth
///
///     cropped.latLngToScreenOffset(p) ==
///         full.latLngToScreenOffset(p) - visibleRect.topLeft
///
/// which is what lets a fixed-size texture cover just the visible part of a
/// deliberately oversized map layer (Vedu lays the map out taller than the
/// screen to push the camera center above the bottom sheet; the overflow is
/// clipped offscreen and need never be rendered).
///
/// Returns [full] itself when the rect covers the whole viewport: the
/// center round-trip through the projection carries a float epsilon that
/// would otherwise defeat the renderer's same-camera dedup.
MapCamera cropCamera(MapCamera full, Rect visibleRect) {
  if (visibleRect == (Offset.zero & full.nonRotatedSize)) return full;
  return full
      .withNonRotatedSize(visibleRect.size)
      .withPosition(center: full.screenOffsetToLatLng(visibleRect.center));
}
```

Add the export to `packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart` (after the `residual_transform.dart` line):

```dart
export 'src/viewport_crop.dart';
```

- [ ] **Step 4: Format, run test to verify it passes**

Run (from `packages/flutter_map_maplibre/`):
```bash
fvm dart format lib/src/viewport_crop.dart lib/flutter_map_maplibre.dart test/viewport_crop_test.dart
fvm flutter test test/viewport_crop_test.dart
fvm flutter analyze
```
Expected: all tests PASS, analyze clean.

- [ ] **Step 5: Commit**

From the worktree root:
```bash
git add packages/flutter_map_maplibre/lib/src/viewport_crop.dart packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart packages/flutter_map_maplibre/test/viewport_crop_test.dart
git commit -m "feat(flutter_map_maplibre): add cropCamera, the visible-strip camera derivation"
```

---

### Task 2: `MapLibreBasemap` fixed-viewport mode

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`
- Test: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`

**Interfaces:**
- Consumes: `cropCamera(MapCamera full, Rect visibleRect)` from Task 1 (import `viewport_crop.dart`).
- Produces: `MapLibreBasemap({..., Size? fixedViewport, Alignment viewportAlignment = Alignment.bottomCenter})` — Task 3 passes `fixedViewport: MediaQuery.sizeOf(context)`.

- [ ] **Step 1: Extend the fake renderer to record creates**

In `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`, replace the `create` override of `_FakeRenderer` (and add the three fields next to the existing counters):

```dart
  int createCalls = 0;
  int? createdWidth;
  int? createdHeight;
```

```dart
  @override
  bool create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  }) {
    createCalls++;
    createdWidth = width;
    createdHeight = height;
    this.styleUrl = styleUrl;
    return true;
  }
```

- [ ] **Step 2: Write the failing widget tests**

Add to `main()` in the same file (after the existing helpers; it reuses `basemapTransform` and the `renderer`/`controller` fixtures):

```dart
  /// Fixed-viewport harness: the map widget in a parent-controlled box, the
  /// shape of Vedu's sheet center-offset layout (layer taller than screen).
  Future<void> pumpSizedMap(
    WidgetTester tester, {
    required double height,
    Size? fixedViewport,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: height,
            child: FlutterMap(
              mapController: controller,
              options: const MapOptions(
                initialCenter: LatLng(59.437, 24.7536),
                initialZoom: 13,
              ),
              children: [
                MapLibreBasemap(
                  styleUrl: 'https://example.com/style.json',
                  fixedViewport: fixedViewport,
                  rendererFactory: () => renderer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('fixedViewport: layout resize never recreates the session', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
    );
    expect(renderer.createCalls, 1);
    expect(renderer.createdWidth, 400);
    expect(renderer.createdHeight, 600);

    // The sheet-drag scenario: the layer grows, the session must not.
    await pumpSizedMap(
      tester,
      height: 900,
      fixedViewport: const Size(400, 600),
    );
    expect(renderer.createCalls, 1);
    expect(renderer.disposeCalls, 0);
  });

  testWidgets('fixedViewport: renders the cropped camera on the visible rect', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
    );

    final shown = renderer.lastRenderedCamera!;
    expect(shown.nonRotatedSize, const Size(400, 600));
    // Bottom-aligned: the visible strip's center sits below the layer
    // center, so the cropped camera looks further south.
    expect(shown.center.latitude, lessThan(controller.camera.center.latitude));
    expect(
      shown.center.longitude,
      closeTo(controller.camera.center.longitude, 1e-9),
    );

    // Success-path transform is the pure translation onto the visible rect
    // (bottomCenter of a 400x800 layer with a 400x600 viewport → dy 200).
    var translation = basemapTransform(tester).getTranslation();
    expect(translation.x, closeTo(0, 1e-6));
    expect(translation.y, closeTo(200, 1e-6));

    await pumpSizedMap(
      tester,
      height: 900,
      fixedViewport: const Size(400, 600),
    );
    translation = basemapTransform(tester).getTranslation();
    expect(translation.y, closeTo(300, 1e-6));
  });

  testWidgets('changing fixedViewport recreates the session', (tester) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
    );
    expect(renderer.createCalls, 1);
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 500),
    );
    expect(renderer.createCalls, 2);
  });

  testWidgets('without fixedViewport a layout resize recreates', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800);
    expect(renderer.createCalls, 1);
    await pumpSizedMap(tester, height: 900);
    expect(renderer.createCalls, 2);
  });
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run (from `packages/flutter_map_maplibre/`): `fvm flutter test test/maplibre_basemap_test.dart`
Expected: compile error — `No named parameter with the name 'fixedViewport'`. The pre-existing tests must be untouched.

- [ ] **Step 4: Implement the widget changes**

In `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`:

Add the import (with the other relative imports):

```dart
import 'viewport_crop.dart';
```

Extend the constructor:

```dart
  const MapLibreBasemap({
    super.key,
    required this.styleUrl,
    this.onDiagnostics,
    this.applyResidualTransform = true,
    this.overRenderFactor = 1.0,
    this.fixedViewport,
    this.viewportAlignment = Alignment.bottomCenter,
    this.rendererFactory,
  }) : assert(overRenderFactor >= 1.0);
```

Add the fields (after `overRenderFactor`):

```dart
  /// When set, the texture viewport is pinned to this size and layout size
  /// changes never recreate the session. Use when the layer's widget is
  /// deliberately laid out larger than what is visible (Vedu lays the map
  /// out taller than the screen to push the camera center above the bottom
  /// sheet): pass the truly visible size and the offscreen remainder is
  /// never rendered. Null means the layout size is the viewport, recreating
  /// on any layout change.
  final Size? fixedViewport;

  /// Where the fixed viewport sits inside the (possibly larger) layer.
  /// Ignored when [fixedViewport] is null.
  final Alignment viewportAlignment;
```

Replace the whole `build` method:

```dart
  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutSize = constraints.biggest;
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

        // The viewport the session must match: pinned when [fixedViewport]
        // is set, the layout size otherwise. Layout sizes churn every frame
        // while a bottom sheet drags, hence the tolerance.
        final viewport = widget.fixedViewport ?? layoutSize;
        final current = _viewportSize;
        final needsCreate =
            current == null ||
            (current.width - viewport.width).abs() > 1 ||
            (current.height - viewport.height).abs() > 1;

        if (needsCreate && viewport.isFinite && !viewport.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _create(viewport, devicePixelRatio);
          });
        }

        final textureId = _textureId;
        final renderSize = _renderSize;

        if (textureId == null || renderSize == null) {
          return const SizedBox.shrink();
        }

        // The part of the layer the texture covers: the whole layer when the
        // viewport is unpinned, the aligned sub-rect when it is pinned — the
        // rest of the layer is clipped offscreen by construction and never
        // rendered.
        final visibleRect = widget.viewportAlignment.inscribe(
          viewport,
          Offset.zero & layoutSize,
        );

        // The same-frame render: by the time this build returns, the front
        // buffer shows [visibleRect]'s view of [camera] (on success). No
        // stamp, no estimate.
        final rendered = _renderer.render(cropCamera(camera, visibleRect));
        final shown = _renderer.lastRenderedCamera;

        // On success the texture needs only to be moved onto [visibleRect]
        // (identity when the viewport is unpinned). On failure the residual
        // places the stale cropped frame in the full layer's frame — the
        // formula already accounts for the size mismatch, no extra
        // translate. First frame before any successful render: draw
        // unplaced rather than hide the map (a hidden map is
        // indistinguishable from a broken renderer).
        final placed = Matrix4.identity()
          ..translateByDouble(visibleRect.left, visibleRect.top, 0, 1);
        final transform = (rendered || shown == null)
            ? placed
            : widget.applyResidualTransform
            ? residualTransform(
                rendered: shown.withNonRotatedSize(renderSize),
                current: camera,
              )
            : placed;

        return Transform(
          transform: transform,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: renderSize.width,
            maxWidth: renderSize.width,
            minHeight: renderSize.height,
            maxHeight: renderSize.height,
            child: Texture(textureId: textureId),
          ),
        );
      },
    );
  }
```

Nothing else in the file changes: `_create` already takes the viewport size as its parameter (`_viewportSize` keeps meaning "the viewport the session was created for"), and the failure path already corrects against `lastRenderedCamera`, which is now naturally the cropped camera.

Also update the class doc comment's camera paragraph (the one starting "The camera stays owned by `flutter_map`.") — append one sentence:

```
/// When the hosting layout is deliberately larger than what is visible, see
/// [fixedViewport].
```

- [ ] **Step 5: Format, run the full package suite**

Run (from `packages/flutter_map_maplibre/`):
```bash
fvm dart format lib/src/maplibre_basemap.dart test/maplibre_basemap_test.dart
fvm flutter test
fvm flutter analyze
```
Expected: all tests PASS (including all pre-existing ones — the null-`fixedViewport` path must behave identically to before), analyze clean.

- [ ] **Step 6: Commit**

From the worktree root:
```bash
git add packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git commit -m "feat(flutter_map_maplibre): fixed-viewport mode — sheet resizes stop recreating the session"
```

---

### Task 3: Vedu wiring

**Files:**
- Modify: `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`

**Interfaces:**
- Consumes: `MapLibreBasemap.fixedViewport` from Task 2.
- Produces: nothing downstream; this is the leaf integration.

- [ ] **Step 1: Pass the screen size as the fixed viewport**

In `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`, in `MaplibreBasemapLayer.build`, add one argument to the `MapLibreBasemap` constructor call (after `overRenderFactor`):

```dart
      // The map widget is laid out taller than the screen (the sheet
      // center-offset trick in MainMapMapView); the truly visible viewport
      // is exactly the screen, so pin the session to it — sheet drags then
      // never recreate the renderer. Screen `size` ignores the keyboard
      // (that's viewInsets), so no keyboard edge case.
      fixedViewport: MediaQuery.sizeOf(context),
```

(`viewportAlignment` stays at its default `Alignment.bottomCenter`, which matches the `OverflowBox(alignment: Alignment.bottomCenter)` in `main_map_map_view.dart`.)

- [ ] **Step 2: Format, analyze, run app tests**

From the worktree root:
```bash
fvm dart format lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart
fvm flutter analyze
fvm flutter test
```
Expected: analyze clean, tests PASS.

- [ ] **Step 3: Commit**

From the worktree root:
```bash
git add lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart
git commit -m "feat(map): pin the maplibre basemap viewport to the screen"
```

---

### Task 4: Device validation (user-assisted)

**Files:**
- Modify: `docs/superpowers/specs/2026-07-23-maplibre-fixed-viewport-render-design.md` (append results)

This task needs the physical iPhone and the user; coordinate with them. The worktree already carries the local-only signing flip + Crashlytics neuter needed for device builds (never commit `ios/Runner.xcodeproj/project.pbxproj`).

- [ ] **Step 1: Build and run on device**

From the worktree root: `fvm flutter run --profile` with the phone connected. In the app: enable the MapLibre basemap debug toggle.

- [ ] **Step 2: Validate with the user**

Phases (batch-read logs per phase, no per-line monitoring):
1. **Sheet drag**: drag the bottom sheet slowly through its full range, then fling it between snap points. Expected: **no transparent flash, ever**; the basemap shifts smoothly with the sheet; markers stay glued to the basemap throughout.
2. **Diagnostics**: with the MLNDIAG overlay, confirm the drag produces camera renders (`cam` ticking) but the session is never recreated (no style reload; `frames` counter does not reset).
3. **Bearing**: rotate the map (two-finger) with the sheet half-open, pan around. Expected: markers stay glued — this live-verifies `cropCamera` under rotation.
4. **Regression**: repeat the previous validation's happy-path pan/fling; expect the same "markers never lag" behavior and render times in the same 2–5ms band (the cropped render is smaller than before, so times may improve slightly).

- [ ] **Step 3: Record results and commit**

Append a "Device validation results" section to `docs/superpowers/specs/2026-07-23-maplibre-fixed-viewport-render-design.md` with the observed outcomes per phase (pass/fail + numbers), then from the worktree root:
```bash
git add docs/superpowers/specs/2026-07-23-maplibre-fixed-viewport-render-design.md
git commit -m "docs(flutter_map_maplibre): record fixed-viewport device validation"
```
