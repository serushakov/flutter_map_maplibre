import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:flutter_map_maplibre/src/maplibre_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Fake renderer: the widget's whole FFI world, scripted per test.
class _FakeRenderer implements BasemapRenderer {
  bool renderResult = true;
  bool tickResult = false;
  int renderCalls = 0;
  int tickCalls = 0;
  int disposeCalls = 0;
  int createCalls = 0;
  int? createdWidth;
  int? createdHeight;
  MapCamera? _last;
  String? styleUrl;
  bool canSleepValue = false;
  bool pumpWorkResult = false;
  int pumpWorkCalls = 0;

  @override
  Duration? frameCap;

  @override
  bool get isReady => true;

  @override
  MapCamera? get lastRenderedCamera => _last;

  @override
  bool get canSleep => canSleepValue;

  @override
  bool pumpWork() {
    pumpWorkCalls++;
    if (pumpWorkResult) canSleepValue = false; // work found → no longer idle
    return pumpWorkResult;
  }

  @override
  Future<bool> create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  }) async {
    createCalls++;
    createdWidth = width;
    createdHeight = height;
    this.styleUrl = styleUrl;
    return true;
  }

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

  @override
  bool tick() {
    tickCalls++;
    final result = tickResult;
    tickResult = false;
    return result;
  }

  @override
  void setStyle(String styleUrl) {
    this.styleUrl = styleUrl;
    canSleepValue = false;
  }

  int flushNudgeCalls = 0;
  bool pendingNudge = false;

  @override
  bool coveredForCachePurge = false;

  @override
  bool flushCachePurgeNudge() {
    flushNudgeCalls++;
    final was = pendingNudge;
    pendingNudge = false;
    return was;
  }

  @override
  Map<String, Object?> diagnostics() => <String, Object?>{
    'renderMsInline': 2.5,
    'blitMs': 0.2,
  };

  @override
  void dispose() => disposeCalls++;
}

/// The cold path still goes over the channel; mock it. A [gate] future, when
/// given, delays every createTextures response — the shape of the real
/// method-channel round trip, during which more frames (and more post-frame
/// _create callbacks) happen.
void installChannelMock({Future<void>? gate, List<int>? disposed}) {
  var nextTextureId = 1;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(MapLibreChannel.channel, (call) async {
        switch (call.method) {
          case 'createTextures':
            if (gate != null) await gate;
            return <String, Object?>{
              'ok': true,
              'textureId': nextTextureId++,
              'backTexture': 0xDEAD,
              'diagnostics': <String, Object?>{},
            };
          case 'disposeTextures':
            // Dispose is id-addressed: presenters are keyed per widget, so a
            // dispose must name its own texture, never "the latest one".
            disposed?.add((call.arguments as Map)['textureId']! as int);
            return null;
          default:
            return null;
        }
      });
}

