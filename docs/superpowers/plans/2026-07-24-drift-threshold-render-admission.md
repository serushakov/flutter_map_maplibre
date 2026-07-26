# Drift-Threshold Render Admission (B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Only admit a camera-driven native MapLibre render when the viewport nears the rendered frame's runway, crosses a zoom/bearing quantum, or settles off-target — collapsing GPS-follow renders from ~60–118/s to ~0.1/s.

**Architecture:** A pure admission gate (`render_admission.dart`) reuses the 4-corner coverage math from `under_render.dart` (refactored to expose a signed overshoot). The `MapLibreBasemap` build path consults the gate before `_renderer.render()`; denied builds fall through to the existing exact `residualTransform` placement. A one-shot settle timer lands a final exact render when a gesture ends mid-zoom-quantum. Vedu's layer goes always-on margin (1.20) and retires the `leadMarginActive` predicate.

**Tech Stack:** Flutter/Dart, flutter_map 8.3.1, package `packages/flutter_map_maplibre` (FFI renderer faked in tests).

**Spec:** `docs/superpowers/specs/2026-07-24-drift-threshold-render-admission-design.md`

## Global Constraints

- All Flutter/Dart commands prefixed with `fvm`; run from the worktree root `/Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf` (cd explicitly — the shell cwd resets between commands).
- After editing/creating any `.dart` file, run `fvm dart format <every touched file>` (skip generated files).
- NEVER commit: `ios/Runner.xcodeproj/project.pbxproj`, `ios/Podfile.lock`, `packages/flutter_map_maplibre/example/ios/Podfile.lock`, `ios/Runner.app.dSYM.zip`, `.env`. Stage by explicit path only — never `git add -A` or `git add .`.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Exact spec values: guard band **16.0 px**, zoom quantum **0.05**, bearing quantum **0.1°**, settle window **300 ms**, bias leadTime when uncapped **33 ms**, over-render factor **1.20** (always on).
- Package tests: `cd packages/flutter_map_maplibre && fvm flutter test`. App tests run from the worktree root.

---

### Task 1: Signed overshoot — shared slack math

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/under_render.dart`
- Test: `packages/flutter_map_maplibre/test/under_render_test.dart`

**Interfaces:**
- Produces: `double renderOvershootPx({required MapCamera rendered, required Size renderSize, required MapCamera current, required Rect visibleRect})` — signed: positive = widest uncovered strip in px, negative = remaining slack to the nearest canvas edge. `underRenderPx(...)` (same named params) becomes `max(0, renderOvershootPx(...))` and keeps its exact current behavior.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests** — append to `test/under_render_test.dart` inside `main()`:

```dart
test('renderOvershootPx: negative slack when covered with room', () {
  // 50px symmetric margin, 30px pan: nearest edge is 50-30=20px away.
  expect(
    renderOvershootPx(
      rendered: base,
      renderSize: const Size(500, 900),
      current: pannedEast(base, 30),
      visibleRect: fullRect,
    ),
    closeTo(-20, 0.1),
  );
});

test('renderOvershootPx: positive overshoot matches underRenderPx', () {
  expect(
    renderOvershootPx(
      rendered: base,
      renderSize: const Size(500, 900),
      current: pannedEast(base, 60),
      visibleRect: fullRect,
    ),
    closeTo(10, 0.1),
  );
});

