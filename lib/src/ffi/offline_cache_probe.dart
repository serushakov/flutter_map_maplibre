import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../cache_config.dart';
import 'ffi_basemap_renderer.dart';
import 'maplibre_bindings.dart';
import 'mln_library.dart';

/// Groundwork probe for the persistent-cache spec
/// (docs/superpowers/specs/2026-08-24-persistent-cache-and-offline-seeding.md).
///
/// Drives the offline-region machinery against the live shared runtime on
/// the UI thread — the topology the spec ended up requiring, since the mln
/// runtime is one-per-thread and a second one on the Dart main thread is
/// impossible. Reports every step so a simulator run can answer:
/// does a region create + download complete, do its events route cleanly
/// through the renderers' pump alongside map events, and does the database
/// grow on disk?
class OfflineCacheProbe {
  OfflineCacheProbe({required this.onUpdate});

  /// Fired after every state change with the accumulated probe facts.
  final void Function(Map<String, Object?> stats) onUpdate;

  static final MaplibreBindings _b = MaplibreBindings(mlnLibrary);

  // ABI constants from the vendored headers (same convention as the
  // renderers: bindings generate enums as ints).
  static const _statusOk = 0;
  static const _evRegionStatus = 19; // ..._OFFLINE_REGION_STATUS_CHANGED
  static const _evRegionError = 20; // ..._OFFLINE_REGION_RESPONSE_ERROR
  static const _evTileLimit = 21; // ..._OFFLINE_REGION_TILE_COUNT_LIMIT_...
  static const _evOpCompleted = 22; // ..._OFFLINE_OPERATION_COMPLETED
  static const _ambientInvalidate = 3; // MLN_AMBIENT_CACHE_OPERATION_INVALIDATE
  static const _downloadActive = 1; // MLN_OFFLINE_REGION_DOWNLOAD_ACTIVE
  static const _defTilePyramid = 1; // ..._DEFINITION_TILE_PYRAMID
  static const _networkOffline = 2; // MLN_NETWORK_STATUS_OFFLINE

  final Map<String, Object?> _stats = {};
  Timer? _timer;
  int _ambientOpId = 0;
  int _createOpId = 0;
  int _observeOpId = 0;
  int _activateOpId = 0;
  int _regionId = 0;

  /// Process-global: makes MapLibre's online source stop issuing requests,
  /// so a relaunch renders purely from the persisted cache. Callable before
  /// any runtime exists.
  static void forceOffline() {
    final status = _b.mln_network_status_set(_networkOffline);
    debugPrint('[cache-probe] network_status_set(OFFLINE) -> $status');
  }

