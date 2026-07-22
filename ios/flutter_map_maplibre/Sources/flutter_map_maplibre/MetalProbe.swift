import CoreVideo
import Flutter
import Metal

/// Clears an IOSurface-backed CVPixelBuffer to solid red using Metal, and
/// vends that same buffer to Flutter.
///
/// The point is whether a CVMetalTextureCache-derived texture is usable as a
/// render target. If it is, MapLibre can draw straight into the buffer Flutter
/// samples — no copy anywhere in the pipeline.
class MetalProbe: NSObject, FlutterTexture {

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private var textureCache: CVMetalTextureCache?
  private var pixelBuffer: CVPixelBuffer?
  private var cvTexture: CVMetalTexture?
  private var target: MTLTexture?

  private(set) var diagnostics: [String: Any] = [:]

  init?(width: Int, height: Int) {
    guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue()
    else { return nil }
    self.device = device
    self.queue = queue
    super.init()

    diagnostics["deviceName"] = device.name

    let attrs: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]

    var buffer: CVPixelBuffer?
    let bufferStatus = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
    diagnostics["cvPixelBufferCreateStatus"] = Int(bufferStatus)
    guard bufferStatus == kCVReturnSuccess, let buffer else {
      diagnostics["error"] = "CVPixelBufferCreate failed: \(bufferStatus)"
      return nil
    }
    self.pixelBuffer = buffer

    // Zero-copy hinges on this: no IOSurface means no shared allocation.
    diagnostics["ioSurfaceBacked"] = CVPixelBufferGetIOSurface(buffer) != nil

    var cache: CVMetalTextureCache?
    let cacheStatus = CVMetalTextureCacheCreate(
      kCFAllocatorDefault, nil, device, nil, &cache)
    diagnostics["cvMetalTextureCacheCreateStatus"] = Int(cacheStatus)
    guard cacheStatus == kCVReturnSuccess, let cache else {
      diagnostics["error"] = "CVMetalTextureCacheCreate failed: \(cacheStatus)"
      return nil
    }
    self.textureCache = cache

    var cvTex: CVMetalTexture?
    let texStatus = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, cache, buffer, nil,
      .bgra8Unorm, width, height, 0, &cvTex)
    diagnostics["cvMetalTextureCreateStatus"] = Int(texStatus)
    guard texStatus == kCVReturnSuccess,
      let cvTex,
      let texture = CVMetalTextureGetTexture(cvTex)
    else {
      diagnostics["error"] =
        "CVMetalTextureCacheCreateTextureFromImage failed: \(texStatus)"
      return nil
    }
    self.cvTexture = cvTex
    self.target = texture

    // ---- THE LOAD-BEARING ASSERTION ----
    diagnostics["usageRenderTarget"] = texture.usage.contains(.renderTarget)
    diagnostics["usageShaderRead"] = texture.usage.contains(.shaderRead)
    diagnostics["pixelFormatIsBGRA8Unorm"] = texture.pixelFormat == .bgra8Unorm
    // ------------------------------------
  }

  /// Returns true if the clear was encoded and completed without error.
  func clearToRed() -> Bool {
    guard let target else {
      diagnostics["error"] = "no target texture"
      return false
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = target
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1)

    guard let commandBuffer = queue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    else {
      diagnostics["error"] = "failed to create command buffer or encoder"
      return false
    }

    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    if let error = commandBuffer.error {
      diagnostics["error"] = "command buffer error: \(error.localizedDescription)"
      return false
    }

    diagnostics["success"] = true
    return true
  }

  // MARK: FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let pixelBuffer else { return nil }
    // Despite the name, this hands over a retained reference — not a copy.
    return Unmanaged.passRetained(pixelBuffer)
  }
}
