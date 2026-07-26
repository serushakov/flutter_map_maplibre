# Texture probe results

Date: 2026-07-22
Plan: `docs/superpowers/plans/2026-07-22-flutter-map-maplibre-probes.md`
Status: **both probes pass on emulated hardware. Physical-device runs still
outstanding.**

## Verdict

Both load-bearing assertions hold. A native GPU renderer can write into a
Flutter-owned texture on both platforms, and Flutter composites the result.

| Assertion | Platform | Result |
|---|---|---|
| `eglCreateWindowSurface` accepts Flutter's ImageReader surface | Android | **PASS** |
| `CVMetalTextureCache` texture is usable as a Metal render target | iOS | **PASS** |

This clears the gate the plan set. It does **not** yet clear the physical-device
bar — see caveats.

## iOS — Simulator (iPhone 17, iOS 26, Apple M3 host)

Screenshot: `packages/flutter_map_maplibre/probe-ios-simulator.png` — solid red
rectangle rendered as a `Texture` widget.

```
deviceName: Apple iOS simulator GPU
cvPixelBufferCreateStatus: 0
ioSurfaceBacked: true
cvMetalTextureCacheCreateStatus: 0
cvMetalTextureCreateStatus: 0
usageRenderTarget: true          <-- load-bearing
usageShaderRead: true
pixelFormatIsBGRA8Unorm: true
success: true
```

The full contract held: IOSurface-backed `CVPixelBuffer` allocation,
`CVMetalTextureCache` wrapping at BGRA8Unorm with no swizzle, a Metal render
pass targeting that texture, `copyPixelBuffer` vending a retained reference,
and the engine binding and compositing it.

`usageRenderTarget: true` is the important one — it is what makes the zero-copy
design possible. MapLibre can render directly into the buffer Flutter samples,
with no blit and no format conversion.

Incidental: the simulator's Metal host did **not** crash during these runs,
despite `SimMetalHost` having crash-looped earlier the same day (16:07–16:21).
The probe's workload is light; this is not evidence the earlier problem is
resolved.

## Android — Emulator (Pixel 6, API 33, Apple M3 host)

Screenshot: `packages/flutter_map_maplibre/probe-android-emulator.png` — solid
red rectangle rendered as a `Texture` widget.

```
eglVersion: 1.0
eglVendor: Android
eglSurfaceCreated: true                      <-- load-bearing
eglErrorAfterCreateWindowSurface: 12288      (0x3000 = EGL_SUCCESS)
glRenderer: Android Emulator OpenGL ES Translator (Apple M3)
glVersion: OpenGL ES 3.0 (4.1 Metal - 90.5)
eglSwapBuffers: true
glErrorAfterClear: 0
success: true
```

API 33 is above the API 29 threshold, so `createSurfaceProducer()` returned an
`ImageReaderSurfaceProducer` (`ImageFormat.PRIVATE`,
`HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE`) — the modern path, and the one whose
compatibility with `eglCreateWindowSurface` was the open question. It works.

Also incidental but useful: the example app ran under **Impeller (OpenGLES)**,
per `android_context_gl_impeller.cc` in logcat. So the path works on Impeller.
The host app runs Skia on Android; the Skia path is untested here, though the
research established that producer selection keys on API level rather than on
the renderer.

## Caveats — what this does not prove

**Both runs were on emulated GPUs backed by an Apple M3 host.** The Android
renderer string is literally `Android Emulator OpenGL ES Translator`, and the
iOS one is `Apple iOS simulator GPU`. Neither exercised a real mobile GPU
driver.

What remains genuinely unverified:

- Whether real Apple GPU drivers report `MTLTextureUsage.renderTarget` on a
  `CVMetalTextureCache`-derived texture. Likely — this is CoreVideo-level
  semantics, and simulators tend to be more restrictive rather than less — but
  unproven.
- Whether `eglCreateWindowSurface` succeeds against Flutter's ImageReader
  surface across the diversity of real Android GPU drivers (Adreno, Mali,
  Xclipse). This is the riskier of the two: driver-specific `ImageFormat.PRIVATE`
  handling is exactly where Android fragmentation bites.
- Anything about performance. These probes clear a buffer once. They say
  nothing about sustained 60fps, buffer rotation, synchronisation, or thermals.

## Next steps

1. Re-run both probes on physical hardware — an Android phone and an iPhone.
   Same command: `cd packages/flutter_map_maplibre/example && fvm flutter run`.
   The probe auto-runs on first frame; read the diagnostics off the screen.
2. If both still pass, the architecture decision becomes live: `maplibre-native-ffi`
   (right destination, unshipped, forces dropping `armeabi-v7a`) versus
   per-platform public API (`VirtualDisplay` + `Presentation` on Android, custom
   `mbgl::mtl::RenderableResource` on iOS).
3. The residual affine transform — pure Dart, unit-testable, architecture-
   independent — can be built in parallel with that decision.
