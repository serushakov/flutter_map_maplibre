# flutter_map_maplibre — Texture Probes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove or disprove, in about a day, that a native renderer can write into a Flutter-owned GPU texture on both iOS and Android — the single assumption every version of the native-basemap design depends on.

**Architecture:** Two independent probes in a new standalone package. Each allocates a Flutter-registered texture, has native code clear it to a solid colour via the platform's GPU API, and displays it in a `Texture` widget. **No MapLibre.** Native reports structured diagnostics back over a method channel, so the result is a machine-checkable fact rather than "it looked red."

**Tech Stack:** Flutter 3.44.5 (fvm), Kotlin + EGL14/GLES20 on Android, Swift + Metal/CoreVideo on iOS.

## Global Constraints

- Flutter is pinned to **3.44.5** via fvm. Every Flutter/Dart command is prefixed `fvm`.
- The package has **zero dependencies on Vedu app code**. It must build and run standalone.
- After editing any `.dart` file, run `fvm dart format <paths>` — the editor formats on save and the repo must match.
- Package name is `flutter_map_maplibre`, following the `flutter_map_<capability>` ecosystem convention.
- **The iOS probe MUST be verified on a physical device, not the simulator.** The simulator's `SimMetalHost` XPC service is currently crash-looping on this machine (see `Runner.crash` / `WidgetRender.crash`, 2026-07-22); a simulator failure would be indistinguishable from a probe failure.
- Probes are **throwaway**. Do not build abstractions, do not design a public API, do not add caching or lifecycle robustness beyond what is needed to observe the result.

## Why these two probes

Both research passes independently converged on the same load-bearing unknowns:

- **Android:** does `eglCreateWindowSurface` succeed on Flutter's `ImageFormat.PRIVATE` ImageReader surface? Mechanically it should — `ImageFormat.PRIVATE` exists precisely so the producer chooses the format — but it is unverified, and it is the assumption *every* Android architecture rests on (direct renderer, VirtualDisplay, and maplibre-native-ffi all ultimately call it).
- **iOS:** does a texture from `CVMetalTextureCacheCreateTextureFromImage` over an IOSurface-backed `CVPixelBuffer` report `MTLTextureUsage.renderTarget`? If not, MapLibre cannot render into it directly and the zero-copy design degrades to a blit plus a format-conversion pass.

Neither question involves MapLibre. Answering them first is the cheapest possible way to kill the project if it deserves killing.

## File Structure

```
packages/flutter_map_maplibre/
  pubspec.yaml                                    package metadata, plugin platform declarations
  lib/flutter_map_maplibre.dart                   public export
  lib/src/probe.dart                              TextureProbe + ProbeResult — method channel client
  test/probe_test.dart                            unit tests for the channel client
  android/src/main/kotlin/.../FlutterMapMaplibrePlugin.kt   channel + SurfaceProducer wiring
  android/src/main/kotlin/.../EglProbe.kt         EGL surface creation, clear, diagnostics
  ios/Classes/FlutterMapMaplibrePlugin.swift      channel + FlutterTextureRegistry wiring
  ios/Classes/MetalProbe.swift                    CVPixelBuffer + Metal clear, FlutterTexture impl
  example/lib/main.dart                           probe harness UI
```

Split rationale: the channel/registry plumbing and the graphics code have different reasons to change and different failure modes. Keeping the graphics isolated means the probe result is attributable to one file.

---

### Task 1: Package scaffold and the Dart probe client

**Files:**
- Create: `packages/flutter_map_maplibre/` (via `flutter create`)
- Create: `packages/flutter_map_maplibre/lib/src/probe.dart`
- Create: `packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart`
- Test: `packages/flutter_map_maplibre/test/probe_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `class ProbeResult { final bool ok; final int? textureId; final String? error; final Map<String, Object?> diagnostics; }`
  - `class TextureProbe { static const MethodChannel channel; Future<ProbeResult> run({required int width, required int height}); }`
  - Method channel name: `flutter_map_maplibre/probe`, method `runProbe`, arguments `{'width': int, 'height': int}`.
  - Native returns a `Map` with keys `ok` (bool), `textureId` (int, absent on failure), `error` (String, absent on success), `diagnostics` (Map).

- [ ] **Step 1: Create the package**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client
fvm flutter create --template=plugin --platforms=android,ios \
  -a kotlin -i swift \
  --org com.veduapp --project-name flutter_map_maplibre \
  packages/flutter_map_maplibre
```

