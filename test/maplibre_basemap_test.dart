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
