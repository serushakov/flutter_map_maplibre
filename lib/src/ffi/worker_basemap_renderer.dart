import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';

import '../basemap_renderer.dart';
import '../camera_conventions.dart';
import 'worker_link.dart';

/// [BasemapRenderer] over the native render worker thread (Android).
///
/// The worker owns runtime/map/session on a dedicated OS thread (the mln C
/// API is owner-thread affine and Dart isolates have no fixed OS thread).
/// This facade keeps the exact decision state machine of FfiBasemapRenderer
/// in Dart — flags, latency FIFO, diagnostics — but every flag update comes
/// from a completion message instead of a synchronous return value. Dart
/// still chooses every camera and places every texture; only *when* renders
/// execute moved.
class WorkerBasemapRenderer implements BasemapRenderer {
  WorkerBasemapRenderer({WorkerLink? link, Duration Function()? arrivalClock})
    : _makeLink = (link == null ? FfiWorkerLink.new : () => link),
      _arrivalClock = arrivalClock;

  /// Completion message kinds — first element of every port message.
  /// Mirrored in fmm_worker.cpp; keep in sync.
  static const _kCreated = 0;
  static const _kEvents = 1;
  static const _kRendered = 2;
  static const _kSuperseded = 3;
  static const _kDestroyed = 4;

  /// See FfiBasemapRenderer.androidPresentLatencyFrames — same latch model,
  /// now keyed on completion arrival times. Re-tune on device.
  static int presentLatencyFrames = 1;

  /// Completions arriving closer together than this ran against a busy
  /// pipeline (same constant and rationale as FfiBasemapRenderer).
  static const _pipelineBusy = Duration(milliseconds: 25);

  final WorkerLink Function() _makeLink;
  final Duration Function()? _arrivalClock;
  final Stopwatch _arrivalStopwatch = Stopwatch()..start();
  Duration get _now => _arrivalClock?.call() ?? _arrivalStopwatch.elapsed;

  WorkerLink? _link;
  ReceivePort? _port;
  // The port (and its fallback timer) of a session currently being torn
  // down. Kept separate from [_port] so a stale DESTROYED — or the fallback
  // firing late — can only ever close ITS OWN session's port, never the
  // port of a session created after it. At most one teardown is ever
  // in-flight: [create] closes any leftover eagerly before starting fresh.
  ReceivePort? _teardownPort;
  Completer<bool>? _createCompleter;
  Timer? _portCloseFallback;

  bool _ready = false;

  int _gen = 0;
  final Map<int, MapCamera> _inFlight = {};
  final Map<int, Duration> _issuedAt = {};
  MapCamera? _jumpedCamera;
  MapCamera? _lastRenderedCamera;
  final List<MapCamera> _pendingRenderedCameras = [];
  Duration _lastArrival = Duration.zero;

  bool _updateAvailable = false;
  bool _needsRepaint = false;
  bool _idleSinceLastJump = false;
  bool _renderPostedSinceLastTick = false;
  bool _presentedSinceLastTick = false;

  // Pumps posted but not yet resolved by an EVENTS completion, and how many
  // of those (from the front of the FIFO) predate the most recent camera
  // jump / style change. An EVENTS resolving a stale pump reports an idle
  // observation made before that jump — applying it would re-latch
  // [_idleSinceLastJump] while the new camera's tiles may still be loading.
  int _pumpsInFlight = 0;
  int _stalePumps = 0;

  @override
  Duration? frameCap;
  final Stopwatch _sincePresent = Stopwatch()..start();

  // Diagnostics, mirroring FfiBasemapRenderer where the concept survives.
  final _diagnostics = <String, Object?>{};
  int _frameCount = 0;
  int _cameraRenders = 0;
  int _linkRenders = 0;
  int _skippedTicks = 0;
  int _cappedTicks = 0;
  int _idleEvents = 0;
  int _superseded = 0;
  int _drawCalls = 0;
  int _failStreak = 0;
  double _maxRenderMs = 0;
  int _steadyFrames = 0;
  double _steadyRenderMs = 0;
  double _steadyMaxMs = 0;
  double? _renderMs;
  double? _blitMs;
  double? _pumpMs;
  double? _jumpMs;
  double? _completionLagMs;
  double _completionLagMsMax = 0;

  @override
  bool get isReady => _ready;

  @override
  MapCamera? get lastRenderedCamera => _lastRenderedCamera;

