package com.veduapp.flutter_map_maplibre

import android.view.Surface

/**
 * JNI surface over maplibre-native-ffi. Everything — EGL context, MapLibre
 * runtime, map and render session — lives in C++; Kotlin only drives the loop.
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

    /** Returns an opaque handle, or 0 on failure. */
    external fun nativeCreate(
        surface: Surface,
        width: Int,
        height: Int,
        scale: Double,
        styleUrl: String
    ): Long

    external fun nativeRender(handle: Long): Boolean

    external fun nativeSetCamera(
        handle: Long,
        lat: Double,
        lng: Double,
        zoom: Double,
        bearing: Double
    )

    external fun nativeSetStyle(handle: Long, styleUrl: String)

    external fun nativeFrameCount(handle: Long): Int

    external fun nativeSwapped(handle: Long): Int

    external fun nativeDestroy(handle: Long)
}
