import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_map/flutter_map.dart';
// src imports: the public exports only land in Task 5.
import 'package:flutter_map_maplibre/src/ffi/worker_basemap_renderer.dart';
import 'package:flutter_map_maplibre/src/ffi/worker_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

MapCamera cameraAt(double lat, double lng, {double zoom = 14}) => MapCamera(
  crs: const Epsg3857(),
  center: LatLng(lat, lng),
  zoom: zoom,
  rotation: 0,
  nonRotatedSize: const Size(400, 800),
  size: const Size(400, 800),
);

class FakeLink implements WorkerLink {
  final calls = <String>[];
  bool startResult = true;
  // The real SendPort the renderer wired up, captured so tests that need to
  // exercise actual ReceivePort delivery (rather than calling
  // handleCompletion directly) can post to it.
  SendPort? completions;

  @override
  bool start(SendPort completions) {
    calls.add('start');
    this.completions = completions;
    return startResult;
  }

  @override
  void postCreate({
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
    required int presenterId,
  }) => calls.add('create:$width:$height:$presenterId');

  @override
  void postPump() => calls.add('pump');

  @override
  void postJump({
    required double lat,
    required double lng,
    required double zoom,
    required double bearing,
    required int gen,
  }) => calls.add('jump:$gen');

  @override
  void postRender(int gen) => calls.add('render:$gen');

  @override
  void postSetStyle(String url) => calls.add('style:$url');

  @override
  void postDestroy() => calls.add('destroy');
}

Future<WorkerBasemapRenderer> createdRenderer(
  FakeLink link, {
  Duration Function()? arrivalClock,
}) async {
  final renderer = WorkerBasemapRenderer(
    link: link,
    arrivalClock: arrivalClock,
  );
  final pending = renderer.create(
    backTextureAddress: 7,
    presenterId: 42,
    width: 400,
    height: 800,
    scale: 3.0,
    styleUrl: 'https://example.com/style.json',
  );
  renderer.handleCompletion([0, 0, 0, 0, 0]); // CREATED, all OK
  expect(await pending, isTrue);
  return renderer;
}

