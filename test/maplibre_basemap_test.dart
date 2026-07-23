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

  @override
  bool get isReady => true;

  @override
  MapCamera? get lastRenderedCamera => _last;

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
  void setStyle(String styleUrl) => this.styleUrl = styleUrl;

  @override
  Map<String, Object?> diagnostics() => <String, Object?>{
    'renderMsInline': 2.5,
    'blitMs': 0.2,
  };

  @override
  void dispose() => disposeCalls++;
}

/// The cold path still goes over the channel; mock it.
void installChannelMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(MapLibreChannel.channel, (call) async {
        switch (call.method) {
          case 'createTextures':
            return <String, Object?>{
              'ok': true,
              'textureId': 1,
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
}