void main() {
  late _FakeRenderer renderer;
  late MapController controller;

  setUp(() {
    renderer = _FakeRenderer();
    installChannelMock();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MapLibreChannel.channel, null);
  });

  Future<void> pumpMap(
    WidgetTester tester, {
    ValueChanged<Map<String, Object?>>? onDiagnostics,
    Duration? frameCap,
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
              frameCap: frameCap,
              rendererFactory: () => renderer,
            ),
          ],
        ),
      ),
    );
    // Frame 1 schedules _create post-frame; pump until the texture exists.
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
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

  /// Fixed-viewport harness: the map widget in a parent-controlled box, the
  /// shape of a sheet center-offset layout (layer taller than screen).
  Future<void> pumpSizedMap(
    WidgetTester tester, {
    required double height,
    Size? fixedViewport,
    double overRenderFactor = 1.0,
    Duration? frameCap,
    ValueChanged<Map<String, Object?>>? onDiagnostics,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OverflowBox(
          alignment: Alignment.topLeft,
          // All four bounds explicit: unset mins inherit the incoming TIGHT
          // 800x600 test-surface constraints and clamp the SizedBox back up.
          minWidth: 0,
          minHeight: 0,
          maxWidth: double.infinity,
          maxHeight: double.infinity,
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
                  overRenderFactor: overRenderFactor,
                  frameCap: frameCap,
                  onDiagnostics: onDiagnostics,
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

  testWidgets('build renders the current camera and draws at identity', (
    tester,
  ) async {
    await pumpMap(tester);
    final calls = renderer.renderCalls;
    expect(calls, greaterThan(0));
    expect(basemapTransform(tester).isIdentity(), isTrue);

    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(renderer.renderCalls, greaterThan(calls));
    expect(renderer.lastRenderedCamera!.center.latitude, closeTo(59.45, 1e-9));
    expect(
      basemapTransform(tester).isIdentity(),
      isTrue,
      reason: 'same-frame render: the texture already shows this camera',
    );
  });

  testWidgets('a failed render falls back to the honest transform', (
    tester,
  ) async {
    await pumpMap(tester);
    expect(basemapTransform(tester).isIdentity(), isTrue);

    renderer.renderResult = false;
    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(
      basemapTransform(tester).isIdentity(),
      isFalse,
      reason:
          'the front buffer still shows the old camera; the transform must '
          'correct against the renderer\'s ground truth',
    );

    // Recovery: the next successful build render snaps back to identity.
    renderer.renderResult = true;
    controller.move(const LatLng(59.46, 24.81), 13);
    await tester.pump();
    expect(basemapTransform(tester).isIdentity(), isTrue);
  });

  testWidgets('a tick that presents triggers a rebuild', (tester) async {
    await pumpMap(tester);
    final buildsBefore = renderer.renderCalls;

    renderer.tickResult = true;
    await tester.pump();
    await tester.pump();
    expect(
      renderer.renderCalls,
      greaterThan(buildsBefore),
      reason:
          'tick presented a frame → setState → rebuild → render (no-op on '
          'the renderer side, but the transform is recomputed)',
    );
  });

  testWidgets('diagnostics polling pauses while TickerMode mutes the route', (
    tester,
  ) async {
    // The dormant-map shape: an opaque route on top mutes the subtree via
    // TickerMode. With several live maps feeding one host-app diagnostics
    // sink, only the focused route's map may publish.
    var polls = 0;
    controller = MapController();
    Widget host({required bool enabled}) => MaterialApp(
      home: TickerMode(
        enabled: enabled,
        child: FlutterMap(
          mapController: controller,
          options: const MapOptions(
            initialCenter: LatLng(59.437, 24.7536),
            initialZoom: 13,
          ),
          children: [
            MapLibreBasemap(
              styleUrl: 'https://example.com/style.json',
              onDiagnostics: (_) => polls++,
              rendererFactory: () => renderer,
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(host(enabled: true));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(polls, 1);

    // Covered: the timer stops, not just the ticks.
    await tester.pumpWidget(host(enabled: false));
    await tester.pump(const Duration(seconds: 3));
    expect(polls, 1);

    // Popped back: polling resumes.
    await tester.pumpWidget(host(enabled: true));
    await tester.pump(const Duration(seconds: 1));
    expect(polls, 2);
  });

  testWidgets('refocus flushes a pending cache-purge nudge and re-renders', (
    tester,
  ) async {
    // A cache purge nudged while the route was covered is lost to the
    // muted ticker; refocus must flush it and force one honest render so
    // the texture never keeps presenting pre-purge pixels.
    controller = MapController();
    Widget host({required bool enabled}) => MaterialApp(
      home: TickerMode(
        enabled: enabled,
        child: FlutterMap(
          mapController: controller,
          options: const MapOptions(
            initialCenter: LatLng(59.437, 24.7536),
            initialZoom: 13,
          ),
          children: [
            MapLibreBasemap(
              styleUrl: 'https://example.com/style.json',
              rendererFactory: () => renderer,
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(host(enabled: true));
    await tester.pump();
    await tester.pump();
    final rendersBefore = renderer.renderCalls;
    final flushesBefore = renderer.flushNudgeCalls;

    await tester.pumpWidget(host(enabled: false));
    await tester.pump();
    expect(renderer.coveredForCachePurge, isTrue);

    await tester.pumpWidget(host(enabled: true));
    await tester.pump();
    await tester.pump();
    expect(renderer.coveredForCachePurge, isFalse);
    expect(renderer.flushNudgeCalls, greaterThan(flushesBefore));
    expect(renderer.renderCalls, greaterThan(rendersBefore));
  });

  testWidgets('purge under cover recreates the session on refocus', (
    tester,
  ) async {
    controller = MapController();
    Widget host({required bool enabled}) => MaterialApp(
      home: TickerMode(
        enabled: enabled,
        child: FlutterMap(
          mapController: controller,
          options: const MapOptions(
            initialCenter: LatLng(59.437, 24.7536),
            initialZoom: 13,
          ),
          children: [
            MapLibreBasemap(
              styleUrl: 'https://example.com/style.json',
              rendererFactory: () => renderer,
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(host(enabled: true));
    await tester.pump();
    await tester.pump();
    final createsBefore = renderer.createCalls;

    await tester.pumpWidget(host(enabled: false));
    await tester.pump();
    // The purge lands while covered: the renderer defers it.
    renderer.pendingNudge = true;

    await tester.pumpWidget(host(enabled: true));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(renderer.createCalls, greaterThan(createsBefore));
  });

  testWidgets('reports renderer diagnostics on the polling timer', (
    tester,
  ) async {
    Map<String, Object?>? latest;
    await pumpMap(tester, onDiagnostics: (d) => latest = d);
    await tester.pump(const Duration(seconds: 1));
    expect(latest, isNotNull);
    expect(latest!['renderMsInline'], 2.5);
    expect(latest!['blitMs'], 0.2);
  });

  testWidgets('style change reaches the renderer', (tester) async {
    await pumpMap(tester);
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
    expect(renderer.styleUrl, 'https://example.com/dark.json');
  });

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

  testWidgets('frameCap is threaded to the renderer before rendering', (
    tester,
  ) async {
    await pumpMap(tester, frameCap: const Duration(milliseconds: 15));
    expect(renderer.frameCap, const Duration(milliseconds: 15));
  });

  testWidgets('over-render margin is centered: success placement pulls the '
      'texture back by half the margin', (tester) async {
    controller = MapController();
    await pumpSizedMap(
      tester,
      height: 800,
      fixedViewport: const Size(400, 600),
      overRenderFactor: 1.5,
    );
    // Session renders 1.5x the 400x600 viewport.
    expect(renderer.createdWidth, 600);
    expect(renderer.createdHeight, 900);

    // The 400x600 viewport sits bottom-center of the 400x800 layer → the
    // visible rect starts at (0, 200); the 200x300 margin hangs half on
    // each side, so the texture's top-left lands at (0-100, 200-150).
    final translation = basemapTransform(tester).getTranslation();
    expect(translation.x, closeTo(-100, 1e-6));
    expect(translation.y, closeTo(50, 1e-6));
  });

  /// Drive the camera east at ~1875 px/s (30px per 16ms frame) for [frames]
  /// frames — enough to converge the 100ms-EMA velocity estimate. The
  /// admission gate throttles most of these frames (30px per step is
  /// usually inside the runway), so it keeps panning at the same per-frame
  /// rate past [frames] until one is actually admitted — every caller below
  /// reads [MapLibreBasemap]'s rendered/shown state right after this
  /// returns, and that assumption (fresh as of the last simulated frame)
  /// predates the gate.
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
    // Keep panning at the same per-frame rate past [frames] until one more
    // is actually admitted, so callers see a fresh rendered/shown state —
    // capped as a runaway guard, well beyond the ~3 extra frames this
    // normally takes.
    for (var i = 0; i < 20; i++) {
      final callsBefore = renderer.renderCalls;
      final cam = controller.camera;
      controller.move(
        cam.screenOffsetToLatLng(
          cam.nonRotatedSize.center(Offset.zero) + const Offset(30, 0),
        ),
        cam.zoom,
      );
      await tester.pump(const Duration(milliseconds: 16));
      if (renderer.renderCalls != callsBefore) break;
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

  testWidgets(
    'no cap still biases: the admission gate alone activates the lead '
    '(leadTime 33ms)',
    (tester) async {
      controller = MapController();
      await pumpSizedMap(
        tester,
        height: 800,
        fixedViewport: const Size(400, 600),
        overRenderFactor: 1.5,
      );
      await panEast(tester);

      // 1875 px/s × 33ms lead = 61.875px east, inside the 85px clamp
      // (0.85 × 100px half-margin) — same convergence as the capped case,
      // just with the uncapped constant leadTime from _biasedCamera.
      final shown = renderer.lastRenderedCamera!;
      final cropped = cropCamera(
        controller.camera,
        const Rect.fromLTWH(0, 200, 400, 600),
      );
      final p = cropped.latLngToScreenOffset(shown.center);
      expect(p.dx - 200, closeTo(61.875, 9));
      expect(p.dy - 300, closeTo(0, 1));
    },
  );

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

    // Self-contained: confirm the bias was actually nonzero, not just that
    // the placement math happens to be exact for a zero bias too. The
    // rendered center must sit measurably ahead of the crop center, beyond
    // the 8px hysteresis quantum.
    final cropped = cropCamera(
      controller.camera,
      const Rect.fromLTWH(0, 200, 400, 600),
    );
    final p = cropped.latLngToScreenOffset(shown.center);
    expect(p.dx - 200, greaterThan(8));
  });

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

    // The capped frame: render refused, camera 120px further east — beyond
    // the 100px symmetric margin alone (which would bare a strip), but
    // still inside the margin+bias runway (~148-156px). If the bias silently
    // stopped applying, this move would bare the leading edge and the
    // assertion below would fail.
    renderer.renderResult = false;
    final cam = controller.camera;
    controller.move(
      cam.screenOffsetToLatLng(
        cam.nonRotatedSize.center(Offset.zero) + const Offset(120, 0),
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

  testWidgets('dispose names this widget\'s own texture id', (tester) async {
    final disposed = <int>[];
    installChannelMock(disposed: disposed);
    controller = MapController();
    await pumpSizedMap(tester, height: 600);
    // Resize path: the old session's texture (id 1) is disposed by name and
    // the recreate gets a fresh id.
    await pumpSizedMap(tester, height: 700);
    await tester.pump();
    expect(disposed, [1]);
    // Widget teardown disposes the live texture (id 2), again by name.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposed, [1, 2]);
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

  testWidgets(
    'a factor change mid-flight create is retried once the stale create lands',
    (tester) async {
      // Hold createTextures open so the first create is still in flight when
      // the factor changes underneath it.
      final gate = Completer<void>();
      installChannelMock(gate: gate.future);
      controller = MapController();

      await pumpSizedMap(
        tester,
        height: 800,
        fixedViewport: const Size(400, 600),
        overRenderFactor: 1.0,
      );
      // Still gated: the channel round trip hasn't resolved, so the renderer
      // was never actually asked to create anything yet.
      expect(renderer.createCalls, 0);

      // Rebuild at the new factor while that first create is still in
      // flight — build's needsCreate schedules a follow-up call, but it
      // no-ops against _creating; the retry has to come from the stale
      // create's own setState landing.
      await pumpSizedMap(
        tester,
        height: 800,
        fixedViewport: const Size(400, 600),
        overRenderFactor: 1.5,
      );
      expect(renderer.createCalls, 0);

      gate.complete();
      // The stale (factor 1.0) create resumes, completes the channel round
      // trip and lands its setState.
      await tester.pump();
      await tester.pump();
      // A build now sees _sessionFactor (1.0) != overRenderFactor (1.5) and
      // schedules — then runs — the retry create at the live factor.
      await tester.pump();
      await tester.pump();

      expect(renderer.createCalls, greaterThanOrEqualTo(2));
      expect(renderer.createdWidth, 600);
      expect(renderer.createdHeight, 900);
    },
  );

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

  testWidgets(
    'settle: forced admission issues exactly once even when the render '
    'fails to land',
    (tester) async {
      controller = MapController();
      await pumpSizedMap(tester, height: 800, overRenderFactor: 1.5);
      final calls = renderer.renderCalls;

      controller.move(controller.camera.center, 13.03); // sub-quantum
      await tester.pump();
      expect(renderer.renderCalls, calls);

      // The async renderer never returns true while a render is in flight;
      // settle must clear on issue, not on landing, or it would re-force
      // every subsequent build forever.
      renderer.renderResult = false;
      await tester.pump(const Duration(milliseconds: 350)); // settle window
      await tester.pump();
      expect(
        renderer.renderCalls,
        calls + 1,
        reason: 'the settle-forced render is issued exactly once',
      );

      // A same-camera, tick-driven rebuild must not re-force a settle
      // render: _settleForced already cleared on issue, and the settle
      // window itself keeps running rather than re-arming.
      renderer.tickResult = true;
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(renderer.renderCalls, calls + 1);
    },
  );

  testWidgets(
    'admission counters: only camera-driven gate decisions move them',
    (tester) async {
      controller = MapController();
      Map<String, Object?> diag = const {};
      await pumpSizedMap(
        tester,
        height: 800,
        overRenderFactor: 1.5,
        onDiagnostics: (d) => diag = d,
      );
      await tester.pump(const Duration(seconds: 1)); // poll after create
      final admitsAfterCreate = diag['admits']! as int;
      final skipsAfterCreate = diag['admissionSkips']! as int;

      // Rebuild the exact same tree at the same camera and size: a parent
      // rebuild, not a camera-driven decision — neither counter may move.
      await pumpSizedMap(
        tester,
        height: 800,
        overRenderFactor: 1.5,
        onDiagnostics: (d) => diag = d,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(diag['admits'], admitsAfterCreate);
      expect(diag['admissionSkips'], skipsAfterCreate);

      // A denied pan (30px < 100px margin - 16px guard) still increments
      // admissionSkips, and by exactly one build's worth.
      final camera = controller.camera;
      controller.move(
        camera.screenOffsetToLatLng(
          camera.nonRotatedSize.center(Offset.zero) + const Offset(30, 0),
        ),
        camera.zoom,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(diag['admissionSkips'], skipsAfterCreate + 1);
      expect(diag['admits'], admitsAfterCreate);
    },
  );

  testWidgets('fling sequence admits ~per-runway, not per-frame (uncapped)', (
    tester,
  ) async {
    controller = MapController();
    await pumpSizedMap(tester, height: 800, overRenderFactor: 1.5);
    final callsBefore = renderer.renderCalls;

    // 400-wide map, overRenderFactor 1.5 → margin (600-400)/2 = 100px per
    // side; guard 16px. 20 successive 30px-east pans (600px total drift)
    // simulate a fling. Per-frame admission would render on all 20 steps;
    // instead each admission renders at the fresh camera and so renews up
    // to ~100px (+ any lead bias) of runway underneath the guard — several
    // 30px steps then fit inside that runway before the next one runs out,
    // roughly one admission per ~100px / 30px ≈ 3-4 steps, i.e. ~5-7
    // admissions across 20 steps. Band kept generous (3-10) to stay robust
    // to bias/EMA convergence noise.
    for (var i = 0; i < 20; i++) {
      final camera = controller.camera;
      controller.move(
        camera.screenOffsetToLatLng(
          camera.nonRotatedSize.center(Offset.zero) + const Offset(30, 0),
        ),
        camera.zoom,
      );
      await tester.pump();
    }

    final delta = renderer.renderCalls - callsBefore;
    expect(delta, greaterThanOrEqualTo(3));
    expect(delta, lessThanOrEqualTo(10));
  });
}
