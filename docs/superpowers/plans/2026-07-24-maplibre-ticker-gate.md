# MapLibre Ticker Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Park the `MapLibreBasemap` widget's Flutter `Ticker` when MapLibre reports the map idle, so the app stops rendering ~120 wasted frames/second at rest (spec: `docs/superpowers/specs/2026-07-24-maplibre-ticker-gate-design.md`).

**Architecture:** The FFI renderer latches MapLibre's `MAP_IDLE` runtime event (cleared on every camera jump and style change) and exposes `canSleep`; the widget stops its Ticker when `canSleep` is true and restarts it when a camera jump, style swap, or the 5-second insurance pump (which drains the native event queue without rendering) creates work. All logic is Dart; the park decision is a pure function.

**Tech Stack:** Flutter (fvm), dart:ffi (existing bindings only — no binding changes), flutter_test with the package's existing fake-renderer harness.

## Global Constraints

- All work in the worktree `<host app worktree>`, branch `ticker-gate`. Every shell command must `cd` there explicitly first (the shell cwd resets between commands).
- Changes ONLY under `packages/flutter_map_maplibre/` (spec: "Scope: packages/flutter_map_maplibre only"). No changes to native code, vendored headers, or generated bindings (`lib/src/ffi/maplibre_bindings.dart`); `lib/src/ffi/ffi_basemap_renderer.dart` is hand-written Dart and IS in scope.
- NEVER commit: `ios/Runner.xcodeproj/project.pbxproj`, `ios/Podfile.lock`, `packages/flutter_map_maplibre/example/ios/Podfile.lock`, `ios/Runner.app.dSYM.zip`, `.env`. These are dirty in the worktree by design — stage files explicitly by path, never `git add -A`.
- All Flutter/Dart commands prefixed with `fvm`. After editing any `.dart` file, run `fvm dart format <every touched file>` before committing.
- Insurance pump period is exactly `Duration(seconds: 5)`; diagnostics keys are exactly `tickerActive` (bool) and `parks` (int) — the soak report reads these names from the JSONL.
- Run the package test suite from the package directory: `cd <worktree>/packages/flutter_map_maplibre && fvm flutter test`.

---

### Task 1: Renderer sleep gate — `decideSleep`, `MAP_IDLE` latch, `canSleep`, `pumpWork`

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/basemap_renderer.dart`
- Modify: `packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart`
- Modify: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart` (fake renderer must implement the widened interface so the suite keeps compiling)
- Test: `packages/flutter_map_maplibre/test/tick_gate_test.dart`

**Interfaces:**
- Consumes: existing `decideTick`, `BasemapRenderer`, `FfiBasemapRenderer._pumpEvents`, `_eventMapIdle`.
- Produces (Task 2 relies on these exact names):
  - `bool decideSleep({required bool idleSinceLastJump, required bool updateAvailable, required bool needsRepaint})` — top-level in `basemap_renderer.dart`.
  - `bool get canSleep` on `BasemapRenderer` (FFI impl: `isReady && decideSleep(...)`).
  - `bool pumpWork()` on `BasemapRenderer` — drains events without rendering, returns whether work is pending.
  - Fake-renderer fields in `maplibre_basemap_test.dart`: `bool canSleepValue`, `bool pumpWorkResult`, `int pumpWorkCalls`.

- [ ] **Step 1: Write the failing tests for `decideSleep`**

Append to `packages/flutter_map_maplibre/test/tick_gate_test.dart`, inside `main()` after the existing tests:

```dart
  test('sleep: idle since the last jump with clear flags may park', () {
    expect(
      decideSleep(
        idleSinceLastJump: true,
        updateAvailable: false,
        needsRepaint: false,
      ),
      isTrue,
    );
  });

  test('sleep: clear flags alone are not enough — tiles for a new camera '
      'can be loading with no repaint requested', () {
    expect(
      decideSleep(
        idleSinceLastJump: false,
        updateAvailable: false,
        needsRepaint: false,
      ),
      isFalse,
    );
  });

  test('sleep: a pending update vetoes the park even after idle', () {
    expect(
      decideSleep(
        idleSinceLastJump: true,
        updateAvailable: true,
        needsRepaint: false,
      ),
      isFalse,
    );
  });

  test('sleep: a repaint request vetoes the park even after idle', () {
    expect(
      decideSleep(
        idleSinceLastJump: true,
        updateAvailable: false,
        needsRepaint: true,
      ),
      isFalse,
    );
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd <package root> && fvm flutter test test/tick_gate_test.dart`
Expected: COMPILE ERROR — `decideSleep` is not defined.

- [ ] **Step 3: Add `decideSleep` and the interface members to `basemap_renderer.dart`**

In `packages/flutter_map_maplibre/lib/src/basemap_renderer.dart`, add after the `decideTick` function:

