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
    private var androidInitStatus: Int? = null

    // Held so the texture survives past the probe call; the example app keeps
    // showing it. Throwaway probe code — no lifecycle management beyond this.
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var renderer: MapLibreRenderer? = null

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
            "runProbe" -> handleRunProbe(call, result)
            "runMap" -> handleRunMap(call, result)
            "setCamera" -> {
                renderer?.setCamera(
                    call.argument<Double>("lat") ?: 0.0,
                    call.argument<Double>("lng") ?: 0.0,
                    call.argument<Double>("zoom") ?: 13.0,
                    call.argument<Double>("bearing") ?: 0.0
                )
                result.success(null)
            }
            "setStyle" -> {
                call.argument<String>("styleUrl")?.let { renderer?.setStyle(it) }
                result.success(null)
            }
            "mapDiagnostics" -> result.success(renderer?.diagnostics() ?: emptyMap<String, Any?>())
            "disposeMap" -> {
                renderer?.destroy()
                renderer = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Clear-to-red probe: validates the Flutter texture contract alone. */
    private fun handleRunProbe(call: MethodCall, result: MethodChannel.Result) {
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0

        try {
            val surfaceProducer = textureRegistry.createSurfaceProducer()
            surfaceProducer.setSize(width, height)
            producer = surfaceProducer

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

    private fun handleRunMap(call: MethodCall, result: MethodChannel.Result) {
        val width = call.argument<Int>("width") ?: 512
        val height = call.argument<Int>("height") ?: 512
        val scale = call.argument<Double>("scale") ?: 2.0
        val styleUrl = call.argument<String>("styleUrl")
            ?: "https://tiles.api.veduapp.com/styles/osm-liberty/style.json"

        // One basemap per plugin instance; replacing tears the old one down.
        renderer?.destroy()

        try {
            val created = MapLibreRenderer(textureRegistry) { id ->
                // Every rendered frame: tell Flutter the texture changed.
                // SurfaceProducer signals the engine itself, so this is a no-op
                // hook kept for symmetry with iOS.
            }
            renderer = created

            val ok = created.start(width, height, scale, styleUrl)
            if (!ok) {
                created.destroy()
                renderer = null
                result.success(
                    mapOf(
                        "ok" to false,
                        "error" to "nativeCreate returned 0",
                        "diagnostics" to emptyMap<String, Any?>()
                    )
                )
                return
            }

            result.success(
                mapOf(
                    "ok" to true,
                    "textureId" to created.textureId,
                    "diagnostics" to created.diagnostics() +
                        mapOf("androidInitStatus" to androidInitStatus)
                )
            )
        } catch (e: Throwable) {
            result.error("MAP_THREW", e.message, null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        renderer?.destroy()
        renderer = null
        producer?.release()
        producer = null
    }
}
