# MapLibre Basemap Latency Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the native basemap's camera-to-texture latency from ~2–3 frames to ~1 frame + ~5 ms, make the residual transform honest, and stop rendering while idle — per `docs/superpowers/specs/2026-07-23-maplibre-latency-bundle-design.md`.

**Architecture:** The native `setCamera` handler renders synchronously before replying, so the method-channel reply *means* "this camera is in the texture" and the existing Dart stamping becomes honest with no new plumbing. The display link demotes to animation-only (tile loads, fades), gated on MapLibre's update events — which is the idle-gating fix. Dart pushes the camera during build instead of in a post-frame callback.

**Tech Stack:** Flutter (fvm), flutter_map, Objective-C over maplibre-native-ffi (`MaplibreNativeC.xcframework`), Swift plugin glue, CADisplayLink, method channels.

## Global Constraints

- All Flutter/Dart commands prefixed with `fvm` (CLAUDE.md).
- After editing/creating any `.dart` file, run `fvm dart format <paths>` (CLAUDE.md).
- All work on branch `maplibre-perf`. The working tree has **unrelated uncommitted changes** (`lib/main.dart`, `lib/providers/subscription_provider.dart`, `lib/screens/more/liquid_glass_setting.dart`, `lib/widgets/ui_restart.dart`, `test/providers/theme_default_test.dart`, `ios/Runner.xcodeproj/project.pbxproj`, `ios/Runner.app.dSYM.zip`) — never `git add` them; stage only the files named in each task.
- iOS only this round; Android is out of scope (spec §5).
- No `dart:ffi`, no camera prediction, no over-render margin (spec §5).
- Package path: `packages/flutter_map_maplibre`. Native sources: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/`.

---

### Task 1: Native — gate the display link on update events (idle gating)

The display-link tick currently renders every frame (~120×/sec while stationary — measured ~420 ms/sec of wasted GPU). Restructure `MLNBridge` so event pumping and rendering are separate methods, make `_updateAvailable` sticky until a successful render consumes it, and skip the render when MapLibre reported nothing new. Camera pushes still work after this task alone: `setCamera` → `request_repaint` → update event → next tick renders.

**Files:**
- Modify: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.m`
- Modify: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.h:23-25` (renderTick doc comment)

**Interfaces:**
- Consumes: existing `renderTick` contract (returns YES only when a frame was rendered) — `MapLibreProbe.tick()` already fires `onFrame` only on YES, so no Swift change needed.
- Produces: private helpers `- (void)pumpEvents` and `- (BOOL)renderNow` (Task 2 reuses both); diagnostics keys `linkRenders`, `skippedTicks` (Task 5 displays them). Removes ivar/key `rendersWithoutUpdate` (measurement scaffolding, superseded by `skippedTicks`).

There is no native test harness for this spike package (spec §6); the verification gate for native tasks is a clean simulator build plus the device protocol in Task 6.

- [ ] **Step 1: Restructure `MLNBridge.m`'s render path**

In the ivar block, remove `NSInteger _rendersWithoutUpdate;` and add:

```objc
  NSInteger _linkRenders;
  NSInteger _skippedTicks;
  NSInteger _cameraRenders;  // incremented by Task 2's camera path