Expected: a plugin package with `android/`, `ios/`, `example/`, and generated boilerplate.

- [ ] **Step 2: Write the failing test**

Create `packages/flutter_map_maplibre/test/probe_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map_maplibre/src/probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(TextureProbe.channel, null);
  });

  test('parses a successful probe response', () async {
    late MethodCall received;
    messenger.setMockMethodCallHandler(TextureProbe.channel, (call) async {
      received = call;
      return <String, Object?>{
        'ok': true,
        'textureId': 7,
        'diagnostics': <String, Object?>{'usageRenderTarget': true},
      };
    });

    final result = await TextureProbe().run(width: 64, height: 32);

    expect(received.method, 'runProbe');
    expect(received.arguments, <String, Object?>{'width': 64, 'height': 32});
    expect(result.ok, isTrue);
    expect(result.textureId, 7);
    expect(result.error, isNull);
    expect(result.diagnostics['usageRenderTarget'], isTrue);
  });

  test('parses a failed probe response', () async {
    messenger.setMockMethodCallHandler(TextureProbe.channel, (call) async {
      return <String, Object?>{
        'ok': false,
        'error': 'eglCreateWindowSurface returned EGL_NO_SURFACE',
        'diagnostics': <String, Object?>{
          'eglSurfaceCreated': false,
          'eglErrorAfterCreateWindowSurface': 12291,
        },
      };
    });

    final result = await TextureProbe().run(width: 64, height: 32);

    expect(result.ok, isFalse);
    expect(result.textureId, isNull);
    expect(result.error, 'eglCreateWindowSurface returned EGL_NO_SURFACE');
    expect(result.diagnostics['eglSurfaceCreated'], isFalse);
    expect(result.diagnostics['eglErrorAfterCreateWindowSurface'], 12291);
  });

  test('surfaces a PlatformException as a failed result', () async {
    messenger.setMockMethodCallHandler(TextureProbe.channel, (call) async {
      throw PlatformException(code: 'PROBE_THREW', message: 'boom');
    });

    final result = await TextureProbe().run(width: 64, height: 32);

    expect(result.ok, isFalse);
    expect(result.error, contains('boom'));
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd packages/flutter_map_maplibre && fvm flutter test test/probe_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'flutter_map_maplibre'` or `probe.dart` not found.

- [ ] **Step 4: Write the implementation**

Create `packages/flutter_map_maplibre/lib/src/probe.dart`:

```dart
import 'package:flutter/services.dart';

/// Outcome of a single texture probe run.
///
/// [diagnostics] carries the platform-specific facts the probe exists to
/// establish — they are the point of the probe, not decoration.
class ProbeResult {
  const ProbeResult({
    required this.ok,
    this.textureId,
    this.error,
    this.diagnostics = const <String, Object?>{},
  });

  final bool ok;
  final int? textureId;
  final String? error;
  final Map<String, Object?> diagnostics;

  @override
  String toString() =>
      'ProbeResult(ok: $ok, textureId: $textureId, error: $error, '
      'diagnostics: $diagnostics)';
}

/// Allocates a Flutter-registered texture, has native clear it via the
/// platform GPU API, and reports what happened.
class TextureProbe {
  static const MethodChannel channel = MethodChannel(
    'flutter_map_maplibre/probe',
  );

  Future<ProbeResult> run({required int width, required int height}) async {
    try {
      final response = await channel.invokeMapMethod<String, Object?>(
        'runProbe',
        <String, Object?>{'width': width, 'height': height},
      );

      if (response == null) {
        return const ProbeResult(ok: false, error: 'null response from native');
      }

      return ProbeResult(
        ok: response['ok'] as bool? ?? false,
        textureId: response['textureId'] as int?,
        error: response['error'] as String?,
        diagnostics:
            (response['diagnostics'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      );
    } on PlatformException catch (e) {
      return ProbeResult(ok: false, error: '${e.code}: ${e.message}');
    }
  }
}
```

