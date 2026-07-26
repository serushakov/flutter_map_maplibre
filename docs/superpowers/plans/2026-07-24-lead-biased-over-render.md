# Lead-Biased Over-Render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the power-saving frame cap makes displayed frames stale against a faster screen, position the fixed over-render margin ahead of camera motion so capped frames never bare the leading edge — proven by a new `underRenderPx` diagnostic.

**Architecture:** A pure `LeadBias` state machine (EMA velocity from successive build cameras → clamped, hysteresis-guarded bias) shifts the camera handed to `render()`; placement rides the existing exact `residualTransform`. A pure `underRenderPx` function measures uncovered viewport px and flows through the existing diagnostics poll into the soak JSONL. The host app activates the margin only when `capFps < display refresh rate`.

**Spec:** `docs/superpowers/specs/2026-07-24-lead-biased-over-render-design.md` — read it if any requirement below seems ambiguous.

**Tech Stack:** Dart/Flutter, `flutter_map` `MapCamera` projection API, package `packages/flutter_map_maplibre` (pure-logic + fake-renderer widget tests, no FFI in tests).

## Global Constraints

- Work in worktree `.claude/worktrees/maplibre-perf`, branch `power-saving`. All commands below assume its root; `cd` there explicitly first (the shell cwd resets unpredictably).
- All Flutter/Dart commands prefixed with `fvm`.
- After editing any `.dart` file, run `fvm dart format <every-touched-file>` (skip generated files).
- Stage by explicit path only — never `git add -A`. NEVER commit: `ios/Runner.xcodeproj/project.pbxproj`, `ios/Podfile.lock`, `packages/flutter_map_maplibre/example/ios/Podfile.lock`, `ios/Runner.app.dSYM.zip`, `.env`.
- Exact values (from the spec, verbatim): diagnostic key `underRenderPx`; host-app margin factor `1.15`; `leadTime = 2 × frameCap`; hysteresis quantum `8.0` logical px; safety factor `0.85`; EMA time constant `100ms`; existing cap constant `powerSavingFrameCap` (15ms, in `lib/providers/power_saving_mode.dart`) — do not rename or re-derive any of these.
- Package tests run from the package dir: `cd packages/flutter_map_maplibre && fvm flutter test`. App tests from the worktree root.
- Bias must be inert (byte-identical behavior to today) when `frameCap == null` or `overRenderFactor == 1.0`.

---

### Task 1: `LeadBias` — velocity estimator + bias policy (pure)

**Files:**
- Create: `packages/flutter_map_maplibre/lib/src/lead_bias.dart`
- Test: `packages/flutter_map_maplibre/test/lead_bias_test.dart`

**Interfaces:**
- Consumes: nothing (pure Dart, `dart:ui` Offset/Size only).
- Produces: `class LeadBias` with `Offset update({required Offset travel, required Duration elapsed, required Size maxBias, required Duration leadTime})`, getters `Offset get velocity`, `Offset get applied`, and `void reset()`. Task 3 constructs it with the default constructor `LeadBias()`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/flutter_map_maplibre/test/lead_bias_test.dart
import 'dart:ui';