```

Replace the entire `- (BOOL)renderTick { ... }` method (currently the event drain + render + stats in one body) with three methods:

```objc
/// Pumps the runtime and drains its event queue into flags and counters.
/// `_updateAvailable` is sticky: set here, cleared only by a successful
/// render. Making it per-tick (the old behaviour) would lose updates that
/// arrive while a render is skipped.
- (void)pumpEvents {
  mln_runtime_run_once(_runtime);

  mln_runtime_event event;
  memset(&event, 0, sizeof(event));
  event.size = (uint32_t)sizeof(event);
  bool hasEvent = false;
  do {
    hasEvent = false;
    if (mln_runtime_poll_event(_runtime, &event, &hasEvent) != MLN_STATUS_OK) break;
    if (!hasEvent) break;

    switch (event.type) {
      case MLN_RUNTIME_EVENT_MAP_RENDER_UPDATE_AVAILABLE:
        _updateAvailable = YES;
        _updatesAvailable++;
        break;

      case MLN_RUNTIME_EVENT_MAP_IDLE:
        _idleEvents++;
        break;

      case MLN_RUNTIME_EVENT_MAP_RENDER_FRAME_FINISHED:
        // needs_repaint is MapLibre asking for another frame — a fade, a
        // symbol transition, a tile still landing. It is the signal that
        // distinguishes "settled" from "mid-animation".
        if (event.payload &&
            event.payload_size >= sizeof(mln_runtime_event_render_frame)) {
          const mln_runtime_event_render_frame *frame = event.payload;
          _needsRepaint = frame->needs_repaint;
          _nativeFrames = frame->stats.frame_count;
          _drawCalls = frame->stats.draw_call_count;
        }
        break;

      case MLN_RUNTIME_EVENT_MAP_LOADING_FAILED:
        _diagnostics[@"loadingFailed"] = @YES;
        if (event.message && event.message_size > 0) {
          _diagnostics[@"loadingFailedMessage"] =
              [[NSString alloc] initWithBytes:event.message
                                       length:event.message_size
                                     encoding:NSUTF8StringEncoding];
        }
        break;

      default:
        break;
    }
  } while (hasEvent);

  _diagnostics[@"updatesAvailable"] = @(_updatesAvailable);
  _diagnostics[@"idleEvents"] = @(_idleEvents);
  _diagnostics[@"needsRepaint"] = @(_needsRepaint);
  _diagnostics[@"nativeFrames"] = @(_nativeFrames);
  _diagnostics[@"drawCalls"] = @(_drawCalls);
}

/// Renders one frame and records timing stats. Returns YES on success.
/// render_update blocks until the GPU finishes (the FFI's texture path calls
/// waitUntilCompleted), so this interval is CPU-record *plus* GPU-execute.
- (BOOL)renderNow {
  CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  mln_status status = mln_render_session_render_update(_session);
  double elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;

  _diagnostics[@"lastRenderStatus"] = @(status);
  if (status != MLN_STATUS_OK) return NO;

  _updateAvailable = NO;
  _frameCount++;
  _totalRenderMs += elapsedMs;
  if (elapsedMs > _maxRenderMs) _maxRenderMs = elapsedMs;
  // Ignore the first few frames: style load and initial tile upload are not
  // representative of steady state.
  if (_frameCount > 30) {
    _steadyFrames++;
    _steadyRenderMs += elapsedMs;
    if (elapsedMs > _steadyMaxMs) _steadyMaxMs = elapsedMs;
  }
  _diagnostics[@"frameCount"] = @(_frameCount);
  _diagnostics[@"renderMsLast"] = @(round(elapsedMs * 100) / 100);
  _diagnostics[@"renderMsMax"] = @(round(_maxRenderMs * 100) / 100);
  if (_steadyFrames > 0) {
    _diagnostics[@"renderMsAvgSteady"] =
        @(round(_steadyRenderMs / _steadyFrames * 100) / 100);
    _diagnostics[@"renderMsMaxSteady"] = @(round(_steadyMaxMs * 100) / 100);
  }
  return YES;
}

- (BOOL)renderTick {
  if (!_runtime || !_session) return NO;
  [self pumpEvents];

  // The gate. An idle map produces no update events and no repaint request,
  // so a stationary map renders zero frames instead of 120/sec. Fallback if
  // the events prove dishonest on device (spec §2): drop `_updateAvailable`
  // from the condition and gate on `_needsRepaint` alone.
  if (!_updateAvailable && !_needsRepaint) {
    _skippedTicks++;
    _diagnostics[@"skippedTicks"] = @(_skippedTicks);
    return NO;
  }

  BOOL rendered = [self renderNow];
  if (rendered) {
    _linkRenders++;
    _diagnostics[@"linkRenders"] = @(_linkRenders);
  }
  return rendered;
}
```

Also delete the now-dead `_diagnostics[@"rendersWithoutUpdate"] = ...` line if any remains (the old body set it; the new methods must not).

- [ ] **Step 2: Update the `renderTick` doc comment in `MLNBridge.h`**

Replace lines 23–25 with:

```objc
/// Pumps the run loop and renders one frame — but only when MapLibre reported
/// new content (tile arrival, fade animation, repaint request). An idle map
/// skips the render entirely. Returns YES if a frame was rendered.
- (BOOL)renderTick;
```

- [ ] **Step 3: Verify the example app compiles for the simulator**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/packages/flutter_map_maplibre/example
fvm flutter build ios --simulator --debug
```

