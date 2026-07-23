import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';

import '../basemap_renderer.dart';
import '../camera_conventions.dart';
import 'maplibre_bindings.dart';

// ABI constants from the vendored headers, kept local so the generated
// bindings' enum shape doesn't matter (ffigen generates enums as ints).
const _statusOk = 0; // MLN_STATUS_OK
const _eventMapIdle = 8; // MLN_RUNTIME_EVENT_MAP_IDLE
const _eventUpdateAvailable = 9; // ..._MAP_RENDER_UPDATE_AVAILABLE
const _eventFrameFinished = 14; // ..._MAP_RENDER_FRAME_FINISHED
const _cameraOptionCenter = 1 << 0; // MLN_CAMERA_OPTION_CENTER
const _cameraOptionZoom = 1 << 1; // MLN_CAMERA_OPTION_ZOOM
const _cameraOptionBearing = 1 << 2; // MLN_CAMERA_OPTION_BEARING
const _mapModeContinuous = 0; // MLN_MAP_MODE_CONTINUOUS

typedef _PresentNative = Double Function(Int64);

/// [BasemapRenderer] over maplibre_native_c via dart:ffi.
///
/// Every mln_* call happens on the thread that calls [create] — the C API is
/// owner-thread affine and returns MLN_STATUS_WRONG_THREAD otherwise, which
/// is exactly the enforcement the design wants: the whole renderer lives on
/// the Flutter UI thread.
class FfiBasemapRenderer implements BasemapRenderer {
  FfiBasemapRenderer();

  static final MaplibreBindings _b = MaplibreBindings(DynamicLibrary.process());
  static final double Function(int) _present = DynamicLibrary.process()
      .lookupFunction<_PresentNative, double Function(int)>('fmm_present');

  Pointer<mln_runtime> _runtime = nullptr;
  Pointer<mln_map> _map = nullptr;
  Pointer<mln_render_session> _session = nullptr;
  int _presenterId = -1;

  // Reused native scratch, allocated in create and freed in dispose.
  Pointer<mln_camera_options> _camera = nullptr;
  Pointer<mln_runtime_event> _event = nullptr;
  Pointer<Bool> _hasEvent = nullptr;
  Pointer<Pointer<mln_runtime>> _outRuntime = nullptr;
  Pointer<Pointer<mln_map>> _outMap = nullptr;
  Pointer<Pointer<mln_render_session>> _outSession = nullptr;

  MapCamera? _lastRenderedCamera;

  /// What jump_to last set — becomes [_lastRenderedCamera] once a render for
  /// it actually lands (a tick render after a failed camera render publishes
  /// this camera's content).
  MapCamera? _jumpedCamera;

  bool _updateAvailable = false;
  bool _needsRepaint = false;
  bool _renderedSinceLastTick = false;
  bool _idleSinceLastJump = false;

  final _diagnostics = <String, Object?>{};
  int _frameCount = 0;
  int _cameraRenders = 0;
  int _linkRenders = 0;
  int _skippedTicks = 0;
  int _idleEvents = 0;
  double _maxRenderMs = 0;
  int _steadyFrames = 0;
  double _steadyRenderMs = 0;
  double _steadyMaxMs = 0;
  double? _renderMsInline;
  double? _blitMs;
  int _drawCalls = 0;
  int _failStreak = 0;

  @override
  bool get isReady => _session != nullptr;

  @override
  MapCamera? get lastRenderedCamera => _lastRenderedCamera;

  @override
  bool get canSleep =>
      isReady &&
      decideSleep(
        idleSinceLastJump: _idleSinceLastJump,
        updateAvailable: _updateAvailable,
        needsRepaint: _needsRepaint,
        // Not identical means the last jump's render or present failed and
        // never landed in _lastRenderedCamera: the screen still shows the
        // old camera, so sleep stays vetoed until a later render publishes
        // it (see decideSleep's doc).
        unpublishedJump: !identical(_jumpedCamera, _lastRenderedCamera),
      );

