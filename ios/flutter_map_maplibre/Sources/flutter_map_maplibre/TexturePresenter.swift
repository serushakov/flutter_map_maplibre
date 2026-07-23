import CoreVideo
import Flutter
import Metal

/// Presentation half of the FFI renderer: the render session's fixed back
/// buffer plus a ring of 3 CVPixelBuffer-backed front buffers. All mln_*
/// calls live on the Dart side; this class only moves pixels and publishes
/// completed frames to Flutter.
///
/// Why a ring: the raster thread samples the front buffer whenever it
/// composites — possibly late. Publishing only completed, immutable buffers
/// (and never writing a published one until two presents later) is what kills
/// the composite race by construction (spec: "Immutable presentation").
final class TexturePresenter: NSObject, FlutterTexture {

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  /// The mln borrowed-texture target. Fixed for the session's lifetime.
  let backTexture: MTLTexture
  private var ring: [(buffer: CVPixelBuffer, texture: MTLTexture)] = []
  /// Index of the published buffer; -1 until the first present.
  private var frontIndex = -1
  private var nextIndex = 0
  /// copyPixelBuffer runs on the raster thread; present() on the UI thread.
  private let lock = NSLock()
  private(set) var diagnostics: [String: Any] = [:]

  init?(width: Int, height: Int, scale: Double) {
    guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue()
    else { return nil }
    self.device = device
    self.queue = queue

    let physicalWidth = Int((Double(width) * scale).rounded())
    let physicalHeight = Int((Double(height) * scale).rounded())

    let backDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: physicalWidth, height: physicalHeight, mipmapped: false)
    backDescriptor.usage = [.renderTarget, .shaderRead]
    backDescriptor.storageMode = .private
    guard let back = device.makeTexture(descriptor: backDescriptor) else {
      return nil
    }
    self.backTexture = back
    super.init()

    diagnostics["deviceName"] = device.name

    var cache: CVMetalTextureCache?
    guard
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        == kCVReturnSuccess, let cache
    else { return nil }

    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: physicalWidth,
      kCVPixelBufferHeightKey as String: physicalHeight,
    ]
    // Triple buffering: present writes slot N while the compositor may still
    // hold N-1; N-2 is guaranteed released by then.
    for _ in 0..<3 {
      var buffer: CVPixelBuffer?
      guard
        CVPixelBufferCreate(
          kCFAllocatorDefault, physicalWidth, physicalHeight,
          kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
          == kCVReturnSuccess, let buffer
      else { return nil }
      var cvTexture: CVMetalTexture?
      guard
        CVMetalTextureCacheCreateTextureFromImage(
          kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
          physicalWidth, physicalHeight, 0, &cvTexture) == kCVReturnSuccess,
        let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture)
      else { return nil }
      // The MTLTexture stays valid only while its parent CVMetalTexture
      // lives, so retain the CVMetalTexture alongside the pair.
      cvTextures.append(cvTexture)
      ring.append((buffer: buffer, texture: texture))
    }
  }

  private var cvTextures: [CVMetalTexture] = []

  /// Blit back → next ring slot and publish it. Returns blit wall-clock ms,
  /// or -1 on failure (nothing published).
  func present() -> Double {
    guard !ring.isEmpty,
      let command = queue.makeCommandBuffer(),
      let encoder = command.makeBlitCommandEncoder()
    else { return -1 }
    let started = CFAbsoluteTimeGetCurrent()
    encoder.copy(from: backTexture, to: ring[nextIndex].texture)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { return -1 }
    lock.lock()
    frontIndex = nextIndex
    lock.unlock()
    nextIndex = (nextIndex + 1) % ring.count
    return (CFAbsoluteTimeGetCurrent() - started) * 1000.0
  }

  /// Debug: clear the back buffer to a solid color (Checkpoint B's payload).
  func fill(red: Double, green: Double, blue: Double) -> Bool {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = backTexture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: red, green: green, blue: blue, alpha: 1)
    guard let command = queue.makeCommandBuffer(),
      let encoder = command.makeRenderCommandEncoder(descriptor: pass)
    else { return false }
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    return command.status == .completed
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard frontIndex >= 0 else { return nil }
    return Unmanaged.passRetained(ring[frontIndex].buffer)
  }
}

/// Global registry keyed by textureId, so the @_cdecl shims (called from Dart
/// via dart:ffi, no instance context) can reach the presenter and the texture
/// registry.
enum PresenterRegistry {
  static let lock = NSLock()
  static var entries: [Int64: (TexturePresenter, FlutterTextureRegistry)] = [:]

  static func get(_ id: Int64) -> (TexturePresenter, FlutterTextureRegistry)? {
    lock.lock()
    defer { lock.unlock() }
    return entries[id]
  }
}

/// FFI: blit + publish + tell Flutter the texture changed. Called from the
/// Dart UI thread immediately after a successful mln render. Returns blit ms,
/// or a negative value when the presenter is unknown or the blit failed.
@_cdecl("fmm_present")
public func fmm_present(_ presenterId: Int64) -> Double {
  guard let (presenter, textures) = PresenterRegistry.get(presenterId) else {
    return -2
  }
  let blitMs = presenter.present()
  if blitMs >= 0 {
    // Called from the UI thread, not the platform thread — Checkpoint B
    // verifies the engine picks this up for the current frame.
    textures.textureFrameAvailable(presenterId)
  }
  return blitMs
}

/// FFI, debug only: solid-color back buffer fill for Checkpoint B.
@_cdecl("fmm_debug_fill")
public func fmm_debug_fill(
  _ presenterId: Int64, _ red: Double, _ green: Double, _ blue: Double
) -> Int32 {
  guard let (presenter, _) = PresenterRegistry.get(presenterId) else {
    return -2
  }
  return presenter.fill(red: red, green: green, blue: blue) ? 0 : -1
}
