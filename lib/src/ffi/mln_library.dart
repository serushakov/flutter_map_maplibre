import 'dart:ffi';
import 'dart:io';

/// The library holding the maplibre_native_c and fmm_* symbols.
///
/// iOS statically links the xcframework into the app binary, so the symbols
/// are visible through the process image. On Android they live in
/// libmln_jni.so, which System.loadLibrary dlopens with RTLD_LOCAL —
/// invisible to DynamicLibrary.process() — so it is opened by name instead
/// (dlopen of an already-loaded library just bumps its refcount).
final DynamicLibrary mlnLibrary = Platform.isAndroid
    ? DynamicLibrary.open('libmln_jni.so')
    : DynamicLibrary.process();