  @override
  bool pumpWork() {
    if (!isReady) return false;
    _pumpEvents();
    return _updateAvailable || _needsRepaint;
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
    assert(!isReady, 'dispose before re-creating');
    _camera = calloc<mln_camera_options>();
    _event = calloc<mln_runtime_event>();
    _hasEvent = calloc<Bool>();
    _outRuntime = calloc<Pointer<mln_runtime>>();
    _outMap = calloc<Pointer<mln_map>>();
    _outSession = calloc<Pointer<mln_render_session>>();
    _presenterId = presenterId;

    final options = calloc<mln_runtime_options>();
    final cachePath = ':memory:'.toNativeUtf8();
    options.ref = _b.mln_runtime_options_default();
    options.ref.cache_path = cachePath.cast();
    final runtimeStatus = _b.mln_runtime_create(options, _outRuntime);
    calloc.free(options);
    calloc.free(cachePath); // "Copied during runtime creation."
    _diagnostics['runtimeCreateStatus'] = runtimeStatus;
    if (runtimeStatus != _statusOk) return _failCreate();
    _runtime = _outRuntime.value;

    final mapOptions = calloc<mln_map_options>();
    mapOptions.ref = _b.mln_map_options_default();
    mapOptions.ref.width = width;
    mapOptions.ref.height = height;
    mapOptions.ref.scale_factor = scale;
    mapOptions.ref.map_mode = _mapModeContinuous;
    final mapStatus = _b.mln_map_create(_runtime, mapOptions, _outMap);
    calloc.free(mapOptions);
    _diagnostics['mapCreateStatus'] = mapStatus;
    if (mapStatus != _statusOk) return _failCreate();
    _map = _outMap.value;

    final styleNative = styleUrl.toNativeUtf8();
    _diagnostics['setStyleStatus'] = _b.mln_map_set_style_url(
      _map,
      styleNative.cast(),
    );
    calloc.free(styleNative);
    _b.mln_map_request_repaint(_map);

    final descriptor = calloc<mln_metal_borrowed_texture_descriptor>();
    descriptor.ref = _b.mln_metal_borrowed_texture_descriptor_default();
    descriptor.ref.extent.width = width;
    descriptor.ref.extent.height = height;
    descriptor.ref.extent.scale_factor = scale;
    descriptor.ref.texture = Pointer<Void>.fromAddress(backTextureAddress);
    final attachStatus = _b.mln_metal_borrowed_texture_attach(
      _map,
      descriptor,
      _outSession,
    );
    calloc.free(descriptor);
    _diagnostics['attachStatus'] = attachStatus;
    if (attachStatus != _statusOk) return _failCreate();
    _session = _outSession.value;
    return true;
  }

  bool _failCreate() {
    dispose();
    return false;
  }

  static bool _sameCamera(MapCamera? a, MapCamera b) =>
      a != null &&
      a.center.latitude == b.center.latitude &&
      a.center.longitude == b.center.longitude &&
      a.zoom == b.zoom &&
      a.rotation == b.rotation;

  @override
  bool render(MapCamera camera) {
    if (!isReady) return false;
    // Already showing it: the settle condition, same role as the channel
    // era's sameCamera guard.
    if (_sameCamera(_lastRenderedCamera, camera)) return true;

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

    final clock = Stopwatch()..start();
    if (!_renderAndPresent()) return false;
    final ms = clock.elapsedMicroseconds / 1000.0;
    _renderMsInline = _renderMsInline == null
        ? ms
        : _renderMsInline! * 0.8 + ms * 0.2;

    _cameraRenders++;
    _renderedSinceLastTick = true;
    _lastRenderedCamera = camera;
    return true;
  }

  @override
  bool tick() {
    if (!isReady) return false;
    _pumpEvents();
    final decision = decideTick(
      updateAvailable: _updateAvailable,
      needsRepaint: _needsRepaint,
      renderedSinceLastTick: _renderedSinceLastTick,
    );
    _renderedSinceLastTick = false;
    switch (decision) {
      case TickDecision.skipIdle:
      case TickDecision.skipRenderedThisFrame:
        _skippedTicks++;
        return false;
      case TickDecision.render:
        if (!_renderAndPresent()) return false;
        _linkRenders++;
        // The content now on screen is whatever camera the map last jumped
        // to — which matters after a failed camera render, where this tick
        // is the retry that lands it.
        if (_jumpedCamera != null) _lastRenderedCamera = _jumpedCamera;
        return true;
    }
  }