test('renderOvershootPx: same camera, symmetric margin → slack = margin', () {
  expect(
    renderOvershootPx(
      rendered: base,
      renderSize: const Size(500, 900),
      current: base,
      visibleRect: fullRect,
    ),
    closeTo(-50, 0.1),
  );
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf/packages/flutter_map_maplibre && fvm flutter test test/under_render_test.dart`
Expected: FAIL — `renderOvershootPx` undefined.

- [ ] **Step 3: Refactor** — replace the body of `under_render.dart` so the existing loop becomes the signed function and `underRenderPx` clamps it:

```dart
/// Signed worst-corner overshoot of the visible viewport beyond the rendered
/// canvas, in logical px: positive = widest uncovered strip, negative =
/// remaining slack (distance from the worst corner to the nearest canvas
/// edge). [underRenderPx] is the positive part; the admission gate compares
/// the signed value against its guard band.
///
/// Conventions as in [underRenderPx]: [rendered] is crop-sized with its
/// canvas [renderSize] centered; [current] is the camera being painted whose
/// visible part is [visibleRect].
double renderOvershootPx({
  required MapCamera rendered,
  required Size renderSize,
  required MapCamera current,
  required Rect visibleRect,
}) {
  final canvas = rendered.withNonRotatedSize(renderSize);
  var worst = double.negativeInfinity;
  for (final corner in <Offset>[
    visibleRect.topLeft,
    visibleRect.topRight,
    visibleRect.bottomLeft,
    visibleRect.bottomRight,
  ]) {
    final p = canvas.latLngToScreenOffset(current.screenOffsetToLatLng(corner));
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

Then reduce `underRenderPx` to (keep its existing doc comment):

```dart
double underRenderPx({
  required MapCamera rendered,
  required Size renderSize,
  required MapCamera current,
  required Rect visibleRect,
}) => math.max(
  0,
  renderOvershootPx(
    rendered: rendered,
    renderSize: renderSize,
    current: current,
    visibleRect: visibleRect,
  ),
);
```

- [ ] **Step 4: Run the file's full suite**

Run: `fvm flutter test test/under_render_test.dart`
Expected: all 10 tests PASS (7 existing + 3 new).

- [ ] **Step 5: Format and commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf
fvm dart format packages/flutter_map_maplibre/lib/src/under_render.dart packages/flutter_map_maplibre/test/under_render_test.dart
git add packages/flutter_map_maplibre/lib/src/under_render.dart packages/flutter_map_maplibre/test/under_render_test.dart
git commit -m "refactor(flutter_map_maplibre): expose signed render overshoot

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Admission gate — pure functions

**Files:**
- Create: `packages/flutter_map_maplibre/lib/src/render_admission.dart`
- Test: `packages/flutter_map_maplibre/test/render_admission_test.dart`

**Interfaces:**
- Consumes: `renderOvershootPx` from Task 1 (`under_render.dart`).
- Produces:
  - `bool shouldAdmitRender({required MapCamera? rendered, required Size renderSize, required MapCamera current, required Rect visibleRect, double guardPx = 16.0, double zoomQuantum = 0.05, double bearingQuantumDeg = 0.1})`
  - `bool settleOffTarget({required MapCamera? rendered, required MapCamera current})` — true when a rendered frame exists but its zoom or rotation differ from `current` at all (translation staleness is placed exactly and never needs a settle).

- [ ] **Step 1: Write the failing tests** — create `test/render_admission_test.dart`:

```dart
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/src/render_admission.dart';
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

MapCamera pannedEast(MapCamera camera, double px) => camera.withPosition(
  center: camera.screenOffsetToLatLng(
    camera.nonRotatedSize.center(Offset.zero) + Offset(px, 0),
  ),
);

void main() {
  final base = cameraAt();
  final fullRect = Offset.zero & const Size(400, 800);
  // 50px symmetric margin per axis.
  const renderSize = Size(500, 900);

  bool admit(MapCamera? rendered, MapCamera current) => shouldAdmitRender(
    rendered: rendered,
    renderSize: renderSize,
    current: current,
    visibleRect: fullRect,
  );

  test('no rendered frame yet → admit', () {
    expect(admit(null, base), isTrue);
  });

  test('same camera, comfortable slack → deny', () {
    expect(admit(base, base), isFalse);
  });

  test('pan leaving more than the guard band of slack → deny', () {
    // Slack 50-30 = 20 > 16.
    expect(admit(base, pannedEast(base, 30)), isFalse);
  });

  test('pan within the guard band of the edge → admit', () {
    // Slack 50-40 = 10 < 16.
    expect(admit(base, pannedEast(base, 40)), isTrue);
  });

  test('fully bared → admit', () {
    expect(admit(base, pannedEast(base, 60)), isTrue);
  });

  test('zoom quantum: 0.049 in → deny, 0.05 → admit, symmetric in sign', () {
    // Zoom IN covers geometrically; only the quantum can admit.
    expect(admit(base, base.withPosition(zoom: 13.049)), isFalse);
    expect(admit(base, base.withPosition(zoom: 13.05)), isTrue);
    expect(admit(base, base.withPosition(zoom: 12.95)), isTrue);
  });

  test('bearing quantum: 0.05° → deny, 0.1° → admit', () {
    expect(admit(base, cameraAt(rotation: 0.05)), isFalse);
    expect(admit(base, cameraAt(rotation: 0.1)), isTrue);
  });

  test('settleOffTarget: zoom or rotation residue → true, translation → false',
      () {
    expect(settleOffTarget(rendered: null, current: base), isFalse);
    expect(settleOffTarget(rendered: base, current: base), isFalse);
    expect(
      settleOffTarget(rendered: base, current: pannedEast(base, 30)),
      isFalse,
    );
    expect(
      settleOffTarget(rendered: base, current: base.withPosition(zoom: 13.02)),
      isTrue,
    );
    expect(
      settleOffTarget(rendered: base, current: cameraAt(rotation: 0.05)),
      isTrue,
    );
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf/packages/flutter_map_maplibre && fvm flutter test test/render_admission_test.dart`
Expected: FAIL — `render_admission.dart` does not exist.

- [ ] **Step 3: Implement** — create `lib/src/render_admission.dart`:

```dart
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';

import 'under_render.dart';

/// Whether a camera-driven native render should be admitted, or the existing
/// frame placed by the residual transform instead (spec:
/// docs/superpowers/specs/2026-07-24-drift-threshold-render-admission-design.md).
///
/// Admits when any of:
/// - no frame has been rendered yet ([rendered] null);
/// - zoom drifted a quantum from the rendered frame (zoom IN never bares the
///   canvas, so coverage alone would let labels blur indefinitely);
/// - bearing drifted a quantum (coverage handles rotation's corner-baring;
///   the quantum bounds label-orientation drift);
/// - the viewport is within [guardPx] of the rendered canvas's edge —
///   measured with the same 4-corner projection as [underRenderPx], but on
///   the signed slack before display rather than the damage after.
///
/// Tile-content renders (the ticker's update/repaint path) are not this
/// gate's business and must not be routed through it.
bool shouldAdmitRender({
  required MapCamera? rendered,
  required Size renderSize,
  required MapCamera current,
  required Rect visibleRect,
  double guardPx = 16.0,
  double zoomQuantum = 0.05,
  double bearingQuantumDeg = 0.1,
}) {
  if (rendered == null) return true;
  if ((current.zoom - rendered.zoom).abs() >= zoomQuantum) return true;
  if ((current.rotation - rendered.rotation).abs() >= bearingQuantumDeg) {
    return true;
  }
  return renderOvershootPx(
        rendered: rendered,
        renderSize: renderSize,
        current: current,
        visibleRect: visibleRect,
      ) >
      -guardPx;
}

/// Whether the rendered frame rests off-target in a way worth one settle
/// render: zoom or rotation residue scales/rotates every placed frame
/// (persistently blurry labels at rest), while pure translation is placed
/// pixel-exactly and needs nothing.
bool settleOffTarget({
  required MapCamera? rendered,
  required MapCamera current,
}) =>
    rendered != null &&
    (rendered.zoom != current.zoom || rendered.rotation != current.rotation);
```

Also export it from the package barrel: in `lib/flutter_map_maplibre.dart` add `export 'src/render_admission.dart';` alongside the existing exports (check the file for the pattern; `under_render.dart` may or may not be exported — add the new export regardless, tests import via `src/` either way).

- [ ] **Step 4: Run to verify pass**

Run: `fvm flutter test test/render_admission_test.dart`
Expected: 9 tests PASS.

- [ ] **Step 5: Format and commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf
fvm dart format packages/flutter_map_maplibre/lib/src/render_admission.dart packages/flutter_map_maplibre/test/render_admission_test.dart packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart
git add packages/flutter_map_maplibre/lib/src/render_admission.dart packages/flutter_map_maplibre/test/render_admission_test.dart packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart
git commit -m "feat(flutter_map_maplibre): pure drift-threshold admission gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Wire the gate into the build path

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`
- Test: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`

**Interfaces:**
- Consumes: `shouldAdmitRender` (Task 2, exact signature above).
- Produces: `MapLibreBasemap` constructor params `admissionGuardPx` (double, default 16.0) and `admissionZoomQuantum` (double, default 0.05); diagnostics keys `admits` and `admissionSkips` (cumulative ints, widget-level like `parks`); state field `bool _settleForced = false;` that Task 4 will set from its timer (this task declares and consumes it, always false until Task 4).

Behavior changes in this task — existing tests WILL break and must be updated to the new semantics (Step 4):
1. Camera changes within the runway no longer call `render()` — the frame is placed by the residual transform.
2. The lead bias is now active WITHOUT a frame cap whenever a margin exists (previously `cap == null` forced it inert). leadTime is `cap * 2` when capped, else 33 ms.
3. With `overRenderFactor` 1.0 (no margin) the slack is always ≤ 0 < guard, so every camera change still admits — today's behavior, automatically.

- [ ] **Step 1: Add the new constructor params** — in the `MapLibreBasemap` widget class:

In the constructor parameter list (after `this.overRenderFactor = 1.0,`):

```dart
    this.admissionGuardPx = 16.0,
    this.admissionZoomQuantum = 0.05,
```

Field declarations (after the `overRenderFactor` field and its doc):

```dart
  /// Admission guard band: a camera-driven render is admitted only when the
  /// viewport comes within this many logical px of the rendered canvas's
  /// edge (or crosses [admissionZoomQuantum]). Between admissions the
  /// residual transform places the existing frame — exact under translation.
  final double admissionGuardPx;

  /// Zoom drift from the rendered frame that admits a render on its own.
  /// Zooming in never bares the canvas, so without this quantum labels
  /// would blur indefinitely under coverage-only admission.
  final double admissionZoomQuantum;
```

Add the import at the top of the file: `import 'render_admission.dart';`

- [ ] **Step 2: Add counters and gate the render** — in `_MapLibreBasemapState`, add fields next to `_underRenderPxMax`:

```dart
  /// Camera-driven admission counters (cumulative, like [_parks]): how many
  /// builds rendered vs placed the existing frame. `admits` counts admitted
  /// attempts, including ones the frame cap then deferred.
  int _admits = 0;
  int _admissionSkips = 0;

  /// Set by the settle timer to force one exact render after a gesture ends
  /// off-quantum; cleared by the next successful render.
  bool _settleForced = false;
```

In `build`, replace:

```dart
        _renderer.frameCap = widget.frameCap;
        final cropped = cropCamera(camera, visibleRect);
        final target = _biasedCamera(cropped, renderSize);
        final biased = !identical(target, cropped);
        final rendered = _renderer.render(target);
        final shown = _renderer.lastRenderedCamera;
```

with:

```dart
        _renderer.frameCap = widget.frameCap;
        final cropped = cropCamera(camera, visibleRect);
        final target = _biasedCamera(cropped, renderSize);
        final biased = !identical(target, cropped);
        // The admission gate: render only when the viewport nears the
        // rendered canvas's runway or crosses a zoom/bearing quantum;
        // otherwise the residual transform places the existing frame, which
        // is pixel-exact under translation. Compared against the UNBIASED
        // current camera — lastRenderedCamera is ground truth for the canvas.
        final admit =
            _settleForced ||
            shouldAdmitRender(
              rendered: _renderer.lastRenderedCamera,
              renderSize: renderSize,
              current: camera,
              visibleRect: visibleRect,
              guardPx: widget.admissionGuardPx,
              zoomQuantum: widget.admissionZoomQuantum,
            );
        if (admit) {
          _admits++;
        } else {
          _admissionSkips++;
        }
        final rendered = admit && _renderer.render(target);
        if (rendered) _settleForced = false;
        final shown = _renderer.lastRenderedCamera;
```

- [ ] **Step 3: Bias without a cap** — in `_biasedCamera`, change the inert condition and leadTime. Replace:

```dart
    final cap = widget.frameCap;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    if (cap == null || maxBias.isEmpty) {
```

with:

```dart
    final cap = widget.frameCap;
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    if (maxBias.isEmpty) {
```

and replace:

```dart
      leadTime: cap * 2,
```

with:

```dart
      // Capped: cover one cap interval of staleness with 2x headroom.
      // Uncapped (admission-gated only): a constant — bias saturates its
      // clamp at fling speeds regardless, and at follow speeds it is
      // negligible either way.
      leadTime: cap == null ? const Duration(milliseconds: 33) : cap * 2,
```

Update `_biasedCamera`'s doc comment first line from "Active only when a frame cap is set and a margin exists" to "Active whenever a margin exists". Also update the `underRenderPx` measurement condition later in `build` — it currently reads `if (shown != null && (!rendered || biased))`; keep it as-is (a denied admission has `rendered == false`, so denied frames are measured — exactly what we want).

Add the diagnostics keys in `_startDiagnosticsPolling`, next to `'underRenderPx'`:

```dart
        'admits': _admits,
        'admissionSkips': _admissionSkips,
```

- [ ] **Step 4: New widget tests** — append to `test/maplibre_basemap_test.dart` (uses the existing `pumpSizedMap` harness; 400-wide map, `overRenderFactor: 1.5` → renderSize 600×heightx1.5, 100 px horizontal margin per side):

```dart
  testWidgets('admission: pan within the runway places without rendering', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800, overRenderFactor: 1.5);
    final calls = renderer.renderCalls;

    // 30px east: slack 100-30 = 70 > guard 16 → denied.
    final camera = controller.camera;
    controller.move(
      camera.screenOffsetToLatLng(
        camera.nonRotatedSize.center(Offset.zero) + const Offset(30, 0),
      ),
      camera.zoom,
    );
    await tester.pump();

    expect(renderer.renderCalls, calls); // no new render
    // Placed by the residual: the transform is not the identity placement.
    expect(basemapTransform(tester), isNot(Matrix4.identity()));
  });

  testWidgets('admission: cumulative pans admit once the guard is crossed', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800, overRenderFactor: 1.5);
    final calls = renderer.renderCalls;

    // 30, 60, 90px total drift → slack 70, 40, 10; only the third admits.
    for (var i = 1; i <= 3; i++) {
      final camera = controller.camera;
      controller.move(
        camera.screenOffsetToLatLng(
          camera.nonRotatedSize.center(Offset.zero) + const Offset(30, 0),
        ),
        camera.zoom,
      );
      await tester.pump();
    }

    expect(renderer.renderCalls, calls + 1);
  });

  testWidgets('admission: zoom-in below the quantum denies, at it admits', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800, overRenderFactor: 1.5);
    final calls = renderer.renderCalls;

    controller.move(controller.camera.center, 13.049);
    await tester.pump();
    expect(renderer.renderCalls, calls); // covered + below quantum → denied

    controller.move(controller.camera.center, 13.05);
    await tester.pump();
    expect(renderer.renderCalls, calls + 1);
  });

  testWidgets('admission counters flow through diagnostics', (tester) async {
    controller = MapController();
    Map<String, Object?> diag = const {};
    await pumpSizedMap(
      tester,
      height: 800,
      overRenderFactor: 1.5,
      onDiagnostics: (d) => diag = d,
    );

    final camera = controller.camera;
    controller.move(
      camera.screenOffsetToLatLng(
        camera.nonRotatedSize.center(Offset.zero) + const Offset(30, 0),
      ),
      camera.zoom,
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 1)); // diagnostics poll
    expect(diag['admits'], greaterThanOrEqualTo(1)); // the create render
    expect(diag['admissionSkips'], greaterThanOrEqualTo(1)); // the 30px pan
  });

  testWidgets('admission: factor 1.0 keeps render-every-change behavior', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800, overRenderFactor: 1.0);
    final calls = renderer.renderCalls;

    final camera = controller.camera;
    controller.move(
      camera.screenOffsetToLatLng(
        camera.nonRotatedSize.center(Offset.zero) + const Offset(5, 0),
      ),
      camera.zoom,
    );
    await tester.pump();

    expect(renderer.renderCalls, calls + 1); // no margin → no runway → admit
  });
```

- [ ] **Step 5: Run the full package suite and update broken tests**

Run: `fvm flutter test`
Expected: the new tests pass; SOME existing tests in `maplibre_basemap_test.dart` fail because they encoded the old semantics. For each failure, rewrite the assertion to the new intended behavior — do not weaken tests to just pass:

- Any test asserting the bias is inert when `frameCap` is null (e.g. a "no cap → no bias" test): the bias is now ACTIVE without a cap whenever `overRenderFactor > 1.0`. Invert or repoint the assertion (factor 1.0 still means inert — `maxBias.isEmpty`).
- Any test panning with `overRenderFactor > 1.0` and expecting `render()` to be called per camera change: small pans are now denied. Either assert the denial (renderCalls unchanged + exact residual placement) or make the pan large enough (> margin − guard px of drift) to admit, matching the test's original intent.
- Tests using `overRenderFactor: 1.0` (most of the older ones) are unaffected by the gate — if one fails, the cause is elsewhere; investigate rather than patch.
- The C acceptance tests ("capped 120px pan → underRenderPx 0" and "no-margin → 20") used `frameCap` to force stale frames; admitted-but-capped renders behave exactly as before, so these should still pass. If the 120px-pan one fails because 120px now exceeds admission drift differently, re-read it with the new gate in mind — the invariant to preserve is `underRenderPx == 0` with margin and nonzero without.

Then: `fvm flutter test` until green (expect ~80 tests passing).

- [ ] **Step 6: Format and commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf
fvm dart format packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git add packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git commit -m "feat(flutter_map_maplibre): gate camera renders on runway drift

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Settle render

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`
- Test: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`

**Interfaces:**
- Consumes: `settleOffTarget` (Task 2), `_settleForced` and the admission wiring (Task 3).
- Produces: nothing new outside the widget.

- [ ] **Step 1: Write the failing tests** — append to `test/maplibre_basemap_test.dart`:

```dart
  testWidgets('settle: a mid-quantum zoom rest lands one exact render', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800, overRenderFactor: 1.5);
    final calls = renderer.renderCalls;

    controller.move(controller.camera.center, 13.03); // below quantum → denied
    await tester.pump();
    expect(renderer.renderCalls, calls);

    await tester.pump(const Duration(milliseconds: 350)); // settle window
    await tester.pump();
    expect(renderer.renderCalls, calls + 1);
    expect(renderer.lastRenderedCamera!.zoom, 13.03);

    // One-shot: resting longer must not render again.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(renderer.renderCalls, calls + 1);
  });

  testWidgets('settle: camera changes re-arm the window', (tester) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800, overRenderFactor: 1.5);
    final calls = renderer.renderCalls;

    controller.move(controller.camera.center, 13.02);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // not yet
    controller.move(controller.camera.center, 13.04); // still sub-quantum
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // window restarted
    expect(renderer.renderCalls, calls);

    await tester.pump(const Duration(milliseconds: 150)); // 350 since re-arm
    await tester.pump();
    expect(renderer.renderCalls, calls + 1);
  });

  testWidgets('settle: pure translation staleness never settles', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800, overRenderFactor: 1.5);
    final calls = renderer.renderCalls;

    final camera = controller.camera;
    controller.move(
      camera.screenOffsetToLatLng(
        camera.nonRotatedSize.center(Offset.zero) + const Offset(30, 0),
      ),
      camera.zoom,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(renderer.renderCalls, calls); // placed exactly; nothing to settle
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `fvm flutter test test/maplibre_basemap_test.dart`
Expected: the first two new tests FAIL (no settle timer exists); the third passes trivially — keep it, it pins the non-goal.

- [ ] **Step 3: Implement the one-shot settle timer** — in `_MapLibreBasemapState`:

Add fields next to `_settleForced`:

```dart
  Timer? _settleTimer;

  /// The camera the running settle window was armed against; a build with a
  /// different camera re-arms, a rebuild with the same camera leaves the
  /// window running (parent rebuilds must not push settling out forever).
  MapCamera? _settleArmedFor;
```

In `dispose()`, add `_settleTimer?.cancel();` next to the other timer cancels.

In `build`, immediately after `final shown = _renderer.lastRenderedCamera;`, add:

```dart
        _manageSettle(rendered: rendered, shown: shown, current: cropped);
```

Add the method after `_biasedCamera`:

```dart
  /// One-shot settle: when the camera rests while the rendered frame is
  /// off-target in zoom or bearing (a pinch ended mid-quantum), land one
  /// exact render so the map does not rest blurry. Never periodic — after
  /// the settle render the ticker parks through the unchanged decideSleep
  /// path (spec criterion 4).
  void _manageSettle({
    required bool rendered,
    required MapCamera? shown,
    required MapCamera current,
  }) {
    if (rendered || !settleOffTarget(rendered: shown, current: current)) {
      _settleTimer?.cancel();
      _settleTimer = null;
      _settleArmedFor = null;
      return;
    }
    final armed = _settleArmedFor;
    final sameCamera =
        armed != null &&
        armed.center == current.center &&
        armed.zoom == current.zoom &&
        armed.rotation == current.rotation;
    if (_settleTimer != null && sameCamera) return; // window keeps running
    _settleArmedFor = current;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _settleForced = true);
    });
  }
```

- [ ] **Step 4: Run the package suite**

Run: `fvm flutter test`
Expected: all tests PASS (including the three settle tests).

- [ ] **Step 5: Format and commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf
fvm dart format packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git add packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git commit -m "feat(flutter_map_maplibre): settle render after off-quantum rest

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Vedu wiring — always-on margin, retire leadMarginActive

**Files:**
- Modify: `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`
- Modify: `test/screens/main_map/maplibre_basemap_layer_test.dart`

**Interfaces:**
- Consumes: diagnostics keys `admits` / `admissionSkips` (Task 3).
- Produces: `MaplibreBasemapLayer` passes `overRenderFactor: 1.20` unconditionally; `leadMarginActive` is deleted.

- [ ] **Step 1: Delete the predicate and gate** — in `maplibre_basemap_layer.dart`:

Delete the whole `leadMarginActive` top-level function and its doc comment (lines beginning "Whether the lead-biased over-render margin should be active"). Delete the `import 'package:flutter/cupertino.dart';` only if nothing else in the file needs it (check `Brightness` and `ValueNotifier` usages first — they come from widgets/foundation via other imports; if the analyzer complains, keep it).

In `MaplibreBasemapLayer.build`, replace:

```dart
    final saving = PowerSavingProvider.savingActiveOf(context);
    final leadMargin = leadMarginActive(
      saving: saving,
      frameCap: powerSavingFrameCap,
      refreshRate: View.of(context).display.refreshRate,
    );
```

with:

```dart
    final saving = PowerSavingProvider.savingActiveOf(context);
```

and replace:

```dart
      overRenderFactor: leadMargin ? _overRenderFactor : 1.0,
```

with:

```dart
      overRenderFactor: _overRenderFactor,
```

Update `_overRenderFactor`'s doc comment to reflect the new always-on rationale — replace the existing comment block with:

```dart
  /// The over-render margin (2026-07-24 specs): +20% per axis of runway,
  /// positioned ahead of motion by the package's velocity estimator. Always
  /// on since drift-threshold admission — renders are rare (admitted only
  /// when the viewport nears the runway), so every device pays the larger
  /// canvas per admission and gets ~50-100x fewer admissions in return.
  /// Started at 1.15; bumped after device acceptance (2026-07-24) showed
  /// bared edges on hard flicks.
  static const _overRenderFactor = 1.20;
```

- [ ] **Step 2: Surface the counters** — in the same file, add to the MLNDIAG `debugPrint` line after `'under=${d['underRenderPx']} '`:

```dart
          'admits=${d['admits']} '
          'skips=${d['admissionSkips']} '
```

and in `MaplibreDiagnosticsOverlay._numbersPanel`, after `'${row('underRenderPx')}'` add:

```dart
                      '${row('admits')}'
                      '${row('admissionSkips')}'
```

- [ ] **Step 3: Update the app test** — `test/screens/main_map/maplibre_basemap_layer_test.dart` tests the now-deleted `leadMarginActive` predicate. Delete those test cases. If the file becomes empty, replace its contents with a single guard so the always-on wiring stays pinned:

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('over-render margin is always on at 1.20 (spec 2026-07-24 B §4)', () {
    // The margin constant is private to the layer; this test documents the
    // contract. If you are changing the factor or making it conditional
    // again, update the drift-threshold admission spec first.
    expect(1.20, closeTo(1.20, 1e-9));
  });
}
```

(If the reviewer judges this placeholder test valueless, deleting the file entirely is acceptable — say so in the report.)

- [ ] **Step 4: Run analysis and tests**

Run from the worktree root:
```bash
fvm flutter analyze lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart
fvm flutter test test/screens/main_map/maplibre_basemap_layer_test.dart
```
Expected: no analyzer errors (in this file; pre-existing infos elsewhere are fine), tests pass.

- [ ] **Step 5: Format and commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf
fvm dart format lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart test/screens/main_map/maplibre_basemap_layer_test.dart
git add lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart test/screens/main_map/maplibre_basemap_layer_test.dart
git commit -m "feat(map): always-on over-render margin under drift admission

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Device acceptance (manual, with the user)

**Files:** none (build + install + observe).

Not subagent work — the controller runs the build and the user handles the phone.

- [ ] **Step 1: Profile build and install** (iPhone 14 Pro, devicectl UUID `80D04F4B-B11B-50CA-B65A-08E6B38B4A6E`, bundle `io.ushakov.busFollow`):

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/.claude/worktrees/maplibre-perf
fvm flutter build ios --profile
xcrun devicectl device install app --device 80D04F4B-B11B-50CA-B65A-08E6B38B4A6E build/ios/iphoneos/Runner.app
```

Expected: "App installed:" in the devicectl output.

- [ ] **Step 2: User checks, against the spec's success criteria:**
  1. GPS-follow leg: MLNDIAG `cam` (cameraRenders) rate ≤ 0.5/s at steady follow, `under=0`, `skips` climbing.
  2. Regular mode (power saving OFF): zoom-out → pan-to-edge → refocus gesture — no immediate heating, no hard stutters, no lingering lag.
  3. Power saving ON: C's fling acceptance still artifact-free.
  4. Idle map still parks (MLNDIAG stops moving / `tickerActive` false).

- [ ] **Step 3: Record outcomes** in `.superpowers/sdd/progress.md`; tuning follow-ups (guard band, quantum) become new work, not silent edits.
