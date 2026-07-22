import CoreVideo
import Flutter
import Metal
import QuartzCore

/// Spike: a real MapLibre map rendered into a Flutter-owned texture.
///
/// Deliberately crude. One texture (so tearing is possible), the FFI's
/// per-frame `waitUntilCompleted()` stall left in place, and everything on the
/// main thread. The question this answers is only "does a map appear", not
/// "is this fast" or "is this correct under load".
final class MapLibreProbe: NSObject, FlutterTexture {

  private let device: MTLDevice
  private var pixelBuffer: CVPixelBuffer?
  private var textureCache: CVMetalTextureCache?
  private var cvTexture: CVMetalTexture?
  private var target: MTLTexture?

  private var bridge: MLNBridge?

  private var displayLink: CADisplayLink?
  private var onFrame: (() -> Void)?

  private(set) var diagnostics: [String: Any] = [:]
  private(set) var frameCount: Int = 0

  init?(width: Int, height: Int, scale: Double, styleURL: String) {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    self.device = device
    super.init()

    diagnostics["deviceName"] = device.name

    // The extent passed to MapLibre is in *logical* pixels; the texture must be
    // sized in *physical* pixels, i.e. logical x scale_factor. Mismatching them
    // is an MLN_STATUS_INVALID_ARGUMENT (-1) on attach.
    let physicalWidth = Int((Double(width) * scale).rounded())
    let physicalHeight = Int((Double(height) * scale).rounded())

    guard makeTexture(width: physicalWidth, height: physicalHeight) else {
      return nil
    }
    guard makeMap(width: width, height: height, scale: scale, styleURL: styleURL)
    else { return nil }
  }

  // MARK: - GPU buffer (same contract the clear-to-red probe validated)

  private func makeTexture(width: Int, height: Int) -> Bool {
    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]
    var buffer: CVPixelBuffer?
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        attrs as CFDictionary, &buffer) == kCVReturnSuccess,
      let buffer
    else {
      diagnostics["error"] = "CVPixelBufferCreate failed"
      return false
    }
    pixelBuffer = buffer

    var cache: CVMetalTextureCache?
    guard
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        == kCVReturnSuccess, let cache
    else {
      diagnostics["error"] = "CVMetalTextureCacheCreate failed"
      return false
    }
    textureCache = cache

    var cvTex: CVMetalTexture?
    guard
      CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
        width, height, 0, &cvTex) == kCVReturnSuccess,
      let cvTex, let texture = CVMetalTextureGetTexture(cvTex)
    else {
      diagnostics["error"] = "CVMetalTextureCacheCreateTextureFromImage failed"
      return false
    }
    self.cvTexture = cvTex
    self.target = texture
    diagnostics["usageRenderTarget"] = texture.usage.contains(.renderTarget)
    return true
  }

  // MARK: - MapLibre

  private func makeMap(
    width: Int, height: Int, scale: Double, styleURL: String
  ) -> Bool {
    guard let target else { return false }
    guard
      let bridge = MLNBridge(
        width: Int32(width), height: Int32(height), scale: scale,
        styleURL: styleURL, texture: target)
    else {
      for (key, value) in MLNBridge.lastFailureDiagnostics() {
        diagnostics[key as String] = value
      }
      return false
    }
    self.bridge = bridge
    for (key, value) in bridge.diagnostics {
      diagnostics[key as String] = value
    }
    return true
  }

  // MARK: - Render loop

  func start(onFrame: @escaping () -> Void) {
    self.onFrame = onFrame
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  @objc private func tick() {
    guard let bridge else { return }
    if bridge.renderTick() {
      frameCount += 1
      onFrame?()
    }
    for (key, value) in bridge.diagnostics {
      diagnostics[key as String] = value
    }
  }

  func setCamera(
    latitude: Double, longitude: Double, zoom: Double, bearing: Double
  ) {
    bridge?.setCameraLatitude(
      latitude, longitude: longitude, zoom: zoom, bearing: bearing)
  }

  func setStyle(_ url: String) {
    bridge?.setStyleURL(url)
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    bridge?.shutdown()
    bridge = nil
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let pixelBuffer else { return nil }
    return Unmanaged.passRetained(pixelBuffer)
  }
}
