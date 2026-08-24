import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'mln_library.dart';

typedef _InitNative = IntPtr Function(Pointer<Void>);
typedef _StartNative = Int64 Function(Int64);
typedef _PostCreateNative =
    Void Function(
      Int64,
      Int32,
      Int32,
      Double,
      Pointer<Utf8>,
      Int64,
      Pointer<Utf8>,
      Uint64,
    );
typedef _PostVoidNative = Void Function(Int64);
typedef _PostJumpNative =
    Void Function(Int64, Double, Double, Double, Double, Int64);
typedef _PostRenderNative = Void Function(Int64, Int64);
typedef _PostStyleNative = Void Function(Int64, Pointer<Utf8>);

/// The command side of the worker protocol, injectable so the facade's
/// state machine is testable without native code. Cameras arrive here
/// already converted to mln conventions (raw doubles): the link is dumb.
abstract interface class WorkerLink {
  /// Starts a fresh worker posting completions to [completions].
  /// Returns false when the native side is unavailable (init failed).
  bool start(SendPort completions);

  void postCreate({
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
    required int presenterId,
    required String cachePath,
    required int maxCacheBytes,
  });
  void postPump();
  void postJump({
    required double lat,
    required double lng,
    required double zoom,
    required double bearing,
    required int gen,
  });
  void postRender(int gen);
  void postSetStyle(String url);

  /// After this the worker frees itself once the queue drains; this link
  /// instance must not be posted to again (the facade starts a fresh link
  /// per session).
  void postDestroy();
}

/// dart:ffi implementation over fmm_worker_* (Android only).
class FfiWorkerLink implements WorkerLink {
  static final int Function(Pointer<Void>) _init = mlnLibrary
      .lookupFunction<_InitNative, int Function(Pointer<Void>)>(
        'fmm_dart_init',
      );
  static final int Function(int) _start = mlnLibrary
      .lookupFunction<_StartNative, int Function(int)>('fmm_worker_start');
  static final void Function(
    int,
    int,
    int,
    double,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    int,
  )
  _postCreate = mlnLibrary
      .lookupFunction<
        _PostCreateNative,
        void Function(
          int,
          int,
          int,
          double,
          Pointer<Utf8>,
          int,
          Pointer<Utf8>,
          int,
        )
      >('fmm_worker_post_create');
  static final void Function(int) _postPump = mlnLibrary
      .lookupFunction<_PostVoidNative, void Function(int)>(
        'fmm_worker_post_pump',
      );
  static final void Function(int, double, double, double, double, int)
  _postJump = mlnLibrary
      .lookupFunction<
        _PostJumpNative,
        void Function(int, double, double, double, double, int)
      >('fmm_worker_post_jump');
  static final void Function(int, int) _postRender = mlnLibrary
      .lookupFunction<_PostRenderNative, void Function(int, int)>(
        'fmm_worker_post_render',
      );
  static final void Function(int, Pointer<Utf8>) _postStyle = mlnLibrary
      .lookupFunction<_PostStyleNative, void Function(int, Pointer<Utf8>)>(
        'fmm_worker_post_set_style',
      );
  static final void Function(int) _postDestroy = mlnLibrary
      .lookupFunction<_PostVoidNative, void Function(int)>(
        'fmm_worker_post_destroy',
      );

  static bool? _dartApiReady;

  int _worker = 0;

  @override
  bool start(SendPort completions) {
    try {
      _dartApiReady ??= _init(NativeApi.initializeApiDLData) == 0;
    } on ArgumentError {
      // fmm_dart_init is not in this binary — the worker ships on Android
      // only. Fail soft (workerStartFailed) like any other native
      // unavailability instead of an unhandled lookup throw.
      _dartApiReady = false;
    }
    if (!_dartApiReady!) return false;
    _worker = _start(completions.nativePort);
    return _worker != 0;
  }

  @override
  void postCreate({
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
    required int presenterId,
    required String cachePath,
    required int maxCacheBytes,
  }) {
    final url = styleUrl.toNativeUtf8();
    final cache = cachePath.toNativeUtf8();
    _postCreate(
      _worker,
      width,
      height,
      scale,
      url,
      presenterId,
      cache,
      maxCacheBytes,
    );
    calloc.free(url); // the worker copied both on this thread
    calloc.free(cache);
  }

  @override
  void postPump() => _postPump(_worker);

  @override
  void postJump({
    required double lat,
    required double lng,
    required double zoom,
    required double bearing,
    required int gen,
  }) => _postJump(_worker, lat, lng, zoom, bearing, gen);

  @override
  void postRender(int gen) => _postRender(_worker, gen);

  @override
  void postSetStyle(String url) {
    final native = url.toNativeUtf8();
    _postStyle(_worker, native);
    calloc.free(native);
  }

  @override
  void postDestroy() => _postDestroy(_worker);
}