Create `packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart`:

```dart
export 'src/probe.dart';
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd packages/flutter_map_maplibre && fvm flutter test test/probe_test.dart`
Expected: PASS — 3 tests.

- [ ] **Step 6: Format and commit**

```bash
cd /Users/sushakov/Projects/vedu-app/vedu_app_client
fvm dart format packages/flutter_map_maplibre/lib/src/probe.dart \
  packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart \
  packages/flutter_map_maplibre/test/probe_test.dart
git add packages/flutter_map_maplibre
git commit -m "feat(flutter_map_maplibre): package scaffold and Dart probe client"
```

---

### Task 2: Android probe — EGL into Flutter's SurfaceProducer

**Files:**
- Create: `packages/flutter_map_maplibre/android/src/main/kotlin/com/veduapp/flutter_map_maplibre/EglProbe.kt`
- Modify: `packages/flutter_map_maplibre/android/src/main/kotlin/com/veduapp/flutter_map_maplibre/FlutterMapMaplibrePlugin.kt` (replace generated boilerplate)

**Interfaces:**
- Consumes: the channel contract from Task 1 — `flutter_map_maplibre/probe`, method `runProbe`, args `{'width': Int, 'height': Int}`, returns `Map<String, Any?>` with `ok`/`textureId`/`error`/`diagnostics`.
- Produces: `class EglProbe { fun run(surface: Surface, width: Int, height: Int): Map<String, Any?> }` — returns the `diagnostics` sub-map plus a `success` boolean and optional `error` string.

**The assertion that matters:** `diagnostics["eglSurfaceCreated"]`. If that is `false`, the Android half of every candidate architecture is dead as designed.

- [ ] **Step 1: Write the EGL probe**

Create `EglProbe.kt`:

```kotlin
package com.veduapp.flutter_map_maplibre

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.view.Surface

/**
 * Clears a Flutter-owned Surface to solid red via EGL/GLES2.
 *
 * The point is not the colour — it is whether eglCreateWindowSurface accepts
 * an ImageFormat.PRIVATE ImageReader surface at all. Every candidate
 * architecture for a native basemap ultimately performs this exact call.
 */
class EglProbe {

    fun run(surface: Surface, width: Int, height: Int): Map<String, Any?> {
        val diagnostics = mutableMapOf<String, Any?>()

        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) {
            return diagnostics.fail("eglGetDisplay returned EGL_NO_DISPLAY")
        }

        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
            return diagnostics.fail("eglInitialize failed: ${EGL14.eglGetError()}")
        }
        diagnostics["eglVersion"] = "${version[0]}.${version[1]}"
        diagnostics["eglVendor"] = EGL14.eglQueryString(display, EGL14.EGL_VENDOR)

        val configAttrs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(
                display, configAttrs, 0, configs, 0, 1, numConfigs, 0
            ) || numConfigs[0] == 0
        ) {
            return diagnostics.fail("eglChooseConfig failed: ${EGL14.eglGetError()}")
        }
        val config = configs[0]!!

        val context = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
        )
        if (context == EGL14.EGL_NO_CONTEXT) {
            return diagnostics.fail("eglCreateContext failed: ${EGL14.eglGetError()}")
        }

        // ---- THE LOAD-BEARING CALL ----
        val eglSurface = EGL14.eglCreateWindowSurface(
            display, config, surface, intArrayOf(EGL14.EGL_NONE), 0
        )
        val surfaceCreated = eglSurface != EGL14.EGL_NO_SURFACE
        diagnostics["eglSurfaceCreated"] = surfaceCreated
        diagnostics["eglErrorAfterCreateWindowSurface"] = EGL14.eglGetError()
        if (!surfaceCreated) {
            cleanup(display, context, null)
            return diagnostics.fail("eglCreateWindowSurface returned EGL_NO_SURFACE")
        }
        // -------------------------------

        if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
            cleanup(display, context, eglSurface)
            return diagnostics.fail("eglMakeCurrent failed: ${EGL14.eglGetError()}")
        }

        diagnostics["glRenderer"] = GLES20.glGetString(GLES20.GL_RENDERER)
        diagnostics["glVersion"] = GLES20.glGetString(GLES20.GL_VERSION)

        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(1.0f, 0.0f, 0.0f, 1.0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glFinish()

        val swapped = EGL14.eglSwapBuffers(display, eglSurface)
        diagnostics["eglSwapBuffers"] = swapped
        diagnostics["glErrorAfterClear"] = GLES20.glGetError()

        cleanup(display, context, eglSurface)

        diagnostics["success"] = swapped
        if (!swapped) diagnostics["error"] = "eglSwapBuffers returned false"
        return diagnostics
    }

    private fun cleanup(display: EGLDisplay, context: EGLContext, surface: EGLSurface?) {
        EGL14.eglMakeCurrent(
            display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT
        )
        if (surface != null) EGL14.eglDestroySurface(display, surface)
        EGL14.eglDestroyContext(display, context)
        EGL14.eglTerminate(display)
    }

    private fun MutableMap<String, Any?>.fail(message: String): Map<String, Any?> {
        this["success"] = false
        this["error"] = message
        return this
    }
}
```

