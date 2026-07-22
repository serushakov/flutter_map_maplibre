package com.veduapp.flutter_map_maplibre

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class FlutterMapMaplibrePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry

    // Held so the texture survives past the probe call; the example app keeps
    // showing it. Throwaway probe code — no lifecycle management beyond this.
    private var producer: TextureRegistry.SurfaceProducer? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "flutter_map_maplibre/probe")
        channel.setMethodCallHandler(this)
        textureRegistry = binding.textureRegistry
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        if (call.method != "runProbe") {
            result.notImplemented()
            return
        }

        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0

        try {
            val surfaceProducer = textureRegistry.createSurfaceProducer()
            surfaceProducer.setSize(width, height)
            producer = surfaceProducer

            // Never cache this Surface: setSize may recreate the underlying
            // ImageReader, and a stale Surface renders silently black.
            val diagnostics = EglProbe().run(surfaceProducer.surface, width, height)
            val ok = diagnostics["success"] as? Boolean ?: false

            result.success(
                mapOf(
                    "ok" to ok,
                    "textureId" to if (ok) surfaceProducer.id() else null,
                    "error" to diagnostics["error"],
                    "diagnostics" to diagnostics
                )
            )
        } catch (e: Exception) {
            result.error("PROBE_THREW", e.message, null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        producer?.release()
        producer = null
    }
}
