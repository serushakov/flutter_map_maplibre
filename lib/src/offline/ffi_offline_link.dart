import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ffi/ffi_basemap_renderer.dart';
import '../ffi/maplibre_bindings.dart';
import '../ffi/mln_library.dart';
import 'offline_link.dart';
import 'offline_types.dart';

/// [OfflineLink] over the renderers' shared runtime (iOS topology; also the
/// sync-renderer path anywhere): every mln call happens on the Dart UI
/// thread, the runtime's owner thread. Holds one runtime user refcount from
/// [start] to [dispose], so an active download keeps the runtime alive after
/// the last map disposes.
///
/// Events arrive through [FfiBasemapRenderer.runtimeEventHook] — whichever
/// pump runs (a live renderer's tick or [pump] here) delivers them. All
/// native handles (operation results, snapshots, lists) are consumed inside
/// this file; only plain values leave.
class FfiOfflineLink implements OfflineLink {
  static final MaplibreBindings _b = MaplibreBindings(mlnLibrary);

  // ABI constants from the vendored headers (bindings generate enums as
  // ints; same convention as the renderers).
  static const _statusOk = 0;
  static const _evRegionStatus = 19; // ..._OFFLINE_REGION_STATUS_CHANGED
  static const _evRegionError = 20; // ..._OFFLINE_REGION_RESPONSE_ERROR
  static const _evTileLimit = 21; // ..._OFFLINE_REGION_TILE_COUNT_LIMIT_...
  static const _evOpCompleted = 22; // ..._OFFLINE_OPERATION_COMPLETED
  static const _defTilePyramid = 1; // ..._DEFINITION_TILE_PYRAMID
  static const _downloadActive = 1; // MLN_OFFLINE_REGION_DOWNLOAD_ACTIVE
  static const _downloadInactive = 0; // MLN_OFFLINE_REGION_DOWNLOAD_INACTIVE
  static const _ambientOpCode = {
    // MLN_AMBIENT_CACHE_OPERATION_*: RESET=1, PACK=2, (INVALIDATE=3), CLEAR=4
    AmbientCacheOp.reset: 1,
    AmbientCacheOp.pack: 2,
    AmbientCacheOp.clear: 4,
  };

  Pointer<mln_runtime> _runtime = nullptr;
  void Function(OfflineEvent event)? _onEvent;

  /// Native operation id → what to do when its completion event lands.
  final Map<int, _PendingOp> _pending = {};

  @override
  bool start(void Function(OfflineEvent event) onEvent) {
    if (_runtime != nullptr) return true;
    _runtime = FfiBasemapRenderer.acquireRuntimeUser();
    if (_runtime == nullptr) return false;
    _onEvent = onEvent;
    FfiBasemapRenderer.runtimeEventHook = _onRuntimeEvent;
    return true;
  }

  @override
  void createRegion({
    required int requestId,
    required OfflineRegionDefinition definition,
    required Uint8List metadata,
  }) {
    final styleNative = definition.styleUrl.toNativeUtf8();
    final def = calloc<mln_offline_region_definition>();
    def.ref.size = sizeOf<mln_offline_region_definition>();
    def.ref.type = _defTilePyramid;
    final tp = def.ref.data.tile_pyramid;
    tp.size = sizeOf<mln_offline_tile_pyramid_region_definition>();
    tp.style_url = styleNative.cast();
    tp.bounds.southwest.latitude = definition.south;
    tp.bounds.southwest.longitude = definition.west;
    tp.bounds.northeast.latitude = definition.north;
    tp.bounds.northeast.longitude = definition.east;
    tp.min_zoom = definition.minZoom;
    tp.max_zoom = definition.maxZoom;
    tp.pixel_ratio = definition.pixelRatio;
    tp.include_ideographs = definition.includeIdeographs;

    final metaNative = metadata.isEmpty
        ? nullptr
        : calloc<Uint8>(metadata.length);
    if (metadata.isNotEmpty) {
      metaNative.asTypedList(metadata.length).setAll(0, metadata);
    }
    final outOp = calloc<Uint64>();
    final status = _b.mln_runtime_offline_region_create_start(
      _runtime,
      def,
      metaNative,
      metadata.length,
      outOp,
    );
    _track(status, outOp.value, requestId, _OpKind.create);
    // Definition, style URL and metadata are copied during the call.
    calloc.free(def);
    calloc.free(styleNative);
    if (metaNative != nullptr) calloc.free(metaNative);
    calloc.free(outOp);
  }

  @override
  void setDownloadState({
    required int requestId,
    required int regionId,
    required bool active,
  }) {
    final outOp = calloc<Uint64>();
    final status = _b.mln_runtime_offline_region_set_download_state_start(
      _runtime,
      regionId,
      active ? _downloadActive : _downloadInactive,
      outOp,
    );
    _track(status, outOp.value, requestId, _OpKind.ack);
    calloc.free(outOp);
  }

