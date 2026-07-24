import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:flutter_map_maplibre/src/maplibre_channel.dart';
import 'package:flutter_map_maplibre/src/viewport_crop.dart';
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
void installChannelMock({Future<void>? gate}) {
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
  /// shape of Vedu's sheet center-offset layout (layer taller than screen).
  Future<void> pumpSizedMap(
    WidgetTester tester, {
    required double height,
    Size? fixedViewport,
    double overRenderFactor = 1.0,
    Duration? frameCap,
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
}