```dart
/// Whether the ticker may park. Idle must have been observed since the last
/// camera jump: flags alone can look clear while tiles for a new camera are
/// still loading (partial render with no repaint requested) — MAP_IDLE is
/// the renderer's own "that frame was final" and only it opens the gate.
bool decideSleep({
  required bool idleSinceLastJump,
  required bool updateAvailable,
  required bool needsRepaint,
}) => idleSinceLastJump && !updateAvailable && !needsRepaint;
```

In the `BasemapRenderer` abstract class, add after the `tick()` declaration:

```dart
  /// True when the map has reported MAP_IDLE since the last camera jump and
  /// no update or repaint is pending: the widget's ticker may stop. A camera
  /// jump, [setStyle], or [pumpWork] finding work wakes it back up.
  bool get canSleep;

  /// Insurance-pump hook: drains the runtime event queue WITHOUT rendering
  /// and reports whether work appeared (update available or repaint needed).
  /// Owner-thread tasks (tile expiry refreshes) only progress when the queue
  /// is pumped, so a parked widget calls this on a slow timer.
  bool pumpWork();
```

- [ ] **Step 4: Implement the latch in `ffi_basemap_renderer.dart`**

Five edits to `packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart`:

(a) Add the field next to the existing flags (after `bool _renderedSinceLastTick = false;`):

```dart
  bool _idleSinceLastJump = false;
```

(b) Add the interface members after the `lastRenderedCamera` getter:

```dart
  @override
  bool get canSleep =>
      isReady &&
      decideSleep(
        idleSinceLastJump: _idleSinceLastJump,
        updateAvailable: _updateAvailable,
        needsRepaint: _needsRepaint,
      );

  @override
  bool pumpWork() {
    if (!isReady) return false;
    _pumpEvents();
    return _updateAvailable || _needsRepaint;
  }
```

(c) In `_pumpEvents`, set the latch on the idle event. Replace:

```dart
        case _eventMapIdle:
          _idleEvents++;
```

with:

```dart
        case _eventMapIdle:
          _idleEvents++;
          _idleSinceLastJump = true;
```

(d) In `render()`, move the event drain BEFORE the jump and clear the latch at the jump. Replace the block from `_camera.ref = _b.mln_camera_options_default();` through `_pumpEvents();` with:

```dart
    // Drain stale events BEFORE the jump: a MAP_IDLE emitted for the old
    // camera must not survive past it, or the sleep gate would read "idle"
    // while the new camera's tiles are still loading and park with work in
    // flight.
    _pumpEvents();

    _camera.ref = _b.mln_camera_options_default();
    _camera.ref.fields =
        _cameraOptionCenter | _cameraOptionZoom | _cameraOptionBearing;
    _camera.ref.latitude = camera.center.latitude;
    _camera.ref.longitude = camera.center.longitude;
    _camera.ref.zoom = maplibreZoom(camera.zoom);
    _camera.ref.bearing = maplibreBearing(camera.rotation);
    _b.mln_map_jump_to(_map, _camera);
    _b.mln_map_request_repaint(_map);
    _jumpedCamera = camera;
    _idleSinceLastJump = false;
```

(so the line order in `render()` becomes: ready check → same-camera check → `_pumpEvents()` → camera setup/jump/latch clear → `Stopwatch` → `_renderAndPresent()` → bookkeeping, all remaining lines unchanged).

(e) `setStyle` requests a repaint whose events arrive later — the latch must not claim idle across a style swap. Add `_idleSinceLastJump = false;` after the `_b.mln_map_request_repaint(_map);` line in `setStyle`, and add `_idleSinceLastJump = false;` in `dispose()` next to `_lastRenderedCamera = null;`.

- [ ] **Step 5: Widen the fake renderer so the widget suite compiles**

In `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`, inside `_FakeRenderer`, add fields after `String? styleUrl;`:

```dart
  bool canSleepValue = false;
  bool pumpWorkResult = false;
  int pumpWorkCalls = 0;
```

Add the members after the `lastRenderedCamera` getter:

```dart
  @override
  bool get canSleep => canSleepValue;

  @override
  bool pumpWork() {
    pumpWorkCalls++;
    if (pumpWorkResult) canSleepValue = false; // work found → no longer idle
    return pumpWorkResult;
  }
```

Replace the fake's `render` with (a jump clears the idle latch, mirroring the FFI implementation):

```dart
  @override
  bool render(MapCamera camera) {
    renderCalls++;
    final jumped =
        _last == null ||
        _last!.center != camera.center ||
        _last!.zoom != camera.zoom;
    if (jumped) canSleepValue = false;
    if (!renderResult) return false;
    _last = camera;
    return true;
  }
```

Replace the fake's `setStyle` with (the real one clears the latch):

