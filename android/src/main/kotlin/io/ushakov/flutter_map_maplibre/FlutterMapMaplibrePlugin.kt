package io.ushakov.flutter_map_maplibre

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import kotlin.math.roundToInt

/**
 * Cold path only: texture/presenter lifecycle. The hot path — camera pushes,
 * render_update, present — happens on the Dart UI thread via dart:ffi against
 * the presenter this class registers (see mln_jni.cpp).
 */
class FlutterMapMaplibrePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private var androidInitStatus: Int? = null

    /** One presenter per plugin instance, same as the iOS plugin. */
    private var producer: TextureRegistry.SurfaceProducer? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "flutter_map_maplibre/probe")
        channel.setMethodCallHandler(this)
        textureRegistry = binding.textureRegistry

        // Before any HTTP: the Rust/rustls stack needs the Android context to
        // reach the platform trust store. Skipping it leaves every tile request
        // failing TLS, which shows up as a map with only its background colour.
        androidInitStatus = MlnNative.nativeAndroidInit(binding.applicationContext)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        when (call.method) {
            "createTextures" -> handleCreateTextures(call, result)
            "disposeTextures" -> {
                disposePresenter()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleCreateTextures(call: MethodCall, result: MethodChannel.Result) {
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val scale = call.argument<Double>("scale") ?: 1.0

        // The widget recreates on resize; a stale presenter here is a leak.
        disposePresenter()

        try {
            val surfaceProducer = textureRegistry.createSurfaceProducer()
            surfaceProducer.setSize(
                (width * scale).roundToInt(),
                (height * scale).roundToInt()
            )
            val presenterId = surfaceProducer.id()

            val created = MlnNative.nativePresenterCreate(
                presenterId,
                surfaceProducer.surface,
                width,
                height,
                scale
            )
            if (created <= 0) {
                surfaceProducer.release()
                result.success(
                    mapOf(
                        "ok" to false,
                        "error" to "nativePresenterCreate step $created",
                        "diagnostics" to mapOf(
                            "presenterCreateStep" to created,
                            "androidInitStatus" to androidInitStatus
                        )
                    )
                )
                return
            }

            surfaceProducer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {}

                // Backgrounding etc. — the EGL window surface is dead. MVP:
                // fmm_present fails soft with kErrSurfaceLost and the Dart
                // failure-streak path surfaces it; in-place surface
                // recreation is a follow-up.
                override fun onSurfaceCleanup() {
                    MlnNative.nativePresenterInvalidate(presenterId)
                }
            })

            producer = surfaceProducer
            result.success(
                mapOf(
                    "ok" to true,
                    "textureId" to presenterId,
                    // GL texture name, not an address: Dart treats it as an
                    // opaque token on Android (fmm_attach holds the real
                    // handles natively).
                    "backTexture" to created,
                    "diagnostics" to mapOf(
                        "androidInitStatus" to androidInitStatus
                    )
                )
            )
        } catch (e: Throwable) {
            result.error("CREATE_TEXTURES_THREW", e.message, null)
        }
    }

    private fun disposePresenter() {
        producer?.let {
            MlnNative.nativePresenterDestroy(it.id())
            it.release()
        }
        producer = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        disposePresenter()
    }
}