  @override
  void setObserved({
    required int requestId,
    required int regionId,
    required bool observed,
  }) {
    final outOp = calloc<Uint64>();
    final status = _b.mln_runtime_offline_region_set_observed_start(
      _runtime,
      regionId,
      observed,
      outOp,
    );
    _track(status, outOp.value, requestId, _OpKind.ack);
    calloc.free(outOp);
  }

  @override
  void listRegions({required int requestId}) {
    final outOp = calloc<Uint64>();
    final status = _b.mln_runtime_offline_regions_list_start(_runtime, outOp);
    _track(status, outOp.value, requestId, _OpKind.list);
    calloc.free(outOp);
  }

  @override
  void deleteRegion({required int requestId, required int regionId}) {
    final outOp = calloc<Uint64>();
    final status = _b.mln_runtime_offline_region_delete_start(
      _runtime,
      regionId,
      outOp,
    );
    _track(status, outOp.value, requestId, _OpKind.delete);
    calloc.free(outOp);
  }

  @override
  void requestStatus({required int requestId, required int regionId}) {
    final outOp = calloc<Uint64>();
    final status = _b.mln_runtime_offline_region_get_status_start(
      _runtime,
      regionId,
      outOp,
    );
    _track(status, outOp.value, requestId, _OpKind.status, regionId: regionId);
    calloc.free(outOp);
  }

  @override
  void ambientOp({required int requestId, required AmbientCacheOp op}) {
    final outOp = calloc<Uint64>();
    final status = _b.mln_runtime_run_ambient_cache_operation_start(
      _runtime,
      _ambientOpCode[op]!,
      outOp,
    );
    _track(status, outOp.value, requestId, _OpKind.ambient);
    calloc.free(outOp);
  }

  @override
  void pump() => FfiBasemapRenderer.pumpSharedRuntime();

  @override
  void dispose() {
    if (_runtime == nullptr) return;
    for (final opId in _pending.keys) {
      _b.mln_runtime_offline_operation_discard(_runtime, opId);
    }
    _pending.clear();
    if (FfiBasemapRenderer.runtimeEventHook == _onRuntimeEvent) {
      FfiBasemapRenderer.runtimeEventHook = null;
    }
    _onEvent = null;
    _runtime = nullptr;
    FfiBasemapRenderer.releaseRuntimeUser();
  }

  void _track(
    int startStatus,
    int opId,
    int requestId,
    _OpKind kind, {
    int regionId = 0,
  }) {
    if (startStatus != _statusOk) {
      _emit(
        OfflineOperationFailed(
          requestId: requestId,
          message: '${kind.name} start failed with mln status $startStatus',
        ),
      );
      return;
    }
    _pending[opId] = _PendingOp(kind, requestId, regionId);
  }

  void _emit(OfflineEvent event) => _onEvent?.call(event);

  void _onRuntimeEvent(Pointer<mln_runtime_event> event) {
    // The event pointer is only valid during this call: decode to plain
    // values before anything asynchronous can happen.
    switch (event.ref.type) {
      case _evOpCompleted:
        final done = event.ref.payload
            .cast<mln_runtime_event_offline_operation_completed>()
            .ref;
        _onOpCompleted(done.operation_id, done.result_status);
      case _evRegionStatus:
        final payload = event.ref.payload
            .cast<mln_runtime_event_offline_region_status>()
            .ref;
        _emit(
          OfflineRegionStatusChanged(
            regionId: payload.region_id,
            progress: _progressFrom(payload.status),
          ),
        );
      case _evRegionError:
        final payload = event.ref.payload
            .cast<mln_runtime_event_offline_region_response_error>()
            .ref;
        _emit(
          OfflineRegionErrored(
            regionId: payload.region_id,
            message: 'resource response error (reason ${payload.reason})',
            isFatal: false,
          ),
        );
      case _evTileLimit:
        final payload = event.ref.payload
            .cast<mln_runtime_event_offline_region_tile_count_limit>()
            .ref;
        _emit(
          OfflineRegionErrored(
            regionId: payload.region_id,
            message: 'tile count limit ${payload.limit} reached',
            isFatal: true,
          ),
        );
      default:
        break;
    }
  }

  void _onOpCompleted(int opId, int resultStatus) {
    final op = _pending.remove(opId);
    if (op == null) return; // not ours (or discarded)
    if (resultStatus != _statusOk) {
      _emit(
        OfflineOperationFailed(
          requestId: op.requestId,
          message: '${op.kind.name} failed with mln status $resultStatus',
        ),
      );
      return;
    }
    switch (op.kind) {
      case _OpKind.create:
        _takeCreatedRegion(opId, op.requestId);
      case _OpKind.list:
        _takeRegionList(opId, op.requestId);
      case _OpKind.delete:
        _emit(OfflineRegionDeleted(requestId: op.requestId));
      case _OpKind.status:
        _takeStatus(opId, op.requestId, op.regionId);
      case _OpKind.ambient:
        _emit(OfflineAmbientOpCompleted(requestId: op.requestId));
      case _OpKind.ack:
        _emit(OfflineCommandAcknowledged(requestId: op.requestId));
    }
  }