  /// mln render (blocks until the GPU finishes) + blit-present. True only
  /// when both landed, so callers can treat it as "the front buffer changed".
  bool _renderAndPresent() {
    final clock = Stopwatch()..start();
    final status = _b.mln_render_session_render_update(_session);
    final elapsedMs = clock.elapsedMicroseconds / 1000.0;
    _diagnostics['lastRenderStatus'] = status;
    if (status != _statusOk) {
      _noteFailure('render_update status=$status');
      return false;
    }

    final blit = _present(_presenterId);
    if (blit < 0) {
      _diagnostics['presentError'] = blit;
      _noteFailure('present rc=$blit');
      return false;
    }
    // A recovered pipeline must not keep reporting the old failure.
    _diagnostics.remove('presentError');
    if (_failStreak > 0) {
      debugPrint('MLNERR recovered after streak=$_failStreak');
      _failStreak = 0;
      _diagnostics.remove('failStreak');
    }
    _blitMs = _blitMs == null ? blit : _blitMs! * 0.8 + blit * 0.2;

    _updateAvailable = false;
    _frameCount++;
    if (elapsedMs > _maxRenderMs) _maxRenderMs = elapsedMs;
    // First frames pay style load and tile upload; not steady state.
    if (_frameCount > 30) {
      _steadyFrames++;
      _steadyRenderMs += elapsedMs;
      if (elapsedMs > _steadyMaxMs) _steadyMaxMs = elapsedMs;
    }
    _diagnostics['renderMsLast'] = _round2(elapsedMs);
    return true;
  }

  /// Render failures are otherwise invisible on device — the widget silently
  /// falls back to the residual transform, and a sustained failure looks like
  /// the map vanishing. Surface the first failure of a streak, then every
  /// ~2s of a sustained one, with the failing call and its code.
  void _noteFailure(String what) {
    _failStreak++;
    _diagnostics['failStreak'] = _failStreak;
    if (_failStreak == 1 || _failStreak % 240 == 0) {
      debugPrint('MLNERR $what streak=$_failStreak');
    }
  }

  /// Drains the runtime event queue into flags. `_updateAvailable` is sticky:
  /// set here, cleared only by a successful render — per-tick clearing would
  /// lose updates that arrive while a render is skipped.
  void _pumpEvents() {
    _b.mln_runtime_run_once(_runtime);
    while (true) {
      _event.ref.size = sizeOf<mln_runtime_event>();
      _hasEvent.value = false;
      final status = _b.mln_runtime_poll_event(_runtime, _event, _hasEvent);
      if (status != _statusOk || !_hasEvent.value) break;
      switch (_event.ref.type) {
        case _eventUpdateAvailable:
          _updateAvailable = true;
        case _eventMapIdle:
          _idleEvents++;
          _idleSinceLastJump = true;
        case _eventFrameFinished:
          if (_event.ref.payload != nullptr &&
              _event.ref.payload_size >=
                  sizeOf<mln_runtime_event_render_frame>()) {
            final frame = _event.ref.payload
                .cast<mln_runtime_event_render_frame>()
                .ref;
            _needsRepaint = frame.needs_repaint;
            _drawCalls = frame.stats.draw_call_count;
          }
        default:
          break;
      }
    }
  }

  @override
  void setStyle(String styleUrl) {
    if (!isReady) return;
    final native = styleUrl.toNativeUtf8();
    _diagnostics['setStyleStatus'] = _b.mln_map_set_style_url(
      _map,
      native.cast(),
    );
    calloc.free(native);
    _b.mln_map_request_repaint(_map);
    _idleSinceLastJump = false;
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  @override
  Map<String, Object?> diagnostics() {
    return <String, Object?>{
      ..._diagnostics,
      'frameCount': _frameCount,
      'cameraRenders': _cameraRenders,
      'linkRenders': _linkRenders,
      'skippedTicks': _skippedTicks,
      'idleEvents': _idleEvents,
      'needsRepaint': _needsRepaint,
      'drawCalls': _drawCalls,
      'renderMsMax': _round2(_maxRenderMs),
      if (_steadyFrames > 0) ...{
        'renderMsAvgSteady': _round2(_steadyRenderMs / _steadyFrames),
        'renderMsMaxSteady': _round2(_steadyMaxMs),
      },
      if (_renderMsInline != null) 'renderMsInline': _round2(_renderMsInline!),
      if (_blitMs != null) 'blitMs': _round2(_blitMs!),
    };
  }

  @override
  void dispose() {
    if (_session != nullptr) {
      _b.mln_render_session_destroy(_session);
      _session = nullptr;
    }
    if (_map != nullptr) {
      _b.mln_map_destroy(_map);
      _map = nullptr;
    }
    if (_runtime != nullptr) {
      _b.mln_runtime_destroy(_runtime);
      _runtime = nullptr;
    }
    for (final pointer in <Pointer>[
      _camera,
      _event,
      _hasEvent,
      _outRuntime,
      _outMap,
      _outSession,
    ]) {
      if (pointer != nullptr) calloc.free(pointer);
    }
    _camera = nullptr;
    _event = nullptr;
    _hasEvent = nullptr;
    _outRuntime = nullptr;
    _outMap = nullptr;
    _outSession = nullptr;
    _lastRenderedCamera = null;
    _jumpedCamera = null;
    _idleSinceLastJump = false;
  }
}