  @override
  bool get canSleep =>
      _ready &&
      decideSleep(
        idleSinceLastJump: _idleSinceLastJump,
        updateAvailable: _updateAvailable,
        needsRepaint: _needsRepaint,
        unpublishedJump: !identical(_jumpedCamera, _lastRenderedCamera),
      );

  @override
  Future<bool> create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  }) {
    assert(!_ready, 'dispose before re-creating');
    _resetSessionState();
    // A fresh session never wants a previous one's port around: close it
    // right here rather than waiting for its DESTROYED (or the 2s fallback)
    // — late messages on a closed port are dropped by the VM, which is
    // exactly what we want (see [_teardownPort]'s doc).
    _closeTeardownPort();
    final link = _makeLink();
    final port = ReceivePort();
    if (!link.start(port.sendPort)) {
      port.close();
      _diagnostics['workerStartFailed'] = true;
      return Future.value(false);
    }
    _link = link;
    _port = port;
    port.listen(handleCompletion);
    final completer = Completer<bool>();
    _createCompleter = completer;
    link.postCreate(
      width: width,
      height: height,
      scale: scale,
      styleUrl: styleUrl,
      presenterId: presenterId,
    );
    return completer.future;
  }

  void _resetSessionState() {
    _gen = 0;
    _inFlight.clear();
    _issuedAt.clear();
    _jumpedCamera = null;
    _lastRenderedCamera = null;
    _pendingRenderedCameras.clear();
    _updateAvailable = false;
    _needsRepaint = false;
    _idleSinceLastJump = false;
    _renderPostedSinceLastTick = false;
    _presentedSinceLastTick = false;
    _failStreak = 0;
    _pumpsInFlight = 0;
    _stalePumps = 0;
  }

  static bool _sameCamera(MapCamera? a, MapCamera b) =>
      a != null &&
      a.center.latitude == b.center.latitude &&
      a.center.longitude == b.center.longitude &&
      a.zoom == b.zoom &&
      a.rotation == b.rotation;

  @override
  bool render(MapCamera camera) {
    final link = _link;
    if (!_ready || link == null) return false;
    // Settled: the front buffer already shows [camera] (published, or still
    // queued in the FIFO to be promoted) — matches the interface contract
    // ("Returns true when the front buffer now shows it (including the
    // no-op case where it already did)"), same as
    // FfiBasemapRenderer.render's early return.
    final newestRendered = _pendingRenderedCameras.isNotEmpty
        ? _pendingRenderedCameras.last
        : _lastRenderedCamera;
    if (_sameCamera(newestRendered, camera)) return true;
    // Already in flight (jumped but not yet rendered/published): nothing new
    // to issue, and it is not on screen yet.
    if (_sameCamera(_jumpedCamera, camera)) return false;

    link.postPump();
    _pumpsInFlight++;
    // Every pump currently outstanding (including the one just posted)
    // predates the jump about to be issued: its eventual EVENTS reports an
    // idle observation from before this camera, and must not re-latch
    // _idleSinceLastJump.
    _stalePumps = _pumpsInFlight;
    _gen++;
    link.postJump(
      lat: camera.center.latitude,
      lng: camera.center.longitude,
      zoom: maplibreZoom(camera.zoom),
      bearing: maplibreBearing(camera.rotation),
      gen: _gen,
    );
    _jumpedCamera = camera;
    _idleSinceLastJump = false;

    if (!frameCapSatisfied(
      frameCap: frameCap,
      sinceLastPresent: _sincePresent.elapsed,
    )) {
      _cappedTicks++;
      return false;
    }
    _postRender(link, _gen, camera);
    _renderPostedSinceLastTick = true;
    _cameraRenders++;
    return false;
  }

  void _postRender(WorkerLink link, int gen, MapCamera camera) {
    _sincePresent.reset();
    _inFlight[gen] = camera;
    _issuedAt[gen] = _now;
    link.postRender(gen);
  }

  @override
  bool tick() {
    final link = _link;
    if (!_ready || link == null) return false;
    link.postPump();
    _pumpsInFlight++;
    final decision = decideTick(
      updateAvailable: _updateAvailable,
      needsRepaint: _needsRepaint,
      renderedSinceLastTick: _renderPostedSinceLastTick,
    );
    _renderPostedSinceLastTick = false;
    switch (decision) {
      case TickDecision.skipIdle:
      case TickDecision.skipRenderedThisFrame:
        // One tick = one engine frame — the latch cadence; drain one entry.
        if (_pendingRenderedCameras.isNotEmpty) {
          _lastRenderedCamera = _pendingRenderedCameras.removeAt(0);
        }
        _skippedTicks++;
      case TickDecision.render:
        if (!frameCapSatisfied(
          frameCap: frameCap,
          sinceLastPresent: _sincePresent.elapsed,
        )) {
          _cappedTicks++;
        } else {
          final jumped = _jumpedCamera;
          if (jumped != null) {
            _gen++;
            _postRender(link, _gen, jumped);
            _linkRenders++;
          }
        }
    }
    final presented = _presentedSinceLastTick;
    _presentedSinceLastTick = false;
    return presented;
  }

  @override
  bool pumpWork() {
    final link = _link;
    if (!_ready || link == null) return false;
    link.postPump();
    _pumpsInFlight++;
    // Flags are one round-trip stale; the next insurance-pump tick (or any
    // completion-driven wake) observes the fresh ones.
    return _updateAvailable || _needsRepaint;
  }

  @override
  void setStyle(String styleUrl) {
    final link = _link;
    if (!_ready || link == null) return;
    link.postSetStyle(styleUrl);
    // Any pump already outstanding predates this style change: its eventual
    // idle report is stale for the same reason a pre-jump pump's is (see
    // render()) — a style swap re-requests a repaint just like a camera
    // jump does.
    _stalePumps = _pumpsInFlight;
    _idleSinceLastJump = false;
  }

  /// Handles one completion message from the worker. Public for tests; the
  /// ReceivePort listener is exactly this method.
  @visibleForTesting
  void handleCompletion(Object? message) {
    final list = message as List<Object?>;
    switch (list[0] as int) {
      case _kCreated:
        _diagnostics['runtimeCreateStatus'] = list[1];
        _diagnostics['mapCreateStatus'] = list[2];
        _diagnostics['setStyleStatus'] = list[3];
        _diagnostics['attachStatus'] = list[4];
        final ok = list[1] == 0 && list[2] == 0 && list[3] == 0 && list[4] == 0;
        _ready = ok;
        final completer = _createCompleter;
        _createCompleter = null;
        if (!ok) _teardownLink();
        completer?.complete(ok);
      case _kEvents:
        if (_pumpsInFlight > 0) _pumpsInFlight--;
        // The FIFO + in-order port delivery mean this EVENTS resolves the
        // oldest outstanding pump: if that pump was marked stale (posted
        // before the latest jump/style change), its idle observation
        // predates that change and must not latch _idleSinceLastJump —
        // still counted in diagnostics, and updates/repaint/drawCalls/pumpMs
        // still apply (a stale "update available" is safe-sticky).
        final stale = _stalePumps > 0;
        if (stale) _stalePumps--;
        if ((list[1] as int) > 0) _updateAvailable = true;
        final idles = list[2] as int;
        if (idles > 0) {
          _idleEvents += idles;
          if (!stale) _idleSinceLastJump = true;
        }
        if (list[3] == 1) _needsRepaint = list[4] == 1;
        _drawCalls = list[5] as int;
        _pumpMs = _ewma(_pumpMs, list[6] as double);
      case _kRendered:
        _handleRendered(
          gen: list[1] as int,
          status: list[2] as int,
          renderMs: list[3] as double,
          blitRc: list[4] as double,
          jumpMs: list[5] as double,
        );
      case _kSuperseded:
        final gen = list[1] as int;
        _inFlight.remove(gen);
        _issuedAt.remove(gen);
        _superseded++;
      case _kDestroyed:
        // Only ever closes the torn-down session's own port (see
        // [_teardownPort]'s doc) — never a session created after it.
        _closeTeardownPort();
    }
  }

  void _handleRendered({
    required int gen,
    required int status,
    required double renderMs,
    required double blitRc,
    required double jumpMs,
  }) {
    final camera = _inFlight.remove(gen);
    final issuedAt = _issuedAt.remove(gen);
    if (issuedAt != null) {
      final lag = (_now - issuedAt).inMicroseconds / 1000.0;
      _completionLagMs = _ewma(_completionLagMs, lag);
      if (lag > _completionLagMsMax) _completionLagMsMax = lag;
    }
    _diagnostics['lastRenderStatus'] = status;
    if (status != 0 || blitRc < 0) {
      if (blitRc < 0) _diagnostics['presentError'] = blitRc;
      _failStreak++;
      _diagnostics['failStreak'] = _failStreak;
      if (_failStreak == 1 || _failStreak % 240 == 0) {
        debugPrint(
          'MLNERR worker render status=$status blit=$blitRc '
          'streak=$_failStreak',
        );
      }
      return;
    }
    _diagnostics.remove('presentError');
    if (_failStreak > 0) {
      debugPrint('MLNERR recovered after streak=$_failStreak');
      _failStreak = 0;
      _diagnostics.remove('failStreak');
    }
    _updateAvailable = false;
    _frameCount++;
    _renderMs = _ewma(_renderMs, renderMs);
    _blitMs = _ewma(_blitMs, blitRc);
    _jumpMs = _ewma(_jumpMs, jumpMs);
    if (renderMs > _maxRenderMs) _maxRenderMs = renderMs;
    if (_frameCount > 30) {
      _steadyFrames++;
      _steadyRenderMs += renderMs;
      if (renderMs > _steadyMaxMs) _steadyMaxMs = renderMs;
    }
    _presentedSinceLastTick = true;
    if (camera == null) return;

    // The latch model, keyed on completion arrival gaps: back-to-back
    // completions mean a busy pipeline (the engine latches a frame late);
    // an isolated completion after an idle gap is on screen this frame.
    final gap = _now - _lastArrival;
    _lastArrival = _now;
    if (presentLatencyFrames > 0 && gap < _pipelineBusy) {
      _pendingRenderedCameras.add(camera);
      while (_pendingRenderedCameras.length > presentLatencyFrames) {
        _lastRenderedCamera = _pendingRenderedCameras.removeAt(0);
      }
    } else {
      _pendingRenderedCameras.clear();
      _lastRenderedCamera = camera;
    }
  }

  static double? _ewma(double? prev, double value) =>
      prev == null ? value : prev * 0.8 + value * 0.2;

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  @override
  Map<String, Object?> diagnostics() {
    return <String, Object?>{
      ..._diagnostics,
      'frameCount': _frameCount,
      'cameraRenders': _cameraRenders,
      'linkRenders': _linkRenders,
      'skippedTicks': _skippedTicks,
      'cappedTicks': _cappedTicks,
      'idleEvents': _idleEvents,
      'needsRepaint': _needsRepaint,
      'drawCalls': _drawCalls,
      'superseded': _superseded,
      'rendersInFlight': _inFlight.length,
      'renderMsMax': _round2(_maxRenderMs),
      if (_steadyFrames > 0) ...{
        'renderMsAvgSteady': _round2(_steadyRenderMs / _steadyFrames),
        'renderMsMaxSteady': _round2(_steadyMaxMs),
      },
      if (_renderMs != null) 'renderMs': _round2(_renderMs!),
      if (_blitMs != null) 'blitMs': _round2(_blitMs!),
      if (_pumpMs != null) 'pumpMs': _round2(_pumpMs!),
      if (_jumpMs != null) 'jumpMs': _round2(_jumpMs!),
      if (_completionLagMs != null) ...{
        'completionLagMs': _round2(_completionLagMs!),
        'completionLagMsMax': _round2(_completionLagMsMax),
      },
    };
  }

  void _teardownLink() {
    _link?.postDestroy();
    _link = null;
    _ready = false;
    // Move the current port to "pending teardown" so a session started
    // after this one (a later create()) never shares it: this session's
    // DESTROYED (or the fallback below) can only ever close the port
    // captured here, never whatever [_port] holds by the time it arrives.
    // Any teardown already pending is closed first — at most one is ever
    // in flight, since create() closes it eagerly (see there).
    _closeTeardownPort();
    _teardownPort = _port;
    _port = null;
    // If DESTROYED never arrives (engine teardown races), don't leak the
    // port — an open ReceivePort pins the isolate.
    _portCloseFallback = Timer(const Duration(seconds: 2), _closeTeardownPort);
  }

  void _closeTeardownPort() {
    _portCloseFallback?.cancel();
    _portCloseFallback = null;
    _teardownPort?.close();
    _teardownPort = null;
  }

  @override
  void dispose() {
    _teardownLink();
    _createCompleter?.complete(false);
    _createCompleter = null;
    _resetSessionState();
  }
}