void main() {
  test('create posts start+create and completes on CREATED', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    expect(link.calls, ['start', 'create:400:800:42']);
    expect(renderer.isReady, isTrue);
  });

  test('create failure completes false and destroys the worker', () async {
    final link = FakeLink();
    final renderer = WorkerBasemapRenderer(link: link);
    final pending = renderer.create(
      backTextureAddress: 7,
      presenterId: 42,
      width: 400,
      height: 800,
      scale: 3.0,
      styleUrl: 's',
    );
    renderer.handleCompletion([0, 0, 0, 0, 5]); // attach failed
    expect(await pending, isFalse);
    expect(renderer.isReady, isFalse);
    expect(link.calls.last, 'destroy');
  });

  test('render posts pump+jump+render; returns true once settled, false '
      'while in flight', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    link.calls.clear();
    final camera = cameraAt(59.43, 24.75);
    // First issue: async, so the front buffer does not show it yet.
    expect(renderer.render(camera), isFalse);
    expect(link.calls, ['pump', 'jump:1', 'render:1']);
    link.calls.clear();
    // Same camera, still in flight (no RENDERED completion yet): no
    // re-post, and still not on screen.
    expect(renderer.render(camera), isFalse);
    expect(link.calls, isEmpty);
    // Once the render for it has actually landed, the front buffer shows
    // it: matches the BasemapRenderer.render doc contract ("Returns true
    // when the front buffer now shows it (including the no-op case where
    // it already did)"), same as FfiBasemapRenderer's settled branch.
    renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]);
    expect(renderer.render(camera), isTrue);
    expect(link.calls, isEmpty);
  });

  test(
    'RENDERED publishes through the latency FIFO on a busy pipeline',
    () async {
      final link = FakeLink();
      var arrival = Duration.zero;
      final renderer = await createdRenderer(link, arrivalClock: () => arrival);
      final a = cameraAt(59.43, 24.75);
      final b = cameraAt(59.44, 24.76);
      renderer.render(a);
      renderer.render(b);
      // Two RENDERED arrive 8ms apart: busy pipeline, FIFO depth 1 holds the
      // newest back one promotion.
      arrival = const Duration(milliseconds: 8);
      renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]);
      arrival = const Duration(milliseconds: 16);
      renderer.handleCompletion([2, 2, 0, 10.0, 1.5, 0.1]);
      expect(renderer.lastRenderedCamera!.center.latitude, a.center.latitude);
      renderer.tick(); // idle tick promotes the pending frame
      expect(renderer.lastRenderedCamera!.center.latitude, b.center.latitude);
    },
  );

  test('RENDERED after an idle gap publishes immediately', () async {
    final link = FakeLink();
    var arrival = Duration.zero;
    final renderer = await createdRenderer(link, arrivalClock: () => arrival);
    final a = cameraAt(59.43, 24.75);
    renderer.render(a);
    arrival = const Duration(milliseconds: 100); // idle > 25ms
    renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]);
    expect(renderer.lastRenderedCamera!.center.latitude, a.center.latitude);
  });

  test('SUPERSEDED is never published and is counted', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.render(cameraAt(59.43, 24.75));
    renderer.handleCompletion([3, 1]); // SUPERSEDED gen 1
    expect(renderer.lastRenderedCamera, isNull);
    expect(renderer.diagnostics()['superseded'], 1);
  });

  test('frameCap defers the RENDER post but not the JUMP', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    // First render uncapped so _sincePresent resets at a known point; only
    // then set the cap — the second render lands well inside the window.
    renderer.render(cameraAt(59.43, 24.75));
    renderer.frameCap = const Duration(seconds: 100);
    link.calls.clear();
    renderer.render(cameraAt(59.44, 24.76));
    expect(link.calls, ['pump', 'jump:2']); // capped: no render post
    expect(renderer.diagnostics()['cappedTicks'], 1);
  });

  test('EVENTS drives flags and canSleep', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    expect(renderer.canSleep, isFalse); // no idle seen yet
    final camera = cameraAt(59.43, 24.75);
    renderer.render(camera); // posts the pre-jump pump (marked stale)
    renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]); // publish
    renderer.tick(); // promote if pending; posts a second, non-stale pump
    // Resolves the pre-jump pump: an idle observation from before the jump
    // — must not latch idle (see the stale-pump guard).
    renderer.handleCompletion([1, 0, 1, 1, 0, 50, 0.5]);
    expect(renderer.canSleep, isFalse);
    // Resolves tick()'s pump: a genuinely new idle observation latches it.
    renderer.handleCompletion([1, 0, 1, 0, 0, 50, 0.5]);
    expect(renderer.canSleep, isTrue);
    renderer.handleCompletion([1, 1, 0, 0, 0, 50, 0.5]); // update available
    expect(renderer.canSleep, isFalse);
  });

  test(
    'a stale pre-jump-pump EVENTS does not latch idle; a fresh one does',
    () async {
      final link = FakeLink();
      var arrival = Duration.zero;
      final renderer = await createdRenderer(link, arrivalClock: () => arrival);
      final camera = cameraAt(59.43, 24.75);
      renderer.render(camera); // posts the pre-jump pump (marked stale)
      arrival = const Duration(milliseconds: 100); // idle pipeline: publish
      renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]); // RENDERED
      expect(renderer.lastRenderedCamera, isNotNull);
      // Resolves the pre-jump pump: its idle observation predates the jump
      // — must not latch _idleSinceLastJump.
      renderer.handleCompletion([1, 0, 1, 0, 0, 0, 0.1]);
      expect(renderer.canSleep, isFalse);
      // A fresh pump posted after the jump (here, by tick()) resolves for
      // real: its idle observation latches normally.
      renderer.tick();
      renderer.handleCompletion([1, 0, 1, 0, 0, 0, 0.1]);
      expect(renderer.canSleep, isTrue);
    },
  );

  test('tick returns true only when new content arrived', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.render(cameraAt(59.43, 24.75));
    expect(renderer.tick(), isFalse);
    renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]);
    expect(renderer.tick(), isTrue);
    expect(renderer.tick(), isFalse);
  });

  test('failed RENDERED does not publish and counts the streak', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.render(cameraAt(59.43, 24.75));
    renderer.handleCompletion([2, 1, 7, 10.0, -3.0, 0.1]); // render failed
    expect(renderer.lastRenderedCamera, isNull);
    expect(renderer.diagnostics()['failStreak'], 1);
    expect(renderer.canSleep, isFalse); // unpublished jump vetoes sleep
  });

  test('dispose posts destroy; create-after-dispose starts fresh', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.dispose();
    expect(link.calls.last, 'destroy');
    renderer.handleCompletion([4]); // DESTROYED
    expect(renderer.isReady, isFalse);
    final pending = renderer.create(
      backTextureAddress: 7,
      presenterId: 43,
      width: 400,
      height: 800,
      scale: 3.0,
      styleUrl: 's',
    );
    renderer.handleCompletion([0, 0, 0, 0, 0]);
    expect(await pending, isTrue);
    expect(link.calls.where((c) => c == 'start').length, 2);
  });

  test('a stale DESTROYED from a torn-down session cannot kill the next '
      'session', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    final firstSessionCompletions = link.completions!;
    renderer.dispose();
    // A new session is created before the first session's DESTROYED (or
    // its 2s fallback) ever lands — create() must close the first
    // session's port eagerly rather than leaving it for a race.
    final pending = renderer.create(
      backTextureAddress: 7,
      presenterId: 43,
      width: 400,
      height: 800,
      scale: 3.0,
      styleUrl: 's',
    );
    final secondSessionCompletions = link.completions!;
    renderer.handleCompletion([0, 0, 0, 0, 0]); // second session CREATED
    expect(await pending, isTrue);
    // The first session's DESTROYED finally arrives late, through a real
    // ReceivePort round-trip (not a direct handleCompletion call — the
    // defect this guards against only shows up when an actual
    // ReceivePort gets closed). It must affect only the torn-down
    // session's own (already-closed) port, never the second session's
    // live one.
    firstSessionCompletions.send([4]);
    await Future<void>.delayed(Duration.zero);
    expect(renderer.isReady, isTrue);
    // The second session's real port must still be alive and delivering:
    // a genuine completion sent through it must still be processed.
    renderer.render(cameraAt(59.43, 24.75));
    secondSessionCompletions.send([2, 1, 0, 10.0, 1.5, 0.1]);
    await Future<void>.delayed(Duration.zero);
    renderer.tick(); // promote out of the busy-pipeline FIFO if pending
    expect(renderer.lastRenderedCamera, isNotNull);
  });

  test('tick-driven renders do not alternate skip/render '
      '(parity with the sync renderer)', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.render(cameraAt(59.43, 24.75)); // sets _jumpedCamera
    // needsRepaint known+true: keeps decideTick returning `render` as
    // long as renderedSinceLastTick is false.
    renderer.handleCompletion([1, 0, 0, 1, 1, 0, 0.1]);
    link.calls.clear();
    // First tick after render() consumes the render()-set flag: skip.
    renderer.tick();
    expect(link.calls, isNot(contains('render:2')));
    link.calls.clear();
    // Two consecutive tick()-driven renders must BOTH post RENDER:
    // tick()'s own render branch must not re-set
    // _renderPostedSinceLastTick (that would make the next tick skip,
    // halving the tick-driven rate).
    renderer.tick();
    expect(link.calls, contains('render:2'));
    link.calls.clear();
    renderer.tick();
    expect(link.calls, contains('render:3'));
  });
}