import 'package:flutter_map_maplibre/src/lead_bias.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const maxBias = Size(100, 150);
  const lead = Duration(milliseconds: 30);
  const frame = Duration(milliseconds: 16);

  /// Feed [n] frames of constant [travel] per 16ms frame.
  void feed(LeadBias bias, Offset travel, int n) {
    for (var i = 0; i < n; i++) {
      bias.update(
        travel: travel,
        elapsed: frame,
        maxBias: maxBias,
        leadTime: lead,
      );
    }
  }

  test('constant velocity converges: applied = velocity × leadTime', () {
    final bias = LeadBias();
    // 30px per 16ms = 1875 px/s east; 40 frames = 640ms >> 100ms EMA tau.
    feed(bias, const Offset(30, 0), 40);
    expect(bias.velocity.dx, closeTo(1875, 20));
    // Hysteresis: applied settles within one 8px quantum below desired.
    expect(56.25 - bias.applied.dx, inInclusiveRange(0.0, 8.0));
    expect(bias.applied.dy, closeTo(0, 1e-9));
  });

  test('clamped to safetyFactor × maxBias per axis', () {
    final bias = LeadBias();
    // 6250 px/s → desired 187.5px, far beyond the 100px margin.
    feed(bias, const Offset(100, 0), 40);
    expect(bias.applied.dx, closeTo(85, 1)); // 0.85 × 100
  });

  test('freeze on zero travel: applied and velocity untouched', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    final appliedBefore = bias.applied;
    final velocityBefore = bias.velocity;
    feed(bias, Offset.zero, 10);
    expect(bias.applied, appliedBefore);
    expect(bias.velocity, velocityBefore);
  });

  test('freeze on zero elapsed', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    final before = bias.applied;
    bias.update(
      travel: const Offset(30, 0),
      elapsed: Duration.zero,
      maxBias: maxBias,
      leadTime: lead,
    );
    expect(bias.applied, before);
  });

  test('hysteresis: sub-quantum desired change leaves applied untouched', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    final before = bias.applied;
    // One slightly faster frame: EMA moves desired well under the 8px
    // quantum, so applied must not move at all.
    bias.update(
      travel: const Offset(31, 0),
      elapsed: frame,
      maxBias: maxBias,
      leadTime: lead,
    );
    expect(bias.applied, before);
  });

  test('reversal flips the bias within the time constant', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    feed(bias, const Offset(-30, 0), 40);
    expect(-56.25 - bias.applied.dx, inInclusiveRange(-8.0, 0.0));
  });

  test('reset zeroes everything', () {
    final bias = LeadBias();
    feed(bias, const Offset(30, 0), 40);
    bias.reset();
    expect(bias.applied, Offset.zero);
    expect(bias.velocity, Offset.zero);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd <package root> && fvm flutter test test/lead_bias_test.dart`
Expected: FAIL — `lead_bias.dart` does not exist.

- [ ] **Step 3: Write the implementation**

```dart
// packages/flutter_map_maplibre/lib/src/lead_bias.dart
import 'dart:math' as math;
import 'dart:ui';

/// Positions the fixed over-render margin ahead of camera motion.
///
/// Estimates the viewport's screen-space velocity from successive build
/// observations and yields a bias — how far ahead of the current center the
/// rendered camera should look — so capped frames, placed by the residual
/// transform, keep the leading edge covered.
///
/// Pure state machine: the widget feeds observations; nothing here touches
/// clocks or bindings. Hysteresis instead of decay: the applied bias moves
/// only when the desired bias strays more than [quantumPx], and freezes when
/// motion stops — a stale bias is harmless (content is correct wherever the
/// margin sits), while decaying it would keep changing the rendered camera
/// on a still map and veto the ticker park.
class LeadBias {
  LeadBias({
    this.timeConstant = const Duration(milliseconds: 100),
    this.quantumPx = 8.0,
    this.safetyFactor = 0.85,
  });

  /// EMA time constant of the velocity estimate.
  final Duration timeConstant;

  /// Applied-bias dead band, logical px.
  final double quantumPx;

  /// Fraction of the margin the bias may consume; the remainder stays as
  /// trailing reserve so an abrupt reversal doesn't bare the very next
  /// capped frame.
  final double safetyFactor;

  Offset _velocity = Offset.zero;
  Offset _applied = Offset.zero;

  /// Latest velocity estimate in screen px/s, pointing the way the viewport
  /// travels (where new content appears).
  Offset get velocity => _velocity;

  /// The bias renders are currently shifted by.
  Offset get applied => _applied;

  void reset() {
    _velocity = Offset.zero;
    _applied = Offset.zero;
  }

  /// Feed one build's observation; returns the bias to apply this build.
  ///
  /// [travel] is how far the viewport moved since the previous observation,
  /// in current-camera screen px. [maxBias] is the per-axis margin available
  /// for lead ((renderSize − viewport) / 2). [leadTime] is how far ahead to
  /// look — the caller passes twice the frame cap.
  Offset update({
    required Offset travel,
    required Duration elapsed,
    required Size maxBias,
    required Duration leadTime,
  }) {
    if (elapsed <= Duration.zero || travel == Offset.zero) return _applied;
    final dt = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final alpha =
        1 - math.exp(-elapsed.inMicroseconds / timeConstant.inMicroseconds);
    _velocity = Offset.lerp(_velocity, travel / dt, alpha)!;
    final lead = leadTime.inMicroseconds / Duration.microsecondsPerSecond;
    final desired = Offset(
      (_velocity.dx * lead).clamp(
        -maxBias.width * safetyFactor,
        maxBias.width * safetyFactor,
      ),
      (_velocity.dy * lead).clamp(
        -maxBias.height * safetyFactor,
        maxBias.height * safetyFactor,
      ),
    );
    if ((desired - _applied).distance > quantumPx) _applied = desired;
    return _applied;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd <package root> && fvm flutter test test/lead_bias_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Format and commit**

```bash
cd <host app worktree>
fvm dart format packages/flutter_map_maplibre/lib/src/lead_bias.dart packages/flutter_map_maplibre/test/lead_bias_test.dart
git add packages/flutter_map_maplibre/lib/src/lead_bias.dart packages/flutter_map_maplibre/test/lead_bias_test.dart
git commit -m "feat(flutter_map_maplibre): lead-bias velocity estimator and policy"
```

---

### Task 2: `underRenderPx` — uncovered-viewport metric (pure)

**Files:**
- Create: `packages/flutter_map_maplibre/lib/src/under_render.dart`
- Test: `packages/flutter_map_maplibre/test/under_render_test.dart`

**Interfaces:**
- Consumes: `MapCamera` from `flutter_map` (projection methods only).
- Produces: `double underRenderPx({required MapCamera rendered, required Size renderSize, required MapCamera current, required Rect visibleRect})` — the widest uncovered strip of the visible viewport in logical px, 0 when fully covered. `rendered` is crop-sized (its canvas is `renderSize`, centered, same convention as `residualTransform`'s `withNonRotatedSize` call). Task 4 calls it from the widget.

- [ ] **Step 1: Write the failing test**

```dart
// packages/flutter_map_maplibre/test/under_render_test.dart
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/src/under_render.dart';
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

/// [camera] panned [px] east (screen +x) at the same zoom.
MapCamera pannedEast(MapCamera camera, double px) => camera.withPosition(
  center: camera.screenOffsetToLatLng(
    camera.nonRotatedSize.center(Offset.zero) + Offset(px, 0),
  ),
);

void main() {
  final base = cameraAt();
  final fullRect = Offset.zero & const Size(400, 800);

  test('same camera, no margin: fully covered', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(400, 800),
        current: base,
        visibleRect: fullRect,
      ),
      closeTo(0, 0.01),
    );
  });

  test('30px pan with no margin bares a 30px strip', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(400, 800),
        current: pannedEast(base, 30),
        visibleRect: fullRect,
      ),
      closeTo(30, 0.1),
    );
  });

  test('a 50px symmetric margin covers a 30px pan', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(500, 900),
        current: pannedEast(base, 30),
        visibleRect: fullRect,
      ),
      closeTo(0, 0.01),
    );
  });

  test('a 60px pan overruns the 50px margin by 10', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(500, 900),
        current: pannedEast(base, 60),
        visibleRect: fullRect,
      ),
      closeTo(10, 0.1),
    );
  });

  test('lead bias extends the runway ahead and shortens it behind', () {
    final biased = pannedEast(base, 40); // rendered 40px ahead of base
    // 60px pan east: viewport sits 20px past base center relative to the
    // biased canvas center; margin 50 → covered.
    expect(
      underRenderPx(
        rendered: biased,
        renderSize: const Size(500, 900),
        current: pannedEast(base, 60),
        visibleRect: fullRect,
      ),
      closeTo(0, 0.01),
    );
    // 20px pan WEST: trailing runway is 50 − 40 = 10 → 10px bared.
    expect(
      underRenderPx(
        rendered: biased,
        renderSize: const Size(500, 900),
        current: pannedEast(base, -20),
        visibleRect: fullRect,
      ),
      closeTo(10, 0.1),
    );
  });

  test('zoom-out bares the edges', () {
    expect(
      underRenderPx(
        rendered: base,
        renderSize: const Size(400, 800),
        current: base.withZoom(12.5),
        visibleRect: fullRect,
      ),
      greaterThan(0),
    );
  });

  test('cropped viewport of a taller layer, the bottom-sheet shape', () {
    // Layer 400x1000, visible bottom 400x800 strip; rendered camera is the
    // crop itself → covered exactly.
    final layer = cameraAt(size: const Size(400, 1000));
    final visible = const Rect.fromLTWH(0, 200, 400, 800);
    final crop = layer
        .withNonRotatedSize(visible.size)
        .withPosition(center: layer.screenOffsetToLatLng(visible.center));
    expect(
      underRenderPx(
        rendered: crop,
        renderSize: const Size(400, 800),
        current: layer,
        visibleRect: visible,
      ),
      closeTo(0, 0.01),
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd <package root> && fvm flutter test test/under_render_test.dart`
Expected: FAIL — `under_render.dart` does not exist.

- [ ] **Step 3: Write the implementation**

```dart
// packages/flutter_map_maplibre/lib/src/under_render.dart
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';

/// The widest strip of the visible viewport, in logical px, that the
/// rendered texture leaves uncovered — 0 when the texture covers it fully.
///
/// [rendered] is the camera the front buffer was rendered for (crop-sized;
/// its canvas is [renderSize], centered — the same convention
/// `residualTransform` consumes via `withNonRotatedSize`). [current] is the
/// camera being painted, whose visible part is [visibleRect] of its screen.
///
/// Each corner of the visible viewport is projected into the rendered
/// canvas; the worst per-axis overshoot beyond the canvas bounds is the
/// uncovered strip. The camera-to-camera mapping is affine and the viewport
/// convex, so the maximum over the four corners is exact.
double underRenderPx({
  required MapCamera rendered,
  required Size renderSize,
  required MapCamera current,
  required Rect visibleRect,
}) {
  final canvas = rendered.withNonRotatedSize(renderSize);
  var worst = 0.0;
  for (final corner in <Offset>[
    visibleRect.topLeft,
    visibleRect.topRight,
    visibleRect.bottomLeft,
    visibleRect.bottomRight,
  ]) {
    final p = canvas.latLngToScreenOffset(
      current.screenOffsetToLatLng(corner),
    );
    final outside = [
      -p.dx,
      p.dx - renderSize.width,
      -p.dy,
      p.dy - renderSize.height,
    ].reduce(math.max);
    if (outside > worst) worst = outside;
  }
  return worst;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd <package root> && fvm flutter test test/under_render_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Format and commit**

```bash
cd <host app worktree>
fvm dart format packages/flutter_map_maplibre/lib/src/under_render.dart packages/flutter_map_maplibre/test/under_render_test.dart
git add packages/flutter_map_maplibre/lib/src/under_render.dart packages/flutter_map_maplibre/test/under_render_test.dart
git commit -m "feat(flutter_map_maplibre): underRenderPx uncovered-viewport metric"
```

---

### Task 3: Wire the bias into `MapLibreBasemap`

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`
- Test: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart` (extend)

**Interfaces:**
- Consumes: `LeadBias` from Task 1 (`update`, `reset`, `applied`); `cropCamera` (existing).
- Produces: when `widget.frameCap != null` and a margin exists, `render()` receives the cropped camera shifted ahead by the applied bias; placement of any frame whose rendered camera differs from the build camera goes through `residualTransform`. Behavior byte-identical to today when inert.

- [ ] **Step 1: Write the failing tests**

Add a `frameCap` parameter to the existing `pumpSizedMap` helper in `maplibre_basemap_test.dart` (thread it to the `MapLibreBasemap` constructor exactly like `overRenderFactor`):

```dart
  Future<void> pumpSizedMap(
    WidgetTester tester, {
    required double height,
    Size? fixedViewport,
    double overRenderFactor = 1.0,
    Duration? frameCap,
  }) async {
```
…and inside the widget: `frameCap: frameCap,` next to `overRenderFactor`.

Add these imports at the top of the test file:

```dart
import 'package:flutter_map_maplibre/src/viewport_crop.dart';
```

Add these tests at the end of `main()`:

```dart
  /// Drive the camera east at ~1875 px/s (30px per 16ms frame) for [frames]
  /// frames — enough to converge the 100ms-EMA velocity estimate.
  Future<void> panEast(WidgetTester tester, {int frames = 25}) async {
    for (var i = 0; i < frames; i++) {
      final cam = controller.camera;
      controller.move(
        cam.screenOffsetToLatLng(
          cam.nonRotatedSize.center(Offset.zero) + const Offset(30, 0),
        ),
        cam.zoom,
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('lead bias: sustained motion shifts the rendered camera ahead', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.5,
      frameCap: const Duration(milliseconds: 15),
    );
    await panEast(tester);

    // 1875 px/s × 30ms lead = 56.25px east, inside the 85px clamp
    // (0.85 × 100px half-margin). Measured in the cropped camera's screen:
    // the rendered center must sit ahead of the crop center.
    final shown = renderer.lastRenderedCamera!;
    final cropped = cropCamera(
      controller.camera,
      const Rect.fromLTWH(0, 200, 400, 600),
    );
    final p = cropped.latLngToScreenOffset(shown.center);
    // Tolerance 9: EMA convergence residue plus up to the 8px hysteresis
    // quantum of lag between desired and applied.
    expect(p.dx - 200, closeTo(56.25, 9));
    expect(p.dy - 300, closeTo(0, 1));
  });

  testWidgets('no cap means no bias: rendered camera is the plain crop', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.5,
    );
    await panEast(tester);
    final shown = renderer.lastRenderedCamera!;
    final cropped = cropCamera(
      controller.camera,
      const Rect.fromLTWH(0, 200, 400, 600),
    );
    final p = cropped.latLngToScreenOffset(shown.center);
    expect(p.dx, closeTo(200, 1e-6));
    expect(p.dy, closeTo(300, 1e-6));
  });

  testWidgets('bias freezes when motion stops: no new camera jumps', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.5,
      frameCap: const Duration(milliseconds: 15),
    );
    await panEast(tester);
    final settled = renderer.lastRenderedCamera!;

    // Motion stops; a tick-driven rebuild must re-render the SAME camera
    // (dedup-friendly), not a decayed-bias variant.
    renderer.tickResult = true;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final after = renderer.lastRenderedCamera!;
    expect(after.center, settled.center);
    expect(after.zoom, settled.zoom);
  });

  testWidgets('biased success frame is placed exactly by the residual', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.5,
      frameCap: const Duration(milliseconds: 15),
    );
    await panEast(tester);

    // Ground truth: pushing a world point through the placement transform
    // must land it where the current full-layer camera projects it.
    final shown = renderer.lastRenderedCamera!;
    final canvas = shown.withNonRotatedSize(const Size(600, 900));
    final transform = basemapTransform(tester);
    final point = controller.camera.center;
    final placed = MatrixUtils.transformPoint(
      transform,
      canvas.latLngToScreenOffset(point),
    );
    final expected = controller.camera.latLngToScreenOffset(point);
    expect((placed - expected).distance, lessThan(0.1));
  });
```

`MatrixUtils` needs `import 'package:flutter/rendering.dart';` in the test file.

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `cd <package root> && fvm flutter test test/maplibre_basemap_test.dart`
Expected: the 3 bias tests FAIL (rendered camera is never shifted); `no cap means no bias` may already pass; all pre-existing tests still PASS.

- [ ] **Step 3: Implement in `maplibre_basemap.dart`**

Add imports:

```dart
import 'lead_bias.dart';
```

Add state fields to `_MapLibreBasemapState` (next to `_parks`):

```dart
  final _leadBias = LeadBias();
  MapCamera? _prevBiasCamera;
  Duration? _prevBiasTime;
```

Add this method to `_MapLibreBasemapState`:

```dart
  /// The camera to render: [cropped] shifted ahead of motion so the fixed
  /// over-render margin becomes runway for capped frames. Active only when
  /// a frame cap is set and a margin exists; otherwise returns [cropped]
  /// itself (same instance — the caller uses identity to detect bias).
  MapCamera _biasedCamera(MapCamera cropped, Size renderSize) {
    final viewport = cropped.nonRotatedSize;
    final maxBias = Size(
      (renderSize.width - viewport.width) / 2,
      (renderSize.height - viewport.height) / 2,
    );
    final cap = widget.frameCap;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    if (cap == null || maxBias.isEmpty) {
      _leadBias.reset();
      _prevBiasCamera = cropped;
      _prevBiasTime = now;
      return cropped;
    }
    final prev = _prevBiasCamera;
    final prevTime = _prevBiasTime;
    final elapsed = prevTime == null ? Duration.zero : now - prevTime;
    final center = viewport.center(Offset.zero);
    final travel = prev == null
        ? Offset.zero
        : center - cropped.latLngToScreenOffset(prev.center);
    _prevBiasCamera = cropped;
    _prevBiasTime = now;
    final bias = _leadBias.update(
      travel: travel,
      elapsed: elapsed,
      maxBias: maxBias,
      leadTime: cap * 2,
    );
    if (bias == Offset.zero) return cropped;
    return cropped.withPosition(
      center: cropped.screenOffsetToLatLng(center + bias),
    );
  }
```

Note: `maxBias.isEmpty` is `Size`'s "either dimension ≤ 0" — margin on both axes is required (the factor enlarges both).

In `build`, replace the render call block:

```dart
        // The same-frame render: by the time this build returns, the front
        // buffer shows [visibleRect]'s view of [camera] (on success). No
        // stamp, no estimate. Under a frame cap the target is lead-biased
        // ahead of motion so capped frames keep the leading edge covered.
        _renderer.frameCap = widget.frameCap;
        final cropped = cropCamera(camera, visibleRect);
        final target = _biasedCamera(cropped, renderSize);
        final biased = !identical(target, cropped);
        final rendered = _renderer.render(target);
        final shown = _renderer.lastRenderedCamera;
```

Replace the transform selection (keep the `placed` construction and its comment as is, but append one sentence to the comment: `A biased success frame goes through the residual instead — exact for any rendered/current pair, so no placement jump at the bias boundary.`):

```dart
        final transform = ((rendered && !biased) || shown == null)
            ? placed
            : widget.applyResidualTransform
            ? residualTransform(
                rendered: shown.withNonRotatedSize(renderSize),
                current: camera,
              )
            : placed;
```

- [ ] **Step 4: Run the full package suite**

Run: `cd <package root> && fvm flutter test`
Expected: ALL PASS — new bias tests and every pre-existing test (inertness: the no-cap and factor-1.0 paths return the identical cropped instance, so the identity fast path is untouched).

- [ ] **Step 5: Format and commit**

```bash
cd <host app worktree>
fvm dart format packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git add packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git commit -m "feat(flutter_map_maplibre): lead-bias the rendered camera under a frame cap"
```

---

### Task 4: `underRenderPx` diagnostic + recreate on factor change

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`
- Test: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart` (extend)

**Interfaces:**
- Consumes: `underRenderPx(...)` from Task 2; the `biased`/`rendered`/`shown` locals from Task 3's build.
- Produces: diagnostics key `'underRenderPx'` (double, max since last poll, reset each poll); changing `overRenderFactor` recreates the session.

- [ ] **Step 1: Write the failing tests**

Add to `maplibre_basemap_test.dart`:

```dart
  testWidgets('capped frame with margin+bias reports underRenderPx 0', (
    tester,
  ) async {
    Map<String, Object?>? latest;
    // Diagnostics require onDiagnostics; extend pumpSizedMap once more with
    // an onDiagnostics parameter threaded to the widget.
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.5,
      frameCap: const Duration(milliseconds: 15),
      onDiagnostics: (d) => latest = d,
    );
    await panEast(tester);

    // The capped frame: render refused, camera 20px further east — well
    // inside the ~156px lead runway.
    renderer.renderResult = false;
    final cam = controller.camera;
    controller.move(
      cam.screenOffsetToLatLng(
        cam.nonRotatedSize.center(Offset.zero) + const Offset(20, 0),
      ),
      cam.zoom,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(seconds: 1)); // diagnostics poll
    expect(latest!['underRenderPx'], closeTo(0, 0.01));
  });

  testWidgets('capped frame without margin reports the bared strip', (
    tester,
  ) async {
    Map<String, Object?>? latest;
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.0,
      frameCap: const Duration(milliseconds: 15),
      onDiagnostics: (d) => latest = d,
    );
    await panEast(tester);

    renderer.renderResult = false;
    final cam = controller.camera;
    controller.move(
      cam.screenOffsetToLatLng(
        cam.nonRotatedSize.center(Offset.zero) + const Offset(20, 0),
      ),
      cam.zoom,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(seconds: 1));
    expect(latest!['underRenderPx'], closeTo(20, 0.5));
  });

  testWidgets('the underRenderPx max resets after each poll', (tester) async {
    Map<String, Object?>? latest;
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.0,
      frameCap: const Duration(milliseconds: 15),
      onDiagnostics: (d) => latest = d,
    );
    await panEast(tester);
    renderer.renderResult = false;
    final cam = controller.camera;
    controller.move(
      cam.screenOffsetToLatLng(
        cam.nonRotatedSize.center(Offset.zero) + const Offset(20, 0),
      ),
      cam.zoom,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(seconds: 1));
    expect(latest!['underRenderPx'], closeTo(20, 0.5));

    // A quiet interval: the stat must not stick at its historic max.
    renderer.renderResult = true;
    controller.move(controller.camera.center, controller.camera.zoom + 0.01);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(seconds: 1));
    expect(latest!['underRenderPx'], closeTo(0, 0.01));
  });

  testWidgets('changing overRenderFactor recreates the session', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.0,
    );
    expect(renderer.createCalls, 1);
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.5,
    );
    await tester.pump();
    expect(renderer.createCalls, 2);
    expect(renderer.createdWidth, 600);
    expect(renderer.createdHeight, 900);
  });
