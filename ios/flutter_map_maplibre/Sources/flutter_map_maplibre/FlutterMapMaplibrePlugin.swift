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

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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
}
