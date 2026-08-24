import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../cache_config.dart';
import '../ffi/mln_library.dart';
import 'offline_link.dart';
import 'offline_types.dart';

typedef _InitNative = IntPtr Function(Pointer<Void>);
typedef _StartNative = Int64 Function(Int64);
typedef _PostCreateNative = Void Function(Int64, Pointer<Utf8>, Uint64);
typedef _PostRegionCreateNative =
    Void Function(
      Int64,
      Int64,
      Pointer<Utf8>,
      Double,
      Double,
      Double,
      Double,
      Double,
      Double,
      Double,
      Int32,
      Pointer<Uint8>,
      IntPtr,
    );
typedef _PostFlagNative = Void Function(Int64, Int64, Int64, Int32);
typedef _PostReqNative = Void Function(Int64, Int64);
typedef _PostReqRegionNative = Void Function(Int64, Int64, Int64);
typedef _PostAmbientNative = Void Function(Int64, Int64, Uint32);
typedef _PostVoidNative = Void Function(Int64);

/// [OfflineLink] over the fmm offline worker (Android): a dedicated
/// map-less owner thread with its own mln runtime, sharing the SQLite
/// database file with the render workers. Commands post over FFI; typed
/// completions arrive on a NativePort — the same protocol discipline as
/// `WorkerLink`, with the worker consuming every native handle on its own
/// thread. The worker self-pumps at 50ms while operations are in flight,
/// so [pump] here is just a nudge.
class WorkerOfflineLink implements OfflineLink {
  // Completion kinds — first element of every message. Mirrors
  // fmm_worker.cpp's kOffline* block; keep in sync.
  static const _kCreated = 100;
  static const _kRegionCreated = 101;
  static const _kAck = 102;
  static const _kList = 103;
  static const _kStatus = 104;
  static const _kDeleted = 105;
  static const _kAmbientDone = 106;
  static const _kRegionError = 107;
  static const _kDestroyed = 108;

  static const _ambientOpCode = {
    // MLN_AMBIENT_CACHE_OPERATION_*: RESET=1, PACK=2, (INVALIDATE=3), CLEAR=4
    AmbientCacheOp.reset: 1,
    AmbientCacheOp.pack: 2,
    AmbientCacheOp.clear: 4,
  };

  static final int Function(Pointer<Void>) _init = mlnLibrary
      .lookupFunction<_InitNative, int Function(Pointer<Void>)>(
        'fmm_dart_init',
      );
  static final int Function(int) _start = mlnLibrary
      .lookupFunction<_StartNative, int Function(int)>('fmm_offline_start');
  static final void Function(int, Pointer<Utf8>, int) _postCreate = mlnLibrary
      .lookupFunction<
        _PostCreateNative,
        void Function(int, Pointer<Utf8>, int)
      >('fmm_offline_post_create');
  static final void Function(
    int,
    int,
    Pointer<Utf8>,
    double,
    double,
    double,
    double,
    double,
    double,
    double,
    int,
    Pointer<Uint8>,
    int,
  )
  _postRegionCreate = mlnLibrary
      .lookupFunction<
        _PostRegionCreateNative,
        void Function(
          int,
          int,
          Pointer<Utf8>,
          double,
          double,
          double,
          double,
          double,
          double,
          double,
          int,
          Pointer<Uint8>,
          int,
        )
      >('fmm_offline_post_region_create');
  static final void Function(int, int, int, int) _postSetObserved = mlnLibrary
      .lookupFunction<_PostFlagNative, void Function(int, int, int, int)>(
        'fmm_offline_post_set_observed',
      );
  static final void Function(int, int, int, int) _postSetDownloadState =
      mlnLibrary
          .lookupFunction<_PostFlagNative, void Function(int, int, int, int)>(
            'fmm_offline_post_set_download_state',
          );
  static final void Function(int, int) _postList = mlnLibrary
      .lookupFunction<_PostReqNative, void Function(int, int)>(
        'fmm_offline_post_list',
      );
  static final void Function(int, int, int) _postDelete = mlnLibrary
      .lookupFunction<_PostReqRegionNative, void Function(int, int, int)>(
        'fmm_offline_post_delete',
      );
  static final void Function(int, int, int) _postGetStatus = mlnLibrary
      .lookupFunction<_PostReqRegionNative, void Function(int, int, int)>(
        'fmm_offline_post_get_status',
      );
  static final void Function(int, int, int) _postAmbient = mlnLibrary
      .lookupFunction<_PostAmbientNative, void Function(int, int, int)>(
        'fmm_offline_post_ambient',
      );
  static final void Function(int) _postPump = mlnLibrary
      .lookupFunction<_PostVoidNative, void Function(int)>(
        'fmm_offline_post_pump',
      );
  static final void Function(int) _postDestroy = mlnLibrary
      .lookupFunction<_PostVoidNative, void Function(int)>(
        'fmm_offline_post_destroy',
      );