```

Extend `pumpSizedMap` with `ValueChanged<Map<String, Object?>>? onDiagnostics` threaded to the widget (like `pumpMap` does).

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `cd <package root> && fvm flutter test test/maplibre_basemap_test.dart`
Expected: the 4 new tests FAIL (`underRenderPx` key absent; factor change does not recreate).

- [ ] **Step 3: Implement in `maplibre_basemap.dart`**

Import:

```dart
import 'under_render.dart';
```

Add state field:

```dart
  double _underRenderPxMax = 0;
```

In `build`, immediately after the `transform` selection from Task 3, add:

```dart
        // The acceptance instrument for the lead bias: whenever the shown
        // frame is not this build's camera, measure the bared strip.
        if (shown != null && (!rendered || biased)) {
          final uncovered = underRenderPx(
            rendered: shown,
            renderSize: renderSize,
            current: camera,
            visibleRect: visibleRect,
          );
          if (uncovered > _underRenderPxMax) _underRenderPxMax = uncovered;
        }
```

In `_startDiagnosticsPolling`, add the key and reset the max:

```dart
      widget.onDiagnostics?.call(<String, Object?>{
        ..._renderer.diagnostics(),
        'tickerActive': _ticker?.isActive ?? false,
        'parks': _parks,
        'underRenderPx': _underRenderPxMax,
      });
      _underRenderPxMax = 0;
