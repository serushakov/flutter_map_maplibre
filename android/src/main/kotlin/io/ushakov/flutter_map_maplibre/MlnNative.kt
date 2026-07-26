package io.ushakov.flutter_map_maplibre

import android.view.Surface

/**
 * JNI surface over the native presenter half of the FFI architecture. Only
 * presenter lifecycle crosses JNI; every mln_* call happens on the Dart UI
 * thread via dart:ffi (fmm_attach / fmm_present in mln_jni.cpp).
 */
internal object MlnNative {

    init {
        System.loadLibrary("mln_jni")
    }

    /**
     * Must be called once before any map is created. The Rust HTTP stack needs
     * the Android context for TLS trust; without it tiles silently fail.
     */
    external fun nativeAndroidInit(context: Any): Int

    /**
     * Builds the EGL objects, GL back texture and blit program for one
     * presenter and registers it under [presenterId] (the Flutter texture id).
     * Returns the GL back-texture name (> 0), or a negative step code on
     * failure. Leaves the EGL context unbound — it becomes current on the
     * Dart UI thread.
     */
    external fun nativePresenterCreate(
        presenterId: Long,
        surface: Surface,
        width: Int,
        height: Int,
        scale: Double
    ): Long

    /** Marks the presenter's window surface dead; fmm_present starts failing soft. */
    external fun nativePresenterInvalidate(presenterId: Long)

    external fun nativePresenterDestroy(presenterId: Long)
}
