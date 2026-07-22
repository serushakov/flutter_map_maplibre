import Flutter
import UIKit

public class FlutterMapMaplibrePlugin: NSObject, FlutterPlugin {

  private let textures: FlutterTextureRegistry
  // Held so the texture outlives the call; the example app keeps showing it.
  private var probe: MetalProbe?
  private var textureId: Int64?

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_map_maplibre/probe",
      binaryMessenger: registrar.messenger())
    let instance = FlutterMapMaplibrePlugin(textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private var mapProbe: MapLibreProbe?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "runMap" {
      handleRunMap(call, result: result)
      return
    }
    if call.method == "mapDiagnostics" {
      result(mapProbe?.diagnostics ?? [String: Any]())
      return
    }
    guard call.method == "runProbe" else {
      result(FlutterMethodNotImplemented)
      return
    }

    let args = call.arguments as? [String: Any] ?? [:]
    let width = args["width"] as? Int ?? 0
    let height = args["height"] as? Int ?? 0

    guard let probe = MetalProbe(width: width, height: height) else {
      result([
        "ok": false,
        "error": "MetalProbe init failed",
        "diagnostics": [String: Any](),
      ])
      return
    }

    let cleared = probe.clearToRed()
    self.probe = probe

    var payload: [String: Any] = [
      "ok": cleared,
      "diagnostics": probe.diagnostics,
    ]

    if cleared {
      let id = textures.register(probe)
      textureId = id
      textures.textureFrameAvailable(id)
      payload["textureId"] = Int(id)
    } else {
      payload["error"] = probe.diagnostics["error"] as? String ?? "clearToRed failed"
    }

    result(payload)
  }

  /// Spike: render a real MapLibre map into a Flutter texture.
  private func handleRunMap(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let width = args["width"] as? Int ?? 512
    let height = args["height"] as? Int ?? 512
    let scale = args["scale"] as? Double ?? 2.0
    let styleURL =
      args["styleUrl"] as? String
      ?? "https://tiles.api.veduapp.com/styles/osm-liberty/style.json"

    guard
      let probe = MapLibreProbe(
        width: width, height: height, scale: scale, styleURL: styleURL)
    else {
      result([
        "ok": false,
        "error": "MapLibreProbe init failed",
        // The probe's own diagnostics die with the failed init, so the bridge
        // stashes them statically.
        "diagnostics": MLNBridge.lastFailureDiagnostics(),
      ])
      return
    }

    mapProbe = probe
    let id = textures.register(probe)
    probe.start { [weak self] in
      // Every rendered frame: tell Flutter the texture changed.
      self?.textures.textureFrameAvailable(id)
    }

    result([
      "ok": true,
      "textureId": Int(id),
      "diagnostics": probe.diagnostics,
    ])
  }

  /// Spike: read back the probe's diagnostics after it has been running.
  public func currentMapDiagnostics() -> [String: Any] {
    mapProbe?.diagnostics ?? [:]
  }
}