```

Make session identity factor-aware (review finding: a `didUpdateWidget`-clears-`_viewportSize` approach loses the recreate when a factor change lands while a `_create` is in flight — the stale create restores `_viewportSize` and `needsCreate` never retries):

- Add a state field `double? _sessionFactor;` — the `overRenderFactor` the live session was created with; set it inside `_create`'s success `setState`.
- Extend `_create`'s stale-callback defense (the early return comparing sizes within 1px) to also require `_sessionFactor == widget.overRenderFactor`.
- Extend `build`'s `needsCreate` with `|| _sessionFactor != widget.overRenderFactor`.
- No `didUpdateWidget` change — the factor-aware `needsCreate` alone is race-free: even a stale-factor create landing late is caught by the next build's mismatch.

Also add a race test using `installChannelMock`'s `gate` parameter: hold `createTextures` open, start at factor 1.0, rebuild with 1.5 while the create is in flight, release the gate, pump until settled, and assert the session ends up created at 600×900 with `createCalls ≥ 2`.

- [ ] **Step 4: Run the full package suite**

Run: `cd <package root> && fvm flutter test`
Expected: ALL PASS.

- [ ] **Step 5: Format and commit**

```bash
cd <host app worktree>
fvm dart format packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git add packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git commit -m "feat(flutter_map_maplibre): underRenderPx diagnostic and factor-change recreate"
```

---

### Task 5: host app activation rule + diagnostics surfacing

**Files:**
- Modify: `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`
- Test: `test/screens/main_map/maplibre_basemap_layer_test.dart` (create)

**Interfaces:**
- Consumes: existing `powerSavingFrameCap` (15ms) and `PowerSavingProvider.savingActiveOf` from `package:host_app/providers/...`; `View.of(context).display.refreshRate`.
- Produces: top-level `@visibleForTesting bool leadMarginActive({required bool saving, required Duration frameCap, required double refreshRate})` in the layer file; `overRenderFactor` wired to `1.15` only when active.

- [ ] **Step 1: Write the failing test**

```dart
// test/screens/main_map/maplibre_basemap_layer_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:host_app/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart';