  void _takeCreatedRegion(int opId, int requestId) {
    final outSnapshot = calloc<Pointer<mln_offline_region_snapshot>>();
    var status = _b.mln_runtime_offline_region_create_take_result(
      _runtime,
      opId,
      outSnapshot,
    );
    var regionId = 0;
    if (status == _statusOk) {
      final info = calloc<mln_offline_region_info>();
      info.ref.size = sizeOf<mln_offline_region_info>();
      status = _b.mln_offline_region_snapshot_get(outSnapshot.value, info);
      if (status == _statusOk) regionId = info.ref.id;
      _b.mln_offline_region_snapshot_destroy(outSnapshot.value);
      calloc.free(info);
    }
    calloc.free(outSnapshot);
    if (status != _statusOk) {
      _emit(
        OfflineOperationFailed(
          requestId: requestId,
          message: 'create take_result failed with mln status $status',
        ),
      );
      return;
    }
    _emit(OfflineRegionCreated(requestId: requestId, regionId: regionId));
  }

  void _takeRegionList(int opId, int requestId) {
    final outList = calloc<Pointer<mln_offline_region_list>>();
    var status = _b.mln_runtime_offline_regions_list_take_result(
      _runtime,
      opId,
      outList,
    );
    final records = <OfflineRegionRecord>[];
    if (status == _statusOk) {
      final list = outList.value;
      final outCount = calloc<Size>();
      status = _b.mln_offline_region_list_count(list, outCount);
      if (status == _statusOk) {
        final info = calloc<mln_offline_region_info>();
        for (var i = 0; i < outCount.value && status == _statusOk; i++) {
          info.ref.size = sizeOf<mln_offline_region_info>();
          status = _b.mln_offline_region_list_get(list, i, info);
          if (status != _statusOk) break;
          final record = _recordFrom(info.ref);
          if (record != null) records.add(record);
        }
        calloc.free(info);
      }
      calloc.free(outCount);
      _b.mln_offline_region_list_destroy(list);
    }
    calloc.free(outList);
    if (status != _statusOk) {
      _emit(
        OfflineOperationFailed(
          requestId: requestId,
          message: 'regions list failed with mln status $status',
        ),
      );
      return;
    }
    _emit(OfflineRegionList(requestId: requestId, regions: records));
  }

  void _takeStatus(int opId, int requestId, int regionId) {
    final outStatus = calloc<mln_offline_region_status>();
    outStatus.ref.size = sizeOf<mln_offline_region_status>();
    final status = _b.mln_runtime_offline_region_get_status_take_result(
      _runtime,
      opId,
      outStatus,
    );
    final progress = status == _statusOk ? _progressFrom(outStatus.ref) : null;
    calloc.free(outStatus);
    if (progress == null) {
      _emit(
        OfflineOperationFailed(
          requestId: requestId,
          message: 'get status failed with mln status $status',
        ),
      );
      return;
    }
    _emit(
      OfflineRegionStatusChanged(
        requestId: requestId,
        regionId: regionId,
        progress: progress,
      ),
    );
  }

  /// null for definition types this package never creates (geometry).
  OfflineRegionRecord? _recordFrom(mln_offline_region_info info) {
    if (info.definition.type != _defTilePyramid) return null;
    final tp = info.definition.data.tile_pyramid;
    return OfflineRegionRecord(
      regionId: info.id,
      definition: OfflineRegionDefinition(
        styleUrl: tp.style_url.cast<Utf8>().toDartString(),
        south: tp.bounds.southwest.latitude,
        west: tp.bounds.southwest.longitude,
        north: tp.bounds.northeast.latitude,
        east: tp.bounds.northeast.longitude,
        minZoom: tp.min_zoom,
        maxZoom: tp.max_zoom,
        pixelRatio: tp.pixel_ratio,
        includeIdeographs: tp.include_ideographs,
      ),
      metadata: info.metadata == nullptr || info.metadata_size == 0
          ? Uint8List(0)
          : Uint8List.fromList(info.metadata.asTypedList(info.metadata_size)),
    );
  }

  static OfflineRegionProgress _progressFrom(mln_offline_region_status s) =>
      OfflineRegionProgress(
        completedResources: s.completed_resource_count,
        requiredResources: s.required_resource_count,
        completedTiles: s.completed_tile_count,
        requiredTiles: s.required_tile_count,
        completedBytes: s.completed_resource_size,
        requiredIsPrecise: s.required_resource_count_is_precise,
        isComplete: s.complete,
        isDownloading: s.download_state == _downloadActive,
      );
}

enum _OpKind { create, list, delete, status, ambient, ack }

class _PendingOp {
  const _PendingOp(this.kind, this.requestId, this.regionId);

  final _OpKind kind;
  final int requestId;
  final int regionId;
}
