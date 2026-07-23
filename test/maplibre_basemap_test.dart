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
    // Fresh state per test: without this, an uncompleted completer left
    // dangling by one test (e.g. the coalescing test's final, deliberately
    // unanswered push) is still the oldest entry in `_replies` when the next
    // test calls replyNext, so firstWhere resolves that stale, disposed
    // widget's push instead of the current test's — the reply the current
    // test is waiting on never lands.
    setCameraCalls.clear();
    _replies.clear();
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

  void replyNext({required bool rendered}) {
    _replies.firstWhere((c) => !c.isCompleted).complete(<String, Object?>{
      'rendered': rendered,
    });
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
    expect(
      harness.setCameraCalls,
      isNotEmpty,
      reason: 'initial camera push should have been sent',
    );
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

  testWidgets('stamps _rendered when the push is sent', (tester) async {
    await pumpMap(tester);

    // Initial push in flight; the send-time stamp means the frame that sent
    // the push already treats the texture as showing its camera — identity.
    expect(isIdentity(basemapTransform(tester)), isTrue);

    harness.replyNext(rendered: true);
    await tester.pump();
    expect(isIdentity(basemapTransform(tester)), isTrue);

    // Move: the same build both sends the push and stamps its camera, so the
    // transform stays identity in that very frame — no reply needed. (The
    // native handler renders before replying, so by composite time the
    // texture matches; stamping on reply instead makes the transform assume
    // a one-frame-older camera and oscillate, which showed up on device as
    // stutter.)
    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(
      isIdentity(basemapTransform(tester)),
      isTrue,
      reason: 'send-time stamp: the pushing frame already trusts the texture',
    );
  });

  testWidgets('a queued (unsent) camera is not stamped', (tester) async {
    await pumpMap(tester);
    // Initial push still in flight — the next move cannot send, only queue.
    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(
      isIdentity(basemapTransform(tester)),
      isFalse,
      reason:
          'the moved camera was queued, not sent, so the transform must '
          'correct against the initial camera still in the texture',
    );
  });

  testWidgets('a failed render rolls back and retries the push', (
    tester,
  ) async {
    await pumpMap(tester);
    harness.replyNext(rendered: true);
    await tester.pump();

    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(isIdentity(basemapTransform(tester)), isTrue);
    final callsBefore = harness.setCameraCalls.length;

    harness.replyNext(rendered: false);
    // The rollback setState fires from the reply's Future callback; its
    // rebuild lands on the next pump, and that rebuild re-pushes the current
    // camera (the sameCamera guard now fails against the rolled-back stamp).
    // Without the rollback there is no setState, no rebuild, and no retry —
    // this is what discriminates honest failure handling from
    // optimism-forever.
    await tester.pump();
    await tester.pump();
    expect(
      harness.setCameraCalls.length,
      callsBefore + 1,
      reason: 'a failed render must retry the camera on the next rebuild',
    );
    expect(harness.setCameraCalls.last['lat'], closeTo(59.45, 1e-9));
    expect(
      isIdentity(basemapTransform(tester)),
      isTrue,
      reason: 'the retry re-stamps optimistically',
    );
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

    expect(
      harness.setCameraCalls.length,
      callsBefore + 1,
      reason: 'only the first change starts a push; the rest coalesce',
    );

    harness.replyNext(rendered: true);
    await tester.pump();

    expect(
      harness.setCameraCalls.length,
      callsBefore + 2,
      reason: 'completion sends exactly one push for the newest camera',
    );
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
