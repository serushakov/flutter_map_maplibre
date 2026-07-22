package com.veduapp.flutter_map_maplibre

import android.view.Choreographer
import io.flutter.view.TextureRegistry

/**
 * Owns a Flutter SurfaceProducer and drives the native render loop.
 *
 * Mirrors the iOS MapLibreProbe: one texture, no buffer rotation, everything on
 * the main thread. The FFI's runtime, map and render session are all owner-
 * thread affine, so the Choreographer callback is where they must be touched.
 */
internal class MapLibreRenderer(
    registry: TextureRegistry,
    private val onFrame: (Long) -> Unit
) : Choreographer.FrameCallback {

    private val producer: TextureRegistry.SurfaceProducer =
        registry.createSurfaceProducer()

    private var handle: Long = 0
    private var running = false

    val textureId: Long get() = producer.id()

    /** Returns false if the native side failed to initialise. */
    fun start(width: Int, height: Int, scale: Double, styleUrl: String): Boolean {
        producer.setSize((width * scale).toInt(), (height * scale).toInt())

        // Never cache this Surface: setSize may recreate the underlying
        // ImageReader, and a stale Surface renders silently black.
        handle = MlnNative.nativeCreate(
            producer.surface, width, height, scale, styleUrl
        )
        if (handle == 0L) return false

        running = true
        Choreographer.getInstance().postFrameCallback(this)
        return true
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!running || handle == 0L) return
        if (MlnNative.nativeRender(handle)) {
            onFrame(producer.id())
        }
        Choreographer.getInstance().postFrameCallback(this)
    }

    fun setCamera(lat: Double, lng: Double, zoom: Double, bearing: Double) {
        if (handle != 0L) MlnNative.nativeSetCamera(handle, lat, lng, zoom, bearing)
    }

    fun setStyle(styleUrl: String) {
        if (handle != 0L) MlnNative.nativeSetStyle(handle, styleUrl)
    }

    fun diagnostics(): Map<String, Any?> = mapOf(
        "frameCount" to if (handle != 0L) MlnNative.nativeFrameCount(handle) else 0,
        "backend" to "opengl-egl",
        "swapped" to if (handle != 0L) MlnNative.nativeSwapped(handle) else -2
    )

    fun destroy() {
        running = false
        Choreographer.getInstance().removeFrameCallback(this)
        if (handle != 0L) {
            MlnNative.nativeDestroy(handle)
            handle = 0
        }
        producer.release()
    }
}