Expected: `✓ Built .../Runner.app`. Compile errors here mean the restructure left a dangling reference (most likely `_rendersWithoutUpdate`).

- [ ] **Step 4: Commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client
git add packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.m \
        packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.h
git commit -m "perf(flutter_map_maplibre): gate display-link renders on MapLibre update events"
```

---

### Task 2: Native — render inside `setCamera`, reply after

The camera path stops waiting for the display link: `jump_to` → `request_repaint` → pump → render → reply `{"rendered": <bool>}`. The reply becomes the proof the frame landed. The probe must fire `onFrame` on this path too, or Flutter never re-samples the texture.

**Files:**
- Modify: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.h:27-33` (replace `setCameraLatitude:` declaration)
- Modify: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.m` (replace `setCameraLatitude:` implementation)
- Modify: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MapLibreProbe.swift:149-154` (`setCamera` returns Bool, fires onFrame)
- Modify: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/FlutterMapMaplibrePlugin.swift:50-59` (`setCamera` handler replies with the render outcome)

**Interfaces:**
- Consumes: `pumpEvents` / `renderNow` and the `_cameraRenders` ivar from Task 1.
- Produces: method-channel reply for `setCamera`: `{"rendered": Bool}` — Task 3's Dart client parses exactly this key. ObjC selector `setCameraAndRenderLatitude:longitude:zoom:bearing:` returning `BOOL`, imported into Swift as `setCameraAndRenderLatitude(_:longitude:zoom:bearing:)`.

- [ ] **Step 1: Replace the bridge's camera method**

In `MLNBridge.h`, replace the `setCameraLatitude:` declaration (lines 27–33) with:

```objc
/// Moves the camera and renders the frame for it before returning, so the
/// caller's reply means "this camera is in the texture" — the property the
/// Dart residual transform's bookkeeping relies on. Returns YES if the
/// render succeeded (NO means the texture still shows the previous camera).
- (BOOL)setCameraAndRenderLatitude:(double)latitude
                         longitude:(double)longitude
                              zoom:(double)zoom
                           bearing:(double)bearing;
```

In `MLNBridge.m`, replace the `setCameraLatitude:` implementation with:

```objc
- (BOOL)setCameraAndRenderLatitude:(double)latitude
                         longitude:(double)longitude
                              zoom:(double)zoom
                           bearing:(double)bearing {
  if (!_map || !_session) return NO;
  mln_camera_options camera = mln_camera_options_default();
  camera.fields = MLN_CAMERA_OPTION_CENTER | MLN_CAMERA_OPTION_ZOOM |
                  MLN_CAMERA_OPTION_BEARING;
  camera.latitude = latitude;
  camera.longitude = longitude;
  camera.zoom = zoom;
  camera.bearing = bearing;
  mln_map_jump_to(_map, &camera);
  mln_map_request_repaint(_map);

  [self pumpEvents];
  BOOL rendered = [self renderNow];
  if (rendered) {
    _cameraRenders++;
    _diagnostics[@"cameraRenders"] = @(_cameraRenders);
  }
  return rendered;
}
```

- [ ] **Step 2: Route the render outcome through the probe**

In `MapLibreProbe.swift`, replace the `setCamera` method (lines 149–154) with:

```swift
  /// Pushes the camera and renders its frame before returning — the caller's
  /// method-channel reply is the "frame landed" signal for the Dart side.
  /// Fires `onFrame` so Flutter re-samples the texture; without it the render
  /// is invisible.
  func setCamera(
    latitude: Double, longitude: Double, zoom: Double, bearing: Double
  ) -> Bool {
    guard let bridge else { return false }
    let rendered = bridge.setCameraAndRenderLatitude(
      latitude, longitude: longitude, zoom: zoom, bearing: bearing)
    if rendered {
      frameCount += 1
      onFrame?()
    }
    for (key, value) in bridge.diagnostics {
      diagnostics[key as String] = value
    }
    return rendered
  }