- [ ] **Step 2: Wire the plugin to SurfaceProducer**

Replace the contents of `FlutterMapMaplibrePlugin.kt`:

```kotlin
package com.veduapp.flutter_map_maplibre

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class FlutterMapMaplibrePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
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
```

- [ ] **Step 3: Build the example app for Android**

Run:
```bash
cd packages/flutter_map_maplibre/example && fvm flutter build apk --debug
```
Expected: BUILD SUCCESSFUL. Kotlin compile errors here mean the `SurfaceProducer` API shape differs from Flutter 3.44.5's — check `TextureRegistry.java` in the pinned engine before changing anything else.

- [ ] **Step 4: Commit**

```bash
git add packages/flutter_map_maplibre/android
git commit -m "feat(flutter_map_maplibre): Android EGL probe into SurfaceProducer"
```

---

### Task 3: iOS probe — Metal into an IOSurface-backed CVPixelBuffer

**Files:**
- Create: `packages/flutter_map_maplibre/ios/Classes/MetalProbe.swift`
- Modify: `packages/flutter_map_maplibre/ios/Classes/FlutterMapMaplibrePlugin.swift` (replace generated boilerplate)

**Interfaces:**
- Consumes: the same channel contract from Task 1.
- Produces: `class MetalProbe: NSObject, FlutterTexture` with `init?(width: Int, height: Int)`, `func clearToRed() -> Bool`, `var diagnostics: [String: Any]`, and the `FlutterTexture` method `copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?`.

**The assertion that matters:** `diagnostics["usageRenderTarget"]`. If that is `false`, MapLibre cannot render directly into Flutter's buffer and the iOS design degrades from zero-copy to blit-plus-format-conversion.

- [ ] **Step 1: Write the Metal probe**

Create `MetalProbe.swift`:

```swift
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
      diagnostics["error"] = "CVMetalTextureCacheCreateTextureFromImage failed: \(texStatus)"
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
```

- [ ] **Step 2: Wire the plugin to the texture registry**

Replace the contents of `FlutterMapMaplibrePlugin.swift`:

```swift
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
```

- [ ] **Step 3: Build the example app for iOS**

Run:
```bash
cd packages/flutter_map_maplibre/example && fvm flutter build ios --debug --no-codesign
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add packages/flutter_map_maplibre/ios
git commit -m "feat(flutter_map_maplibre): iOS Metal probe into IOSurface CVPixelBuffer"
```

---

### Task 4: Harness, run on devices, record the verdict