```dart
  @override
  void setStyle(String styleUrl) {
    this.styleUrl = styleUrl;
    canSleepValue = false;
  }
```

- [ ] **Step 6: Run the package suite**

Run: `cd <package root> && fvm flutter test`
Expected: ALL PASS (the four new sleep tests plus every existing test).

- [ ] **Step 7: Format and analyze**

Run: `cd <host app worktree> && fvm dart format packages/flutter_map_maplibre/lib/src/basemap_renderer.dart packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart packages/flutter_map_maplibre/test/tick_gate_test.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart && cd packages/flutter_map_maplibre && fvm flutter analyze`
Expected: no issues.

- [ ] **Step 8: Commit**

```bash
cd <host app worktree> && \
git add packages/flutter_map_maplibre/lib/src/basemap_renderer.dart \
        packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart \
        packages/flutter_map_maplibre/test/tick_gate_test.dart \
        packages/flutter_map_maplibre/test/maplibre_basemap_test.dart && \
git commit -m "feat(flutter_map_maplibre): renderer sleep gate — MAP_IDLE latch, canSleep, pumpWork"
```

---

### Task 2: Widget park/unpark, insurance pump, diagnostics

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`
- Test: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`

**Interfaces:**
- Consumes (from Task 1): `BasemapRenderer.canSleep` (bool getter), `BasemapRenderer.pumpWork()` (returns bool: work pending), fake fields `canSleepValue` / `pumpWorkResult` / `pumpWorkCalls`; fake `render()` clears `canSleepValue` on a camera jump, fake `setStyle` clears it too.
- Produces: diagnostics map keys `tickerActive` (bool) and `parks` (int) merged into every `onDiagnostics` callback — the soak JSONL and overlay read these exact names.

- [ ] **Step 1: Write the failing widget tests**

Append inside `main()` of `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`:

```dart
  testWidgets('ticker parks when the renderer reports canSleep', (
    tester,
  ) async {
    await pumpMap(tester);
    await tester.pump();
    expect(renderer.tickCalls, greaterThan(0));

    renderer.canSleepValue = true;
    await tester.pump(); // the tick that observes canSleep and parks
    final ticksAtPark = renderer.tickCalls;
    await tester.pump();
    await tester.pump();
    expect(renderer.tickCalls, ticksAtPark, reason: 'parked: no more ticks');
  });

  testWidgets('a camera move wakes the parked ticker', (tester) async {
    await pumpMap(tester);
    renderer.canSleepValue = true;
    await tester.pump();
    final ticksAtPark = renderer.tickCalls;
    await tester.pump();
    expect(renderer.tickCalls, ticksAtPark);

    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump(); // build renders the jump → latch clears → wake
    await tester.pump(); // the restarted ticker ticks
    expect(renderer.tickCalls, greaterThan(ticksAtPark));
  });

  testWidgets('insurance pump wakes the parked ticker when work appears', (
    tester,
  ) async {
    await pumpMap(tester);
    renderer.canSleepValue = true;
    await tester.pump();
    final ticksAtPark = renderer.tickCalls;

    // Parked: the 5s pump polls and finds nothing; still parked.
    await tester.pump(const Duration(seconds: 5));
    expect(renderer.pumpWorkCalls, 1);
    expect(renderer.tickCalls, ticksAtPark);

    // Work appears (a tile expired, say): the pump wakes the ticker.
    renderer.pumpWorkResult = true;
    await tester.pump(const Duration(seconds: 5));
    expect(renderer.pumpWorkCalls, 2);
    await tester.pump();
    expect(renderer.tickCalls, greaterThan(ticksAtPark));
  });

  testWidgets('a style change wakes the parked ticker', (tester) async {
    await pumpMap(tester);
    renderer.canSleepValue = true;
    await tester.pump();
    final ticksAtPark = renderer.tickCalls;
    await tester.pump();
    expect(renderer.tickCalls, ticksAtPark);

    await tester.pumpWidget(
      MaterialApp(
        home: FlutterMap(
          mapController: controller,
          options: const MapOptions(
            initialCenter: LatLng(59.437, 24.7536),
            initialZoom: 13,
          ),
          children: [
            MapLibreBasemap(
              styleUrl: 'https://example.com/dark.json',
              rendererFactory: () => renderer,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(renderer.tickCalls, greaterThan(ticksAtPark));
  });

  testWidgets('diagnostics carry tickerActive and parks', (tester) async {
    Map<String, Object?>? latest;
    await pumpMap(tester, onDiagnostics: (d) => latest = d);
    await tester.pump(const Duration(seconds: 1));
    expect(latest!['tickerActive'], isTrue);
    expect(latest!['parks'], 0);

    renderer.canSleepValue = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(latest!['tickerActive'], isFalse);
    expect(latest!['parks'], 1);
  });
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `cd <package root> && fvm flutter test test/maplibre_basemap_test.dart`
Expected: the five new tests FAIL (ticker never parks, `pumpWorkCalls` stays 0, diagnostics lack the new keys); all pre-existing tests still pass.

- [ ] **Step 3: Implement the gate in `maplibre_basemap.dart`**

Six edits to `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`:

(a) Add fields next to `Ticker? _ticker;`:

```dart
  Timer? _insurancePump;
  int _parks = 0;