```

- [ ] **Step 3: Reply with the outcome from the plugin handler**

In `FlutterMapMaplibrePlugin.swift`, replace the `setCamera` block (lines 50–59) with:

```swift
    if call.method == "setCamera" {
      let args = call.arguments as? [String: Any] ?? [:]
      let rendered =
        mapProbe?.setCamera(
          latitude: args["lat"] as? Double ?? 0,
          longitude: args["lng"] as? Double ?? 0,
          zoom: args["zoom"] as? Double ?? 13,
          bearing: args["bearing"] as? Double ?? 0) ?? false
      result(["rendered": rendered])
      return
    }
```

- [ ] **Step 4: Verify the example app compiles for the simulator**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/packages/flutter_map_maplibre/example
fvm flutter build ios --simulator --debug
```

Expected: `✓ Built .../Runner.app`. A Swift error at the `bridge.setCameraAndRenderLatitude` call means the ObjC selector import name differs — check the generated interface rather than guessing.

- [ ] **Step 5: Commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client
git add packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.h \
        packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.m \
        packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MapLibreProbe.swift \
        packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/FlutterMapMaplibrePlugin.swift
git commit -m "perf(flutter_map_maplibre): render inside setCamera and reply with the outcome"
```

---

### Task 3: Dart channel — `setCamera` returns whether the frame landed

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_channel.dart:73-89`
- Test: `packages/flutter_map_maplibre/test/maplibre_channel_test.dart` (create)

**Interfaces:**
- Consumes: native reply `{"rendered": Bool}` from Task 2.
- Produces: `Future<bool> setCamera({required double lat, required double lng, required double zoom, required double bearing})` on `MapLibreChannel` — Task 4 stamps `_rendered` only when this resolves true. Old native code (or an error) yields `false`, never a throw.

- [ ] **Step 1: Write the failing tests**

Create `packages/flutter_map_maplibre/test/maplibre_channel_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_map_maplibre/src/maplibre_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MapLibreChannel();

  void mockSetCamera(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MapLibreChannel.channel, (call) async {
          return handler(call);
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MapLibreChannel.channel, null);
  });

  test('setCamera resolves true when native reports the frame rendered',
      () async {
    mockSetCamera((call) => <String, Object?>{'rendered': true});
    expect(
      await channel.setCamera(lat: 59, lng: 24, zoom: 12, bearing: 0),
      isTrue,
    );
  });

  test('setCamera resolves false when native reports a failed render',
      () async {
    mockSetCamera((call) => <String, Object?>{'rendered': false});
    expect(
      await channel.setCamera(lat: 59, lng: 24, zoom: 12, bearing: 0),
      isFalse,
    );
  });

  test('setCamera resolves false on a null reply (older native code)',
      () async {
    mockSetCamera((call) => null);
    expect(
      await channel.setCamera(lat: 59, lng: 24, zoom: 12, bearing: 0),
      isFalse,
    );
  });

  test('setCamera resolves false instead of throwing on a platform error',
      () async {
    mockSetCamera((call) => throw PlatformException(code: 'boom'));
    expect(
      await channel.setCamera(lat: 59, lng: 24, zoom: 12, bearing: 0),
      isFalse,
    );
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/packages/flutter_map_maplibre
fvm flutter test test/maplibre_channel_test.dart
```

Expected: compile error — `Future<void>` from `setCamera` cannot be used where `bool` is expected.

- [ ] **Step 3: Change `setCamera` to parse the reply**

In `maplibre_channel.dart`, replace the `setCamera` method (lines 73–89) with:

```dart
  /// Pushes the camera to the native renderer, which renders the frame for it
  /// *before* replying — a `true` result means the texture now shows exactly
  /// this camera. That property is what keeps the residual transform honest.
  ///
  /// `false` means the texture is unchanged (failed render, platform error,
  /// or older native code); callers must not treat the camera as rendered.
  ///
  /// [zoom] and [bearing] are in *MapLibre's* units, not `flutter_map`'s — see
  /// `camera_conventions.dart`. They go straight to `mln_map_jump_to`.
  Future<bool> setCamera({
    required double lat,
    required double lng,
    required double zoom,
    required double bearing,
  }) async {
    try {
      final response = await channel
          .invokeMapMethod<String, Object?>('setCamera', <String, Object?>{
            'lat': lat,
            'lng': lng,
            'zoom': zoom,
            'bearing': bearing,
          });
      return response?['rendered'] as bool? ?? false;
    } on PlatformException {
      // A dropped camera push costs one stale frame, nothing more.
      return false;
    }
  }
```

- [ ] **Step 4: Format and run the tests**

```bash
fvm dart format lib/src/maplibre_channel.dart test/maplibre_channel_test.dart
fvm flutter test test/maplibre_channel_test.dart
```

Expected: all 4 tests PASS. (`maplibre_basemap.dart` still compiles: it currently only uses the future's completion, not its value.)

- [ ] **Step 5: Commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client
git add packages/flutter_map_maplibre/lib/src/maplibre_channel.dart \
        packages/flutter_map_maplibre/test/maplibre_channel_test.dart
git commit -m "feat(flutter_map_maplibre): setCamera reports whether the frame landed"
```

---

### Task 4: Dart widget — build-time push, honest stamping, pushToTextureMs

Three changes to `_MapLibreBasemapState`: push during build instead of post-frame (removes ~1 frame of latency), stamp `_rendered` only when the reply says the frame landed (honesty), and record a rolling push-to-texture latency for diagnostics.

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`
- Test: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart` (create)

**Interfaces:**
- Consumes: `Future<bool> setCamera(...)` from Task 3.
- Produces: diagnostics key `pushToTextureMs` (double, EMA, 2 decimals) merged into the map passed to `onDiagnostics` — Task 5 displays it. Widget behaviour: `_rendered` advances only on `rendered == true`.

- [ ] **Step 1: Write the failing widget tests**

Create `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:flutter_map_maplibre/src/maplibre_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Drives MapLibreBasemap inside a real FlutterMap with the method channel
/// mocked, so the camera → push → reply → stamp cycle runs under test control.
class _ChannelHarness {
  final setCameraCalls = <Map<Object?, Object?>>[];
  final _replies = <Completer<Map<String, Object?>>>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MapLibreChannel.channel, (call) async {
          switch (call.method) {
            case 'runMap':
              return <String, Object?>{
                'ok': true,
                'textureId': 1,
                'diagnostics': <String, Object?>{},
              };
            case 'setCamera':
              setCameraCalls.add(call.arguments as Map<Object?, Object?>);
              final completer = Completer<Map<String, Object?>>();
              _replies.add(completer);
              return completer.future;
            case 'mapDiagnostics':
              return <String, Object?>{'frameCount': 1};
            default:
              return null;
          }
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MapLibreChannel.channel, null);
  }

  int get pendingReplies => _replies.where((c) => !c.isCompleted).length;

  void replyNext({required bool rendered}) {
    _replies
        .firstWhere((c) => !c.isCompleted)
        .complete(<String, Object?>{'rendered': rendered});
  }
}