**Files:**
- Modify: `packages/flutter_map_maplibre/example/lib/main.dart` (replace generated boilerplate)
- Create: `docs/superpowers/specs/2026-07-22-flutter-map-maplibre-probe-results.md`

**Interfaces:**
- Consumes: `TextureProbe`, `ProbeResult` from Task 1; the native handlers from Tasks 2 and 3.
- Produces: a recorded verdict that decides whether the design proceeds.

- [ ] **Step 1: Write the harness UI**

Replace `packages/flutter_map_maplibre/example/lib/main.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: ProbePage());
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  ProbeResult? _result;

  Future<void> _run() async {
    final result = await TextureProbe().run(width: 512, height: 512);
    if (!mounted) return;
    setState(() => _result = result);
    debugPrint('probe: $result');
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Texture probe')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(onPressed: _run, child: const Text('Run probe')),
            const SizedBox(height: 16),
            if (result != null) ...[
              Text(result.ok ? 'OK' : 'FAILED: ${result.error}'),
              const SizedBox(height: 8),
              // A red square here means native GPU output reached Flutter's
              // compositor. Anything else (black, blank) means it did not.
              if (result.textureId != null)
                SizedBox(
                  height: 200,
                  child: Texture(textureId: result.textureId!),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    result.diagnostics.entries
                        .map((e) => '${e.key}: ${e.value}')
                        .join('\n'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Run on a physical Android device**

```bash
fvm flutter devices
cd packages/flutter_map_maplibre/example && fvm flutter run -d <android-device-id>
```

Tap "Run probe". Record:
- Is the square red?
- `eglSurfaceCreated` — the decisive value
- `eglErrorAfterCreateWindowSurface`, `glRenderer`, `glVersion`, `eglVendor`

- [ ] **Step 3: Run on a physical iOS device**

```bash
cd packages/flutter_map_maplibre/example && fvm flutter run -d <ios-device-id>
```

**Physical device only** — the simulator's Metal host is crash-looping on this machine and would produce a false negative. Tap "Run probe". Record:
- Is the square red?
- `usageRenderTarget` — the decisive value
- `ioSurfaceBacked`, `pixelFormatIsBGRA8Unorm`, `deviceName`

- [ ] **Step 4: Record the verdict**

Create `docs/superpowers/specs/2026-07-22-flutter-map-maplibre-probe-results.md` with the raw diagnostics from both devices and one of these conclusions:

| Outcome | Meaning | Next step |
|---|---|---|
| Both red, `eglSurfaceCreated` and `usageRenderTarget` both true | The core assumption holds on both platforms | Proceed to architecture selection (maplibre-native-ffi vs per-platform public API) |
| Android fails | `eglCreateWindowSurface` rejects Flutter's ImageReader surface | Every Android architecture is dead as designed; investigate `SurfaceTextureSurfaceProducer` fallback before concluding |
| iOS `usageRenderTarget` false | No direct render-target path | Zero-copy degrades to blit + format conversion; re-cost the iOS design before proceeding |
| Either crashes or shows black | Contract violated somewhere unexamined | Do not proceed; debug with superpowers:systematic-debugging |

- [ ] **Step 5: Commit**

```bash
fvm dart format packages/flutter_map_maplibre/example/lib/main.dart
git add packages/flutter_map_maplibre/example docs/superpowers/specs/2026-07-22-flutter-map-maplibre-probe-results.md
git commit -m "test(flutter_map_maplibre): probe harness and recorded device results"
```

---

## Explicitly out of scope

Deferred until the probes return a verdict, so that no effort is spent on an architecture that may not survive:

- MapLibre, in any form
- The residual affine transform (pure Dart, unit-testable, architecture-independent — worth doing early, but it is not what the probes answer)
- The `maplibre-native-ffi` build pipeline, and the `armeabi-v7a` product decision it forces
- Buffer rotation and synchronisation (3 buffers on iOS, since the engine retains `_lastPixelBuffer` with no release signal)
- Public API design, caching, offline, dark mode, Remote Config gating, attribution UI