```

(b) Replace `_onTick` and its doc comment with:

```dart
  /// Ticker: lets the map animate itself (tile fades, transitions) between
  /// camera changes. When a tick presents a new frame the widget rebuilds so
  /// the transform stays true to the new content. When the renderer reports
  /// the map idle the ticker parks — an active Ticker forces the whole app
  /// pipeline to run at display rate even when every tick is a no-op.
  void _onTick(Duration _) {
    if (_renderer.tick() && mounted) setState(() {});
    if (_renderer.canSleep) _park();
  }

  /// Stop requesting frames and fall back to the slow insurance pump. The
  /// pump drives owner-thread tasks (tile expiry refreshes) that would
  /// otherwise freeze while parked, and wakes the ticker if work appears.
  void _park() {
    final ticker = _ticker;
    if (ticker == null || !ticker.isActive) return;
    ticker.stop();
    _parks++;
    _insurancePump ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _renderer.pumpWork()) _wake();
    });
  }

  /// Idempotent: restart the ticker and drop the insurance pump.
  void _wake() {
    _insurancePump?.cancel();
    _insurancePump = null;
    final ticker = _ticker;
    if (ticker != null && !ticker.isActive) ticker.start();
  }
```

(c) In `didUpdateWidget`, wake on a style swap:

```dart
    if (oldWidget.styleUrl != widget.styleUrl) {
      _renderer.setStyle(widget.styleUrl);
      _wake();
    }
```

(d) In `dispose()`, add `_insurancePump?.cancel();` next to `_diagnosticsTimer?.cancel();`.

(e) In `_create`, replace `_ticker ??= createTicker(_onTick)..start();` with:

```dart
    _ticker ??= createTicker(_onTick);
    _wake();
```

(f) In `_startDiagnosticsPolling`, merge the gate state into the callback — replace the timer body with:

```dart
    _diagnosticsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      widget.onDiagnostics?.call(<String, Object?>{
        ..._renderer.diagnostics(),
        'tickerActive': _ticker?.isActive ?? false,
        'parks': _parks,
      });
    });
```

(g) In `build`, after the two lines

```dart
        final rendered = _renderer.render(cropCamera(camera, visibleRect));
        final shown = _renderer.lastRenderedCamera;
```

insert:

```dart
        // A camera jump cleared the renderer's idle latch; make sure the
        // ticker runs to carry the aftermath (tile loads, fades). A
        // same-camera rebuild leaves a parked ticker parked.
        if (!_renderer.canSleep) _wake();
```

- [ ] **Step 4: Run the package suite**

Run: `cd <package root> && fvm flutter test`
Expected: ALL PASS.

- [ ] **Step 5: Format and analyze**

Run: `cd <host app worktree> && fvm dart format packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart packages/flutter_map_maplibre/test/maplibre_basemap_test.dart && cd packages/flutter_map_maplibre && fvm flutter analyze`
Expected: no issues.

- [ ] **Step 6: Commit**

```bash
cd <host app worktree> && \
git add packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart \
        packages/flutter_map_maplibre/test/maplibre_basemap_test.dart && \
git commit -m "feat(flutter_map_maplibre): park the basemap ticker when the map idles"
```

---

### Task 3: On-device acceptance leg (human-in-loop — do NOT dispatch to a subagent)

No code. The acceptance test from the spec, run with the user's iPhone:

- [ ] **Step 1: Build and install the profile app on the device** (requires the locally-flipped `project.pbxproj`; restore from `scratchpad/device-flip/` if Xcode mangled it).

- [ ] **Step 2: Run a 15-minute maplibre soak leg** — debug menu → Power soak controls → maplibre renderer on → `15m` chip (script v2 pins the start camera automatically). Device unplugged.

- [ ] **Step 3: Retrieve the JSONL** (share chip → AirDrop to ~/Downloads) and compare against the 2026-07-23 maplibre leg:

```bash
cd <host app worktree> && \
fvm dart run tools/soak_report.dart ~/Downloads/<new-run>.jsonl /Users/sushakov/Downloads/soak-20260723-231407.jsonl -o <scratchpad>/ticker-gate-ab.html
```

- [ ] **Step 4: Verify success criteria** (spec "Testing"): settle-phase fps ≤ ~20 (was 119.9), thermal stays 0–1 (was 2), `parks` > 0 in the JSONL, interaction phases still render (cameraRenders present, no blank map observed during the run).