void main() {
  final harness = _ChannelHarness();

  setUp(harness.install);
  tearDown(harness.uninstall);

  late MapController controller;

  Future<void> pumpMap(
    WidgetTester tester, {
    ValueChanged<Map<String, Object?>>? onDiagnostics,
  }) async {
    controller = MapController();
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
              styleUrl: 'https://example.com/style.json',
              onDiagnostics: onDiagnostics,
            ),
          ],
        ),
      ),
    );
    // Frame 1 schedules _create post-frame; pump until the texture exists and
    // the first camera push has gone out.
    await tester.pump();
    await tester.pump();
    expect(harness.setCameraCalls, isNotEmpty,
        reason: 'initial camera push should have been sent');
  }

  Matrix4 basemapTransform(WidgetTester tester) {
    final transform = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(MapLibreBasemap),
            matching: find.byType(Transform),
          )
          .first,
    );
    return transform.transform;
  }

  bool isIdentity(Matrix4 m) => m.isIdentity();

  testWidgets('stamps _rendered only when the reply arrives', (tester) async {
    await pumpMap(tester);

    // Initial push in flight; before any reply the widget treats the texture
    // as showing the current camera (renderedOrCurrent fallback) — identity.
    expect(isIdentity(basemapTransform(tester)), isTrue);

    harness.replyNext(rendered: true);
    await tester.pump();
    expect(isIdentity(basemapTransform(tester)), isTrue);

    // Move: current camera leaves the rendered camera behind. The transform
    // must become non-identity (residual correction) until the reply lands.
    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(isIdentity(basemapTransform(tester)), isFalse);

    harness.replyNext(rendered: true);
    await tester.pump();
    expect(isIdentity(basemapTransform(tester)), isTrue,
        reason: 'reply == frame landed, so the transform settles');
  });

  testWidgets('a failed render does not advance _rendered', (tester) async {
    await pumpMap(tester);
    harness.replyNext(rendered: true);
    await tester.pump();

    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(isIdentity(basemapTransform(tester)), isFalse);

    harness.replyNext(rendered: false);
    await tester.pump();
    expect(isIdentity(basemapTransform(tester)), isFalse,
        reason: 'texture unchanged, so the correction must persist');
  });

  testWidgets('coalesces pushes while one is in flight', (tester) async {
    await pumpMap(tester);
    harness.replyNext(rendered: true);
    await tester.pump();
    final callsBefore = harness.setCameraCalls.length;

    // Three camera changes while no push can go out (reply held).
    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    controller.move(const LatLng(59.46, 24.81), 13);
    await tester.pump();
    controller.move(const LatLng(59.47, 24.82), 13);
    await tester.pump();

    expect(harness.setCameraCalls.length, callsBefore + 1,
        reason: 'only the first change starts a push; the rest coalesce');

    harness.replyNext(rendered: true);
    await tester.pump();

    expect(harness.setCameraCalls.length, callsBefore + 2,
        reason: 'completion sends exactly one push for the newest camera');
    final last = harness.setCameraCalls.last;
    expect(last['lat'], closeTo(59.47, 1e-9));
    expect(last['lng'], closeTo(24.82, 1e-9));
  });

  testWidgets('reports pushToTextureMs in diagnostics', (tester) async {
    Map<String, Object?>? latest;
    await pumpMap(tester, onDiagnostics: (d) => latest = d);
    harness.replyNext(rendered: true);
    await tester.pump();

    // The diagnostics poll runs on a 1s timer.
    await tester.pump(const Duration(seconds: 1));
    expect(latest, isNotNull);
    expect(latest!['pushToTextureMs'], isA<double>());
    // Native keys pass through untouched.
    expect(latest!['frameCount'], 1);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client/packages/flutter_map_maplibre
fvm flutter test test/maplibre_basemap_test.dart
```

Expected: 'a failed render does not advance _rendered' FAILS (current code stamps on `whenComplete`, ignoring the outcome). 'coalesces' and 'stamps' may pass or fail depending on post-frame timing; 'pushToTextureMs' FAILS (key absent). If *everything* passes, the tests are not exercising the widget — stop and fix the harness before touching the implementation.

- [ ] **Step 3: Implement the three changes in `maplibre_basemap.dart`**

(a) Add two fields to `_MapLibreBasemapState` next to `_pushInFlight`:

```dart
  /// Exponential moving average of _pushCamera call → reply, in ms — the
  /// pipeline latency the residual transform has to absorb, as a number.
  double? _pushToTextureMs;
```

(b) Replace the `_pushCamera` method with:

```dart
  /// Pushes [camera] to the renderer, at most one call in flight.
  ///
  /// The early return on an unchanged camera is what makes the widget settle.
  /// Completing a push calls `setState`, which rebuilds, which pushes again —
  /// so without a stopping condition an idle map drives a permanent loop of
  /// channel round-trips.
  ///
  /// The native side renders the frame *before* replying, so a `true` result
  /// means the texture now shows exactly [camera] — stamping `_rendered` here
  /// is honest. On `false` the texture is unchanged and `_rendered` must stay
  /// put: the transform then keeps correcting relative to what is actually
  /// on screen, and the next camera change (or the animation-driven display
  /// link) repairs the content.
  void _pushCamera(MapCamera camera) {
    if (_textureId == null) return;
    if (_sameCamera(_rendered, camera)) return;

    // Mid-gesture the camera moves again before the previous push resolves.
    // Hold the newest and send it on completion: dropping it would leave the
    // texture rendered for a slightly stale camera once the gesture ends, and
    // nothing would rebuild to correct it.
    if (_pushInFlight) {
      _pendingCamera = camera;
      return;
    }

    _pushInFlight = true;
    final pushClock = Stopwatch()..start();
    _channel
        .setCamera(
          lat: camera.center.latitude,
          lng: camera.center.longitude,
          zoom: maplibreZoom(camera.zoom),
          bearing: maplibreBearing(camera.rotation),
        )
        .then((rendered) {
          _pushInFlight = false;
          if (!mounted) return;

          if (rendered) {
            final ms = pushClock.elapsedMicroseconds / 1000.0;
            _pushToTextureMs = _pushToTextureMs == null
                ? ms
                : _pushToTextureMs! * 0.8 + ms * 0.2;
            setState(() => _rendered = camera);
          }

          final pending = _pendingCamera;
          _pendingCamera = null;
          if (pending != null && !_sameCamera(camera, pending)) {
            _pushCamera(pending);
          }
        });
  }
```

(c) In `build`, replace the post-frame push:

```dart
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pushCamera(camera);
        });