void main() {
  test('lead margin only when capped below the display rate', () {
    const cap = Duration(milliseconds: 15); // ≈66.7fps
    expect(
      leadMarginActive(saving: true, frameCap: cap, refreshRate: 120),
      isTrue,
    );
    expect(
      leadMarginActive(saving: true, frameCap: cap, refreshRate: 60),
      isFalse,
      reason: 'a 60Hz panel keeps up with the cap; no stale frames to cover',
    );
    expect(
      leadMarginActive(saving: false, frameCap: cap, refreshRate: 120),
      isFalse,
      reason: 'cap off: every displayed frame is fresh',
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd <host app worktree> && fvm flutter test test/screens/main_map/maplibre_basemap_layer_test.dart`
Expected: FAIL — `leadMarginActive` is not defined.

- [ ] **Step 3: Implement in `maplibre_basemap_layer.dart`**

Add the predicate at top level (after the `maplibreLogPhase` declaration):

```dart
/// Whether the lead-biased over-render margin should be active: power saving
/// on AND the native frame cap below the display's refresh rate. At
/// cap ≥ refresh every displayed frame is fresh — margin would cost render
/// area for nothing, so non-ProMotion devices never pay it. (Spec:
/// docs/superpowers/specs/2026-07-24-lead-biased-over-render-design.md.)
@visibleForTesting
bool leadMarginActive({
  required bool saving,
  required Duration frameCap,
  required double refreshRate,
}) =>
    saving &&
    Duration.millisecondsPerSecond / frameCap.inMilliseconds < refreshRate;
```

Replace the `_overRenderFactor` constant and its experiment-era comment:

```dart
  /// The lead-biased over-render margin (2026-07-24 spec): +15% per axis of
  /// runway, positioned ahead of motion by the package's velocity estimator.
  /// Applied only while [leadMarginActive] — capped frames are the only ones
  /// the residual transform can bare, so uncapped sessions render no margin.
  static const _overRenderFactor = 1.15;
```

Replace the `build` method's wiring:

```dart
  @override
  Widget build(BuildContext context) {
    final dark = context.watch<ThemeProvider>().brightness == Brightness.dark;
    final saving = PowerSavingProvider.savingActiveOf(context);
    final leadMargin = leadMarginActive(
      saving: saving,
      frameCap: powerSavingFrameCap,
      refreshRate: View.of(context).display.refreshRate,
    );
    return MapLibreBasemap(
      styleUrl: dark ? _darkStyle : _lightStyle,
      // ~60fps native render cap while power saving; the Flutter pipeline
      // and gesture tracking stay at the display's native rate.
      frameCap: saving ? powerSavingFrameCap : null,
      overRenderFactor: leadMargin ? _overRenderFactor : 1.0,
```
(the remaining named arguments — `fixedViewport`, `onDiagnostics` — stay exactly as they are).

In the MLNDIAG `debugPrint`, add after the `skip=` line:

```dart
          'under=${d['underRenderPx']} '
```

In `_numbersPanel`'s row list, add after `${row('skippedTicks')}`:

```dart
                      '${row('underRenderPx')}'
```

- [ ] **Step 4: Run the tests and analyzer**

Run: `cd <host app worktree> && fvm flutter test test/screens/main_map/maplibre_basemap_layer_test.dart && fvm flutter analyze`
Expected: test PASS; analyze reports no new issues.

- [ ] **Step 5: Format and commit**

```bash
cd <host app worktree>
fvm dart format lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart test/screens/main_map/maplibre_basemap_layer_test.dart
git add lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart test/screens/main_map/maplibre_basemap_layer_test.dart
git commit -m "feat(map): activate the lead-biased margin when capped below the display rate"
```

---

### Task 6: Device acceptance (manual, with the user)

Not a code task — run after Tasks 1–5 land.

- [ ] Build and install a profile build from the worktree:

```bash
cd <host app worktree>
fvm flutter build ios --profile
xcrun devicectl device install app --device 80D04F4B-B11B-50CA-B65A-08E6B38B4A6E build/ios/iphoneos/Runner.app
```

- [ ] On the iPhone 14 Pro (120Hz): debug menu → power saving ON → maplibre basemap ON → run a scripted soak leg (the v4 script's fling phases are the worst case).
- [ ] Pull the JSONL (devicectl `copy from`, see memory note) and check: `underRenderPx` is 0 (or ≤1px) in every sample; `cameraRenders`/s unchanged vs the cap-60 baseline (bias must not add renders); no placement jumps visible during flings.
- [ ] Control run with the margin forced off (temporarily pass `overRenderFactor: 1.0`): `underRenderPx` > 0 during fling phases — proving the metric detects what the margin fixes.