  /// Starts the probe against the live shared runtime. Returns false when
  /// no runtime exists yet (build a map first).
  bool start({
    required String styleUrl,
    required double south,
    required double west,
    required double north,
    required double east,
    required double minZoom,
    required double maxZoom,
    required double pixelRatio,
  }) {
    final runtime = FfiBasemapRenderer.sharedRuntimeForProbe;
    if (runtime == nullptr) return false;
    FfiBasemapRenderer.runtimeEventHook = _onRuntimeEvent;

    _stats['db'] = MaplibreCache.databasePath;

    // Ambient-op smoke: proves the maintenance path accepts work and its
    // completion routes back through the hook.
    final outOp = calloc<Uint64>();
    var status = _b.mln_runtime_run_ambient_cache_operation_start(
      runtime,
      _ambientInvalidate,
      outOp,
    );
    _ambientOpId = outOp.value;
    _stats['ambientStart'] = status;

    // Region create: Tallinn tile pyramid, deliberately tiny.
    final styleNative = styleUrl.toNativeUtf8();
    final def = calloc<mln_offline_region_definition>();
    def.ref.size = sizeOf<mln_offline_region_definition>();
    def.ref.type = _defTilePyramid;
    final tp = def.ref.data.tile_pyramid;
    tp.size = sizeOf<mln_offline_tile_pyramid_region_definition>();
    tp.style_url = styleNative.cast();
    tp.bounds.southwest.latitude = south;
    tp.bounds.southwest.longitude = west;
    tp.bounds.northeast.latitude = north;
    tp.bounds.northeast.longitude = east;
    tp.min_zoom = minZoom;
    tp.max_zoom = maxZoom;
    tp.pixel_ratio = pixelRatio;
    tp.include_ideographs = false;
    status = _b.mln_runtime_offline_region_create_start(
      runtime,
      def,
      nullptr,
      0,
      outOp,
    );
    _createOpId = outOp.value;
    _stats['createStart'] = status;
    calloc.free(def);
    calloc.free(styleNative); // "Copied during region creation."
    calloc.free(outOp);

    // The map's ticker parks on idle, so the probe drives its own pump while
    // the download runs; DB file size is the on-disk truth of progress.
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      FfiBasemapRenderer.pumpSharedRuntimeForProbe();
      final db = File(MaplibreCache.databasePath);
      _stats['dbBytes'] = db.existsSync() ? db.lengthSync() : -1;
      onUpdate(Map.of(_stats));
    });
    onUpdate(Map.of(_stats));
    return true;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    FfiBasemapRenderer.runtimeEventHook = null;
  }

  void _onRuntimeEvent(Pointer<mln_runtime_event> event) {
    switch (event.ref.type) {
      case _evOpCompleted:
        final done = event.ref.payload
            .cast<mln_runtime_event_offline_operation_completed>()
            .ref;
        if (done.operation_id == _ambientOpId) {
          _stats['ambientDone'] = done.result_status;
        } else if (done.operation_id == _createOpId) {
          _stats['createDone'] = done.result_status;
          if (done.result_status == _statusOk) _takeRegionAndActivate();
        } else if (done.operation_id == _observeOpId) {
          _stats['observeDone'] = done.result_status;
        } else if (done.operation_id == _activateOpId) {
          _stats['activateDone'] = done.result_status;
        }
      case _evRegionStatus:
        final payload = event.ref.payload
            .cast<mln_runtime_event_offline_region_status>()
            .ref;
        _stats['tiles'] =
            '${payload.status.completed_tile_count}'
            '/${payload.status.required_tile_count}';
        _stats['resources'] = payload.status.completed_resource_count;
        _stats['regionBytes'] = payload.status.completed_resource_size;
        _stats['complete'] = payload.status.complete;
      case _evRegionError:
        final payload = event.ref.payload
            .cast<mln_runtime_event_offline_region_response_error>()
            .ref;
        _stats['regionError'] = payload.reason;
      case _evTileLimit:
        _stats['tileLimitHit'] = true;
      default:
        break;
    }
    onUpdate(Map.of(_stats));
  }

  /// Create completed: take the snapshot, read the region id, release the
  /// snapshot, then enable observation (status events are opt-in per
  /// region) and activate the download.
  void _takeRegionAndActivate() {
    final runtime = FfiBasemapRenderer.sharedRuntimeForProbe;
    final outSnapshot = calloc<Pointer<mln_offline_region_snapshot>>();
    var status = _b.mln_runtime_offline_region_create_take_result(
      runtime,
      _createOpId,
      outSnapshot,
    );
    if (status == _statusOk) {
      final info = calloc<mln_offline_region_info>();
      info.ref.size = sizeOf<mln_offline_region_info>();
      status = _b.mln_offline_region_snapshot_get(outSnapshot.value, info);
      if (status == _statusOk) _regionId = info.ref.id;
      _b.mln_offline_region_snapshot_destroy(outSnapshot.value);
      calloc.free(info);
    }
    _stats['takeResult'] = status;
    _stats['regionId'] = _regionId;
    calloc.free(outSnapshot);
    if (status != _statusOk) return;

    final outOp = calloc<Uint64>();
    _stats['observeStart'] = _b.mln_runtime_offline_region_set_observed_start(
      runtime,
      _regionId,
      true,
      outOp,
    );
    _observeOpId = outOp.value;
    _stats['activateStart'] = _b
        .mln_runtime_offline_region_set_download_state_start(
          runtime,
          _regionId,
          _downloadActive,
          outOp,
        );
    _activateOpId = outOp.value;
    calloc.free(outOp);
  }
}