  static bool? _dartApiReady;

  int _worker = 0;
  ReceivePort? _port;
  void Function(OfflineEvent event)? _onEvent;

  @override
  bool start(void Function(OfflineEvent event) onEvent) {
    if (_worker != 0) return true;
    try {
      _dartApiReady ??= _init(NativeApi.initializeApiDLData) == 0;
    } on ArgumentError {
      // The offline worker ships in the Android native library only.
      _dartApiReady = false;
    }
    if (!_dartApiReady!) return false;
    final port = ReceivePort();
    _worker = _start(port.sendPort.nativePort);
    if (_worker == 0) {
      port.close();
      return false;
    }
    _onEvent = onEvent;
    _port = port..listen(_onMessage);
    final cachePath = MaplibreCache.databasePath.toNativeUtf8();
    _postCreate(_worker, cachePath, MaplibreCache.maxAmbientBytes ?? 0);
    calloc.free(cachePath); // copied on this thread
    MaplibreCache.markRuntimeCreated();
    return true;
  }

  @override
  void createRegion({
    required int requestId,
    required OfflineRegionDefinition definition,
    required Uint8List metadata,
  }) {
    final styleUrl = definition.styleUrl.toNativeUtf8();
    final metaNative = metadata.isEmpty
        ? Pointer<Uint8>.fromAddress(0)
        : calloc<Uint8>(metadata.length);
    if (metadata.isNotEmpty) {
      metaNative.asTypedList(metadata.length).setAll(0, metadata);
    }
    _postRegionCreate(
      _worker,
      requestId,
      styleUrl,
      definition.south,
      definition.west,
      definition.north,
      definition.east,
      definition.minZoom,
      definition.maxZoom,
      definition.pixelRatio,
      definition.includeIdeographs ? 1 : 0,
      metaNative,
      metadata.length,
    );
    calloc.free(styleUrl); // both copied on this thread
    if (metadata.isNotEmpty) calloc.free(metaNative);
  }

  @override
  void setObserved({
    required int requestId,
    required int regionId,
    required bool observed,
  }) => _postSetObserved(_worker, requestId, regionId, observed ? 1 : 0);

  @override
  void setDownloadState({
    required int requestId,
    required int regionId,
    required bool active,
  }) => _postSetDownloadState(_worker, requestId, regionId, active ? 1 : 0);

  @override
  void listRegions({required int requestId}) => _postList(_worker, requestId);

  @override
  void deleteRegion({required int requestId, required int regionId}) =>
      _postDelete(_worker, requestId, regionId);

  @override
  void requestStatus({required int requestId, required int regionId}) =>
      _postGetStatus(_worker, requestId, regionId);

  @override
  void ambientOp({required int requestId, required AmbientCacheOp op}) =>
      _postAmbient(_worker, requestId, _ambientOpCode[op]!);

  @override
  void pump() {
    if (_worker != 0) _postPump(_worker);
  }