```

with a direct call plus its rationale:

```dart
        // Push during build, not post-frame: flutter_map rebuilds this widget
        // in the same frame the gesture moves the camera, so pushing here
        // starts the native render a full frame earlier. The send is
        // fire-and-forget async — its setState happens on reply, never
        // during this build.
        _pushCamera(camera);
```

(d) In `_startDiagnosticsPolling`, merge the Dart-side metric into the callback payload — replace the timer body:

```dart
    _diagnosticsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final diagnostics = await _channel.diagnostics();
      if (!mounted) return;
      widget.onDiagnostics?.call(<String, Object?>{
        ...diagnostics,
        if (_pushToTextureMs != null)
          'pushToTextureMs':
              double.parse(_pushToTextureMs!.toStringAsFixed(2)),
      });
    });
```

Also update the class doc comment's stale claim: in the `MapLibreBasemap` doc block, replace "which is always at least a frame behind; that gap is closed every Flutter frame by [residualTransform]" with "which renders each pushed camera before acknowledging it; the remaining sub-frame gap is closed every Flutter frame by [residualTransform]". And update `_rendered`'s field comment from "treated as the camera the current texture contents were rendered with. True within a frame or two" to "stamped only when the native side confirms the frame for it is in the texture."

- [ ] **Step 4: Format and run the full package test suite**

```bash
fvm dart format lib/src/maplibre_basemap.dart test/maplibre_basemap_test.dart
fvm flutter test
```

Expected: all tests PASS, including the pre-existing `camera_conventions_test.dart`, `residual_transform_test.dart`, `probe_test.dart`.

- [ ] **Step 5: Commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client
git add packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart \
        packages/flutter_map_maplibre/test/maplibre_basemap_test.dart
git commit -m "perf(flutter_map_maplibre): push camera at build time and stamp only landed frames"
```

---

### Task 5: Vedu — surface the new numbers in the overlay and MLNDIAG line

**Files:**
- Modify: `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`

**Interfaces:**
- Consumes: diagnostics keys `pushToTextureMs` (Task 4), `cameraRenders`, `linkRenders`, `skippedTicks` (Tasks 1–2). The key `rendersWithoutUpdate` no longer exists.

- [ ] **Step 1: Update the MLNDIAG log line**

In `MaplibreBasemapLayer.build`'s `onDiagnostics` callback, replace the `debugPrint` with:

```dart
        debugPrint(
          'MLNDIAG '
          'avg=${d['renderMsAvgSteady']} '
          'max=${d['renderMsMaxSteady']} '
          'last=${d['renderMsLast']} '
          'push=${d['pushToTextureMs']} '
          'frames=${d['frameCount']} '
          'cam=${d['cameraRenders']} '
          'link=${d['linkRenders']} '
          'skip=${d['skippedTicks']} '
          'idle=${d['idleEvents']} '
          'repaint=${d['needsRepaint']} '
          'draws=${d['drawCalls']}',
        );
```

