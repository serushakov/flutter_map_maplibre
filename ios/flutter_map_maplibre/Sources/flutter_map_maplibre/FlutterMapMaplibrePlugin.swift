import Flutter
import UIKit

public class FlutterMapMaplibrePlugin: NSObject, FlutterPlugin {

  private let textures: FlutterTextureRegistry
  // Held so the texture outlives the call; the example app keeps showing it.
  private var probe: MetalProbe?
  private var textureId: Int64?
  // Live presenters keyed by texture id — one per MapLibreBasemap.
  private var presenters: [Int64: TexturePresenter] = [:]

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
    if call.method == "createTextures" {
      let args = call.arguments as? [String: Any] ?? [:]
      let width = args["width"] as? Int ?? 0
      let height = args["height"] as? Int ?? 0
      let scale = args["scale"] as? Double ?? 2.0
      guard let presenter = TexturePresenter(width: width, height: height, scale: scale)
      else {
        result(["ok": false, "error": "TexturePresenter init failed"])
        return
      }
      let id = textures.register(presenter)
      presenters[id] = presenter
      PresenterRegistry.lock.lock()
      PresenterRegistry.entries[id] = (presenter, textures)
      PresenterRegistry.lock.unlock()
      let backAddress = Int64(
        Int(bitPattern: Unmanaged.passUnretained(presenter.backTexture as AnyObject).toOpaque()))
      result([
        "ok": true,
        "textureId": Int(id),
        "backTexture": backAddress,
        "diagnostics": presenter.diagnostics,
      ])
      return
    }
    if call.method == "disposeTextures" {
      let args = call.arguments as? [String: Any] ?? [:]
      if let id = (args["textureId"] as? NSNumber)?.int64Value {
        disposePresenter(id)
      }
      result(nil)
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

  private func disposePresenter(_ id: Int64) {
    guard presenters.removeValue(forKey: id) != nil else { return }
    PresenterRegistry.lock.lock()
    PresenterRegistry.entries.removeValue(forKey: id)
    PresenterRegistry.lock.unlock()
    textures.unregisterTexture(id)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    for id in Array(presenters.keys) { disposePresenter(id) }
  }
}