  @override
  void dispose() {
    if (_worker == 0) return;
    _postDestroy(_worker);
    _worker = 0;
    _port?.close();
    _port = null;
    _onEvent = null;
  }

  void _emit(OfflineEvent event) => _onEvent?.call(event);

  void _onMessage(dynamic raw) {
    final message = raw as List<dynamic>;
    switch (message[0] as int) {
      case _kCreated:
        // A failed runtime create has no request to fail; every subsequent
        // command answers with kErrNoRuntime, which the facade surfaces.
        break;
      case _kRegionCreated:
        final requestId = message[1] as int;
        final status = message[2] as int;
        if (status != 0) {
          _emit(
            OfflineOperationFailed(
              requestId: requestId,
              message: 'create failed with mln status $status',
            ),
          );
        } else {
          _emit(
            OfflineRegionCreated(
              requestId: requestId,
              regionId: message[3] as int,
            ),
          );
        }
      case _kAck:
        final requestId = message[1] as int;
        final status = message[2] as int;
        _emit(
          status == 0
              ? OfflineCommandAcknowledged(requestId: requestId)
              : OfflineOperationFailed(
                  requestId: requestId,
                  message: 'command failed with mln status $status',
                ),
        );
      case _kList:
        _onListMessage(message);
      case _kStatus:
        final requestId = message[1] as int;
        _emit(
          OfflineRegionStatusChanged(
            requestId: requestId == 0 ? null : requestId,
            regionId: message[2] as int,
            progress: OfflineRegionProgress(
              isDownloading: (message[3] as int) == 1,
              completedResources: message[4] as int,
              completedBytes: message[5] as int,
              completedTiles: message[6] as int,
              requiredTiles: message[7] as int,
              requiredResources: message[8] as int,
              requiredIsPrecise: (message[9] as int) != 0,
              isComplete: (message[10] as int) != 0,
            ),
          ),
        );
      case _kDeleted:
        final requestId = message[1] as int;
        final status = message[2] as int;
        _emit(
          status == 0
              ? OfflineRegionDeleted(requestId: requestId)
              : OfflineOperationFailed(
                  requestId: requestId,
                  message: 'delete failed with mln status $status',
                ),
        );
      case _kAmbientDone:
        final requestId = message[1] as int;
        final status = message[2] as int;
        _emit(
          status == 0
              ? OfflineAmbientOpCompleted(requestId: requestId)
              : OfflineOperationFailed(
                  requestId: requestId,
                  message: 'ambient op failed with mln status $status',
                ),
        );
      case _kRegionError:
        _emit(
          OfflineRegionErrored(
            regionId: message[1] as int,
            isFatal: (message[2] as int) != 0,
            message: message[3] as String,
          ),
        );
      case _kDestroyed:
        break;
    }
  }

  void _onListMessage(List<dynamic> message) {
    final requestId = message[1] as int;
    final status = message[2] as int;
    if (status != 0) {
      _emit(
        OfflineOperationFailed(
          requestId: requestId,
          message: 'regions list failed with mln status $status',
        ),
      );
      return;
    }
    final count = message[3] as int;
    final records = <OfflineRegionRecord>[];
    for (var i = 0; i < count; i++) {
      final base = 4 + i * 11;
      records.add(
        OfflineRegionRecord(
          regionId: message[base] as int,
          definition: OfflineRegionDefinition(
            styleUrl: message[base + 1] as String,
            south: message[base + 2] as double,
            west: message[base + 3] as double,
            north: message[base + 4] as double,
            east: message[base + 5] as double,
            minZoom: message[base + 6] as double,
            maxZoom: message[base + 7] as double,
            pixelRatio: message[base + 8] as double,
            includeIdeographs: (message[base + 9] as int) != 0,
          ),
          metadata: message[base + 10] as Uint8List,
        ),
      );
    }
    _emit(OfflineRegionList(requestId: requestId, regions: records));
  }
}