- [ ] **Step 2: Update the overlay rows**

In `MaplibreDiagnosticsOverlay`, replace the `row('rendersWithoutUpdate')` line in the `text` expression with:

```dart
                        '${row('pushToTextureMs')}'
                        '${row('cameraRenders')}'
                        '${row('linkRenders')}'
                        '${row('skippedTicks')}'
```

(keeping the surrounding rows as they are).

- [ ] **Step 3: Format, analyze, run Vedu's tests**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client
fvm dart format lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart
fvm flutter analyze lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart
```

Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart
git commit -m "feat(map): show pipeline latency and render cadence in MapLibre diagnostics"
```

---

### Task 6: Device validation (manual protocol, iPhone 16 Pro)

This is the spec's §4 protocol — it needs the physical device and the user driving the phone, with the MLNDIAG stream watched from the laptop. Claude runs the build and monitors; the user gestures.

**Files:**
- Modify: `docs/superpowers/specs/2026-07-23-maplibre-latency-bundle-design.md` (append a "## Device validation results" section with the measured numbers)

- [ ] **Step 1: Build and run on the device, streaming MLNDIAG**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client
fvm flutter run --profile -d 00008140-00084C990EA3001C
```

(Run in background; grep the output for `MLNDIAG`. The debug menu toggle "Native MapLibre basemap" must be on. Note: `ios/Runner.xcodeproj/project.pbxproj` still carries the temporary automatic-dev-signing flip from the previous session — needed for sideloading; do not commit it, and revert before any TestFlight deploy.)

- [ ] **Step 2: Idle check**

Leave the map untouched for ~30 s after tiles settle. Success: `link=` and `cam=` stop climbing (≤ ~1/sec), `skip=` climbs by ~120/sec, tiles and label fades still complete (no frozen half-loaded map). If the map freezes mid-load: the update events are dishonest — apply the spec's fallback (gate on `needsRepaint` only) and re-test before proceeding.

- [ ] **Step 3: Motion check**

Fling and pinch hard. Success: `push=` reports a stable single-digit ms value; `cam=` climbs at roughly the gesture frame rate; marker-vs-basemap slip visibly reduced compared to the pre-bundle build.

- [ ] **Step 4: The falsifiable test — power-saving mode**

Enable Low Power Mode (60 Hz) and repeat the fling. Prediction from the spec: the slip should now look close to normal mode, because the bookkeeping error that 60 Hz doubled is gone. If power-saving is still dramatically worse, the honest-staleness diagnosis was wrong — stop and re-investigate before any further tuning.

- [ ] **Step 5: Record results and commit**

Append a `## Device validation results (2026-07-XX)` section to the spec with: idle `skip`/`link` rates, motion `push=` average, `cam=` rate, and the subjective slip verdicts for normal and low-power modes.

```bash
git add docs/superpowers/specs/2026-07-23-maplibre-latency-bundle-design.md
git commit -m "docs(flutter_map_maplibre): record latency-bundle device validation results"
```

---

## Self-Review

- **Spec coverage:** §1 handler render → Task 2; §2 idle gating + fallback → Task 1 (fallback documented in the gate comment and Task 6 Step 2); §3 build-time push + honest stamping → Task 4; §4 diagnostics + device protocol → Tasks 4 (metric), 5 (display), 6 (protocol, including the falsifiable low-power test); §5 boundaries → Global Constraints; §6 testing → Tasks 3–4 (mocked-channel tests), Task 6 (device). No gaps.
- **Placeholder scan:** no TBDs; every code step shows the code; commands carry expected outputs.
- **Type consistency:** `setCameraAndRenderLatitude:longitude:zoom:bearing:` (ObjC) ↔ `setCameraAndRenderLatitude(_:longitude:zoom:bearing:)` (Swift, Task 2 Steps 1–2); reply key `rendered` (Task 2 Step 3 ↔ Task 3 Step 3 ↔ Task 4 harness); diagnostics keys `pushToTextureMs`/`cameraRenders`/`linkRenders`/`skippedTicks` consistent across Tasks 1, 2, 4, 5.
