# MapLibre dart:ffi Same-Frame Render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the method-channel camera hot path with synchronous `dart:ffi` rendering during build plus a 3-buffer presentation ring, so the texture content matches the camera by construction and the raster thread only ever samples immutable buffers.

**Architecture:** All `mln_*` calls move to Dart on the UI thread (the C API is owner-thread affine and enforces this). The native side shrinks to a `TexturePresenter`: one fixed Metal back buffer (the render session's borrowed target) plus a ring of 3 CVPixelBuffer-backed front buffers published via an FFI-callable blit shim. The widget renders inline during build and draws at identity transform; the residual transform survives only as the failure fallback.

**Tech Stack:** Flutter (fvm), dart:ffi + ffigen, `maplibre_native_c` (vendored static xcframework), Metal/Swift presentation shim.

**Spec:** `docs/superpowers/specs/2026-07-23-maplibre-ffi-same-frame-render-design.md`

## Global Constraints

- All Flutter/Dart commands prefixed with `fvm` (project rule).
- After editing/creating any hand-written `.dart` file, run `fvm dart format <files>` (skip generated files — including `lib/src/ffi/maplibre_bindings.dart`).
- Branch: `maplibre-perf`. iOS only; Android is out of scope.
- NEVER commit `ios/Runner.xcodeproj/project.pbxproj` (local dev-signing flip; breaks fastlane/CI).
- The channel survives only for the cold path: `createTextures` / `disposeTextures`. The hot-path handlers (`runMap`, `setCamera`, `setStyle`, `mapDiagnostics`, `disposeMap`) are deleted by the end. `runProbe`/`MetalProbe` (the original clear-to-red probe) are deliberately retained.
- Symbols resolve via `DynamicLibrary.process()`; every `mln_*` symbol Dart calls must appear in the keeper table.
- Diagnostics keys: `renderMsInline` (EMA of the in-build render, replaces `pushToTextureMs`) and `blitMs` are new; ported counters keep their existing names (`renderMsAvgSteady`, `renderMsMaxSteady`, `renderMsLast`, `frameCount`, `cameraRenders`, `linkRenders`, `skippedTicks`, `idleEvents`, `needsRepaint`, `drawCalls`).
- Two device checkpoints (Tasks 2 and 4) require the human partner with the iPhone 14 Pro. Do not proceed past them without the human's device results.
- `mln_status` OK is `0`; event type values used: `MAP_IDLE = 8`, `MAP_RENDER_UPDATE_AVAILABLE = 9`, `MAP_RENDER_FRAME_FINISHED = 14`. Camera field flags: `CENTER = 1<<0`, `ZOOM = 1<<1`, `BEARING = 1<<2`. Map mode `CONTINUOUS = 0`. (Verified against the vendored headers; the renderer uses these as local constants so the generated enum shape doesn't matter.)

## File Structure

- `packages/flutter_map_maplibre/ffigen.yaml` — bindings config (new)
- `packages/flutter_map_maplibre/lib/src/ffi/maplibre_bindings.dart` — generated, committed (new)
- `packages/flutter_map_maplibre/lib/src/ffi/ffi_probe.dart` — symbol probe (new)
- `packages/flutter_map_maplibre/lib/src/ffi/ffi_present_probe.dart` — presentation probe widget (new)
- `packages/flutter_map_maplibre/lib/src/basemap_renderer.dart` — renderer interface + tick gate (new)
- `packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart` — FFI renderer (new)
- `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/mln_symbol_keeper.c` — dead-strip guard (new)
- `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/TexturePresenter.swift` — back buffer + ring + FFI shims (new)
- `packages/flutter_map_maplibre/ios/.../FlutterMapMaplibrePlugin.swift` — createTextures/disposeTextures; old handlers deleted at the end
- `packages/flutter_map_maplibre/lib/src/maplibre_channel.dart` — cold-path methods only by the end
- `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart` — widget rewrite
- `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart` — rewrite against fake renderer
- `packages/flutter_map_maplibre/test/tick_gate_test.dart` — pure gate logic tests (new)
- `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart` — diagnostics key updates
- Deleted at the end: `MLNBridge.m`, `MLNBridge.h`, `MapLibreProbe.swift`

---

### Task 1: FFI bindings, symbol keeper, and symbol probe

**Files:**
- Create: `packages/flutter_map_maplibre/ffigen.yaml`
- Create: `packages/flutter_map_maplibre/lib/src/ffi/maplibre_bindings.dart` (generated)
- Create: `packages/flutter_map_maplibre/lib/src/ffi/ffi_probe.dart`
- Create: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/mln_symbol_keeper.c`
- Modify: `packages/flutter_map_maplibre/pubspec.yaml`
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart` (temporary probe call)

**Interfaces:**
- Consumes: vendored headers at `ios/MaplibreNativeC.xcframework/ios-arm64/Headers/`.
- Produces: `MaplibreBindings` class (generated; constructor takes a `DynamicLibrary`), used by Task 5. `probeMaplibreFfi() -> String` used by Task 2. Keeper table used by every later FFI call.

- [ ] **Step 1: Add dependencies to the package pubspec**

In `packages/flutter_map_maplibre/pubspec.yaml`, add under the existing sections:

```yaml
dependencies:
  ffi: ^2.1.0
dev_dependencies:
  ffigen: ^13.0.0
```

(Merge into the existing `dependencies:`/`dev_dependencies:` blocks — do not duplicate the keys.) Then run:

```bash
cd packages/flutter_map_maplibre && fvm flutter pub get
```

- [ ] **Step 2: Write the ffigen config**

Create `packages/flutter_map_maplibre/ffigen.yaml`:

```yaml
name: MaplibreBindings
description: |
  Bindings for maplibre_native_c. Generated; do not edit.
  Regenerate: fvm dart run ffigen --config ffigen.yaml
output: 'lib/src/ffi/maplibre_bindings.dart'
headers:
  entry-points:
    - 'ios/MaplibreNativeC.xcframework/ios-arm64/Headers/maplibre_native_c.h'
  include-directives:
    - '**maplibre_native_c**'
compiler-opts:
  - '-std=c2x'
  - '-Iios/MaplibreNativeC.xcframework/ios-arm64/Headers'
functions:
  include:
    - 'mln_c_version'
    - 'mln_supported_render_backend_mask'
    - 'mln_runtime_options_default'
    - 'mln_runtime_create'
    - 'mln_runtime_destroy'
    - 'mln_runtime_run_once'
    - 'mln_runtime_poll_event'
    - 'mln_map_options_default'
    - 'mln_map_create'
    - 'mln_map_destroy'
    - 'mln_map_set_style_url'
    - 'mln_map_request_repaint'
    - 'mln_camera_options_default'
    - 'mln_map_jump_to'
    - 'mln_metal_borrowed_texture_descriptor_default'
    - 'mln_metal_borrowed_texture_attach'
    - 'mln_render_session_render_update'
    - 'mln_render_session_destroy'
structs:
  include:
    - 'mln_.*'
enums:
  as-int:
    include:
      - '.*'
preamble: |
  // Generated by ffigen from maplibre_native_c.h. Do not edit by hand.
  // Regenerate: fvm dart run ffigen --config ffigen.yaml
comments: none
```

The `enums.as-int` block makes every enum (including `mln_status` returns) come out as plain `int` — the renderer in Task 5 assumes int returns and local constants. If your ffigen version rejects that config key, check `fvm dart run ffigen --help` / the ffigen changelog for the current spelling of "generate enums as ints" and use that; the requirement is that no generated function signature uses a Dart enum type.

- [ ] **Step 3: Generate the bindings**

```bash
cd packages/flutter_map_maplibre && fvm dart run ffigen --config ffigen.yaml
```

Expected: `lib/src/ffi/maplibre_bindings.dart` is created and contains a `MaplibreBindings` class with methods like `mln_runtime_create`, plus structs `mln_camera_options`, `mln_runtime_event`, `mln_metal_borrowed_texture_descriptor`, `mln_render_target_extent` with snake_case field names. If ffigen fails to find libclang, install LLVM (`brew install llvm`) and add `llvm-path: ['/opt/homebrew/opt/llvm']` to the config. Do NOT format the generated file.

- [ ] **Step 4: Write the symbol keeper**

Create `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/mln_symbol_keeper.c`:

```c
#include <maplibre_native_c.h>

// Dart resolves mln_* through dlsym on the app image
// (DynamicLibrary.process()). The C API is linked as a static archive, so any
// function the linker considers unused is dead-stripped and dlsym returns
// null. This table references every symbol the Dart bindings call, keeping
// them alive through the app link. Update it whenever ffigen.yaml's function
// list changes.
__attribute__((used)) static void* const mln_ffi_symbol_keeper[] = {
  (void*)mln_c_version,
  (void*)mln_supported_render_backend_mask,
  (void*)mln_runtime_options_default,
  (void*)mln_runtime_create,
  (void*)mln_runtime_destroy,
  (void*)mln_runtime_run_once,
  (void*)mln_runtime_poll_event,
  (void*)mln_map_options_default,
  (void*)mln_map_create,
  (void*)mln_map_destroy,
  (void*)mln_map_set_style_url,
  (void*)mln_map_request_repaint,
  (void*)mln_camera_options_default,
  (void*)mln_map_jump_to,
  (void*)mln_metal_borrowed_texture_descriptor_default,
  (void*)mln_metal_borrowed_texture_attach,
  (void*)mln_render_session_render_update,
  (void*)mln_render_session_destroy,
};
```

- [ ] **Step 5: Write the probe function**

Create `packages/flutter_map_maplibre/lib/src/ffi/ffi_probe.dart`:

```dart
import 'dart:ffi';

import 'maplibre_bindings.dart';

/// Confirms the statically linked maplibre_native_c symbols are visible to
/// dart:ffi in this build — the go/no-go gate for the FFI port (spec, risk 1).
/// Returns a one-line diagnostic for the MLNFFI log.
String probeMaplibreFfi() {
  try {
    final bindings = MaplibreBindings(DynamicLibrary.process());
    final version = bindings.mln_c_version();
    final backends = bindings.mln_supported_render_backend_mask();
    return 'ok version=$version backends=0x${backends.toRadixString(16)}';
  } catch (e) {
    return 'FAILED: $e';
  }
}
```

- [ ] **Step 6: Call the probe from the widget (temporary)**

In `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart`, at the top of `_create` (right after `_creating = true;`), add:

```dart
    // Temporary (removed with the widget rewrite): FFI symbol probe, read
    // from the device log as MLNFFI.
    debugPrint('MLNFFI probe: ${probeMaplibreFfi()}');
```

Add the imports at the top of the file:

```dart
import 'package:flutter/foundation.dart';

import 'ffi/ffi_probe.dart';
```

- [ ] **Step 7: Analyze, format, verify tests still pass**

```bash
cd packages/flutter_map_maplibre \
  && fvm dart format lib/src/ffi/ffi_probe.dart lib/src/maplibre_basemap.dart \
  && fvm flutter analyze \
  && fvm flutter test
```

Expected: analyze clean (the generated file may produce lints — if so, add `lib/src/ffi/maplibre_bindings.dart` to the package's `analysis_options.yaml` exclude list), all existing tests pass (the probe only adds a log line).

- [ ] **Step 8: Commit**

```bash
git add packages/flutter_map_maplibre
git commit -m "feat(flutter_map_maplibre): generate dart:ffi bindings and symbol probe"
```

---

### Task 2: DEVICE CHECKPOINT A — symbol visibility (human + iPhone required)

No implementer subagent. The controller coordinates with the human partner.

- [ ] **Step 1: Build and run in profile mode on the device**

```bash
fvm flutter run --profile -d 00008120-001E35E234EB401E
```

(Adjust the device id if the phone re-enumerates; `fvm flutter devices` lists it.) The human opens the app with the MapLibre toggle ON so `MapLibreBasemap._create` runs.

- [ ] **Step 2: Read the probe line from the log**

Grep the run log for `MLNFFI probe:`.

- `ok version=... backends=0x1` (bit 0 = Metal) → **PASS**, proceed to Task 3.
- `FAILED: Failed to lookup symbol` → the app link stripped the symbols. Apply fallbacks in order, re-running the probe after each:
  1. In `flutter_map_maplibre.podspec`, add to `s.user_target_xcconfig`: `'STRIP_STYLE' => 'non-global'`, then `cd ios && pod install` and rebuild.
  2. If still failing, escalate to the human: the remaining option is rebuilding the xcframework as a dylib (spec, risk 1), which is a build-infrastructure task outside this plan.

- [ ] **Step 3: Record the result**

Append one line to `.superpowers/sdd/progress.md`: `Checkpoint A: symbols <PASS/what was needed>`.

---

### Task 3: TexturePresenter — back buffer, ring, FFI present/fill shims, cold-path channel

**Files:**
- Create: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/TexturePresenter.swift`
- Modify: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/FlutterMapMaplibrePlugin.swift`
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_channel.dart`

**Interfaces:**
- Consumes: nothing from earlier tasks (pure native + channel).
- Produces: channel method `createTextures {width:int,height:int,scale:double}` → `{ok:bool, textureId:int, backTexture:int}` and `disposeTextures` → null. FFI symbols `double fmm_present(int64_t presenterId)` (returns blit ms ≥ 0, or < 0 on error) and `int32_t fmm_debug_fill(int64_t presenterId, double r, double g, double b)` (0 = ok). `presenterId == textureId`. Task 5 calls `fmm_present`; Task 4's probe widget calls both.

- [ ] **Step 1: Write TexturePresenter.swift**

```swift
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
```

- [ ] **Step 2: Add the cold-path channel handlers**

In `FlutterMapMaplibrePlugin.swift`, add fields and handlers (keep all existing handlers untouched in this task):

```swift
  private var presenter: TexturePresenter?
  private var presenterTextureId: Int64?
```

In `handle(_:result:)`, before the `runProbe` guard:

```swift
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
      // One presenter per plugin instance; replacing tears the old one down.
      disposePresenter()
      self.presenter = presenter
      let id = textures.register(presenter)
      presenterTextureId = id
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
      disposePresenter()
      result(nil)
      return
    }
```

And the helper method on the plugin class:

```swift
  private func disposePresenter() {
    if let id = presenterTextureId {
      PresenterRegistry.lock.lock()
      PresenterRegistry.entries.removeValue(forKey: id)
      PresenterRegistry.lock.unlock()
      textures.unregisterTexture(id)
    }
    presenter = nil
    presenterTextureId = nil
  }
```

- [ ] **Step 3: Add the cold-path client methods to MapLibreChannel**

In `packages/flutter_map_maplibre/lib/src/maplibre_channel.dart`, add (keep existing methods in this task):

```dart
/// Result of creating the presentation textures (back buffer + ring).
class TexturesCreateResult {
  const TexturesCreateResult({
    required this.ok,
    this.textureId,
    this.backTextureAddress,
    this.error,
    this.diagnostics = const <String, Object?>{},
  });

  final bool ok;
  final int? textureId;

  /// Address of the borrowed MTLTexture the render session attaches to,
  /// passed to mln_metal_borrowed_texture_attach as descriptor.texture.
  final int? backTextureAddress;
  final String? error;
  final Map<String, Object?> diagnostics;
}
```

And inside `MapLibreChannel`:

```dart
  Future<TexturesCreateResult> createTextures({
    required int width,
    required int height,
    required double scale,
  }) async {
    try {
      final response = await channel.invokeMapMethod<String, Object?>(
        'createTextures',
        <String, Object?>{'width': width, 'height': height, 'scale': scale},
      );
      if (response == null) {
        return const TexturesCreateResult(ok: false, error: 'null response');
      }
      return TexturesCreateResult(
        ok: response['ok'] as bool? ?? false,
        textureId: response['textureId'] as int?,
        backTextureAddress: response['backTexture'] as int?,
        error: response['error'] as String?,
        diagnostics:
            (response['diagnostics'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      );
    } on PlatformException catch (e) {
      return TexturesCreateResult(ok: false, error: '${e.code}: ${e.message}');
    }
  }

  Future<void> disposeTextures() async {
    try {
      await channel.invokeMethod<void>('disposeTextures');
    } on PlatformException {
      // Teardown is best-effort.
    }
  }
```

- [ ] **Step 4: Write the presentation probe widget (Checkpoint B's driver)**

Create `packages/flutter_map_maplibre/lib/src/ffi/ffi_present_probe.dart`:

```dart
import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../maplibre_channel.dart';

typedef _PresentNative = Double Function(Int64);
typedef _FillNative = Int32 Function(Int64, Double, Double, Double);

/// Device probe (spec, risk 2): drives the TexturePresenter from the Dart UI
/// thread with a solid-color hue sweep — no MapLibre involved. A smooth sweep
/// on screen proves fmm_debug_fill/fmm_present resolve via dlsym and that
/// textureFrameAvailable fired from the UI thread reaches the engine at the
/// full frame rate. Temporary; deleted with the spike.
class FfiPresentProbe extends StatefulWidget {
  const FfiPresentProbe({super.key});

  @override
  State<FfiPresentProbe> createState() => _FfiPresentProbeState();
}

class _FfiPresentProbeState extends State<FfiPresentProbe>
    with SingleTickerProviderStateMixin {
  final _channel = MapLibreChannel();
  int? _textureId;
  Ticker? _ticker;
  int _frame = 0;
  double _lastBlitMs = -1;

  late final _present = DynamicLibrary.process()
      .lookupFunction<_PresentNative, double Function(int)>('fmm_present');
  late final _fill = DynamicLibrary.process()
      .lookupFunction<_FillNative, int Function(int, double, double, double)>(
        'fmm_debug_fill',
      );

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    final result = await _channel.createTextures(
      width: 200,
      height: 200,
      scale: 2.0,
    );
    if (!mounted || !result.ok) {
      debugPrint('MLNFFIPROBE createTextures failed: ${result.error}');
      return;
    }
    setState(() => _textureId = result.textureId);
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration _) {
    final id = _textureId;
    if (id == null) return;
    _frame++;
    // Slow hue sweep: ~4s per cycle at 120Hz. Stalls or freezes mean the
    // UI-thread textureFrameAvailable is not reaching the engine.
    final hue = (_frame % 480) / 480.0;
    final color = HSVColor.fromAHSV(1, hue * 360, 1, 1).toColor();
    final filled = _fill(id, color.r, color.g, color.b);
    if (filled != 0) {
      debugPrint('MLNFFIPROBE fill failed: $filled');
      return;
    }
    _lastBlitMs = _present(id);
    if (_frame % 120 == 0) {
      debugPrint('MLNFFIPROBE frame=$_frame blitMs=$_lastBlitMs');
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _channel.disposeTextures();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _textureId;
    if (textureId == null) return const SizedBox.shrink();
    return SizedBox(
      width: 200,
      height: 200,
      child: Texture(textureId: textureId),
    );
  }
}
```

- [ ] **Step 5: Analyze, format, run tests, build for device**

```bash
cd packages/flutter_map_maplibre \
  && fvm dart format lib/src/ffi/ffi_present_probe.dart lib/src/maplibre_channel.dart \
  && fvm flutter analyze && fvm flutter test
cd ../.. && fvm flutter build ios --profile --no-codesign 2>&1 | tail -5
```

Expected: analyze clean, existing tests pass (nothing on the old path changed), iOS build succeeds (compiles TexturePresenter.swift + keeper).

- [ ] **Step 6: Commit**

```bash
git add packages/flutter_map_maplibre
git commit -m "feat(flutter_map_maplibre): TexturePresenter ring with FFI present/fill shims"
```

---

### Task 4: DEVICE CHECKPOINT B — same-frame presentation from the UI thread (human + iPhone required)

No implementer subagent. The controller coordinates with the human partner.

- [ ] **Step 1: Temporarily mount the probe widget**

In `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`, temporarily add `FfiPresentProbe` on top of the diagnostics overlay — inside `MaplibreDiagnosticsOverlay.build`'s `Column` children, first entry:

```dart
          const FfiPresentProbe(),
          const SizedBox(height: 6),
```

with import `package:flutter_map_maplibre/src/ffi/ffi_present_probe.dart`. (Do not commit this edit; it is reverted in Step 3.)

- [ ] **Step 2: Run on device (profile), human verifies**

```bash
fvm flutter run --profile -d 00008120-001E35E234EB401E
```

Human turns the MapLibre toggle on and looks at the 200×200 square above the overlay. **PASS**: a smooth, continuous color sweep (no freezes, no stepping), and `MLNFFIPROBE` log lines show `blitMs` well under 1ms. **FAIL** modes: square never appears (fmm symbols not found — same fallback ladder as Checkpoint A, now for the Swift @_cdecl symbols), or the sweep is frozen/stuttering (UI-thread `textureFrameAvailable` not reaching the engine — escalate: the shim must dispatch to the main queue, and the checkpoint re-run must confirm the sweep stays smooth, which validates the async timing is still adequate).

- [ ] **Step 3: Revert the temporary edit, record the result**

Revert the probe mount in `maplibre_basemap_layer.dart` (`git checkout -- lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`). Append to `.superpowers/sdd/progress.md`: `Checkpoint B: present <PASS/what was needed>, blitMs≈<value>`.

---

### Task 5: BasemapRenderer interface, tick gate, and the FFI renderer

**Files:**
- Create: `packages/flutter_map_maplibre/lib/src/basemap_renderer.dart`
- Create: `packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart`
- Create: `packages/flutter_map_maplibre/test/tick_gate_test.dart`
- Modify: `packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart` (exports)

**Interfaces:**
- Consumes: `MaplibreBindings` (Task 1), `fmm_present` (Task 3), `maplibreZoom`/`maplibreBearing` from `lib/src/camera_conventions.dart` (existing), `MapCamera` from flutter_map.
- Produces: `BasemapRenderer` (interface below) and `FfiBasemapRenderer` implementing it — Task 6's widget depends on exactly this surface. `decideTick(...) -> TickDecision` pure function.

- [ ] **Step 1: Write the failing tests for the tick gate**

Create `packages/flutter_map_maplibre/test/tick_gate_test.dart`:

```dart
import 'package:flutter_map_maplibre/src/basemap_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('idle map skips: no update, no repaint, nothing rendered', () {
    expect(
      decideTick(
        updateAvailable: false,
        needsRepaint: false,
        renderedSinceLastTick: false,
      ),
      TickDecision.skipIdle,
    );
  });

  test('a camera render this frame suppresses the tick render', () {
    expect(
      decideTick(
        updateAvailable: true,
        needsRepaint: true,
        renderedSinceLastTick: true,
      ),
      TickDecision.skipRenderedThisFrame,
    );
  });

  test('a pending update with no camera render this frame renders', () {
    expect(
      decideTick(
        updateAvailable: true,
        needsRepaint: false,
        renderedSinceLastTick: false,
      ),
      TickDecision.render,
    );
  });

  test('needs_repaint alone (mid-animation) renders', () {
    expect(
      decideTick(
        updateAvailable: false,
        needsRepaint: true,
        renderedSinceLastTick: false,
      ),
      TickDecision.render,
    );
  });
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd packages/flutter_map_maplibre && fvm flutter test test/tick_gate_test.dart
```

Expected: FAIL — `basemap_renderer.dart` does not exist.

- [ ] **Step 3: Write the interface and gate**

Create `packages/flutter_map_maplibre/lib/src/basemap_renderer.dart`:

```dart
import 'package:flutter_map/flutter_map.dart';

/// What the ticker should do this frame.
enum TickDecision {
  /// Map is settled: no pending update event, no repaint request.
  skipIdle,

  /// A camera render already produced this frame's pixels; rendering again
  /// would be the same content at ~2ms a pop. Frame-granular — the wall-clock
  /// suppression window from the channel era died with the race.
  skipRenderedThisFrame,

  render,
}

/// The idle/suppression gate, pure so it is testable without FFI. Idle wins
/// over suppression so `skippedTicks` counts idle frames the way the channel
/// implementation did.
TickDecision decideTick({
  required bool updateAvailable,
  required bool needsRepaint,
  required bool renderedSinceLastTick,
}) {
  if (!updateAvailable && !needsRepaint) return TickDecision.skipIdle;
  if (renderedSinceLastTick) return TickDecision.skipRenderedThisFrame;
  return TickDecision.render;
}

/// The native renderer as the basemap widget sees it. One implementation
/// talks FFI ([FfiBasemapRenderer]); tests inject a fake. The defining
/// property: [lastRenderedCamera] is ground truth for what the front buffer
/// shows — measured, never estimated.
abstract interface class BasemapRenderer {
  /// True after a successful [create] and before [dispose].
  bool get isReady;

  /// The camera the published front buffer was rendered for, or null before
  /// the first successful render. Unlike the channel era's `_rendered` stamp,
  /// this is written only after the render + present actually completed.
  MapCamera? get lastRenderedCamera;

  /// Creates runtime, map, and render session on the calling (UI) thread,
  /// attaching the borrowed back texture. Returns false on failure (details
  /// land in [diagnostics]).
  bool create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  });

  /// Synchronously renders and presents [camera]. Returns true when the front
  /// buffer now shows it (including the no-op case where it already did).
  bool render(MapCamera camera);

  /// Ticker hook: pump events, apply [decideTick], render+present if due.
  /// Returns true when a new frame was presented (callers rebuild so the
  /// transform stays true to the new content).
  bool tick();

  /// Swaps the style in place. No-op when not ready.
  void setStyle(String styleUrl);

  Map<String, Object?> diagnostics();

  /// Destroys session, map, and runtime on the calling (UI) thread.
  void dispose();
}
```

- [ ] **Step 4: Run the gate tests to verify they pass**

```bash
cd packages/flutter_map_maplibre && fvm flutter test test/tick_gate_test.dart
```

Expected: 4 tests PASS.

- [ ] **Step 5: Write the FFI renderer**

Create `packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart`:

```dart
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_map/flutter_map.dart';

import '../basemap_renderer.dart';
import '../camera_conventions.dart';
import 'maplibre_bindings.dart';

// ABI constants from the vendored headers, kept local so the generated
// bindings' enum shape doesn't matter (ffigen generates enums as ints).
const _statusOk = 0; // MLN_STATUS_OK
const _eventMapIdle = 8; // MLN_RUNTIME_EVENT_MAP_IDLE
const _eventUpdateAvailable = 9; // ..._MAP_RENDER_UPDATE_AVAILABLE
const _eventFrameFinished = 14; // ..._MAP_RENDER_FRAME_FINISHED
const _cameraOptionCenter = 1 << 0; // MLN_CAMERA_OPTION_CENTER
const _cameraOptionZoom = 1 << 1; // MLN_CAMERA_OPTION_ZOOM
const _cameraOptionBearing = 1 << 2; // MLN_CAMERA_OPTION_BEARING
const _mapModeContinuous = 0; // MLN_MAP_MODE_CONTINUOUS

typedef _PresentNative = Double Function(Int64);

/// [BasemapRenderer] over maplibre_native_c via dart:ffi.
///
/// Every mln_* call happens on the thread that calls [create] — the C API is
/// owner-thread affine and returns MLN_STATUS_WRONG_THREAD otherwise, which
/// is exactly the enforcement the design wants: the whole renderer lives on
/// the Flutter UI thread.
class FfiBasemapRenderer implements BasemapRenderer {
  FfiBasemapRenderer();

  static final MaplibreBindings _b = MaplibreBindings(
    DynamicLibrary.process(),
  );
  static final double Function(int) _present = DynamicLibrary.process()
      .lookupFunction<_PresentNative, double Function(int)>('fmm_present');

  Pointer<mln_runtime> _runtime = nullptr;
  Pointer<mln_map> _map = nullptr;
  Pointer<mln_render_session> _session = nullptr;
  int _presenterId = -1;

  // Reused native scratch, allocated in create and freed in dispose.
  Pointer<mln_camera_options> _camera = nullptr;
  Pointer<mln_runtime_event> _event = nullptr;
  Pointer<Bool> _hasEvent = nullptr;
  Pointer<Pointer<mln_runtime>> _outRuntime = nullptr;
  Pointer<Pointer<mln_map>> _outMap = nullptr;
  Pointer<Pointer<mln_render_session>> _outSession = nullptr;

  MapCamera? _lastRenderedCamera;

  /// What jump_to last set — becomes [_lastRenderedCamera] once a render for
  /// it actually lands (a tick render after a failed camera render publishes
  /// this camera's content).
  MapCamera? _jumpedCamera;

  bool _updateAvailable = false;
  bool _needsRepaint = false;
  bool _renderedSinceLastTick = false;

  final _diagnostics = <String, Object?>{};
  int _frameCount = 0;
  int _cameraRenders = 0;
  int _linkRenders = 0;
  int _skippedTicks = 0;
  int _idleEvents = 0;
  double _maxRenderMs = 0;
  int _steadyFrames = 0;
  double _steadyRenderMs = 0;
  double _steadyMaxMs = 0;
  double? _renderMsInline;
  double? _blitMs;
  int _drawCalls = 0;

  @override
  bool get isReady => _session != nullptr;

  @override
  MapCamera? get lastRenderedCamera => _lastRenderedCamera;

  @override
  bool create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  }) {
    assert(!isReady, 'dispose before re-creating');
    _camera = calloc<mln_camera_options>();
    _event = calloc<mln_runtime_event>();
    _hasEvent = calloc<Bool>();
    _outRuntime = calloc<Pointer<mln_runtime>>();
    _outMap = calloc<Pointer<mln_map>>();
    _outSession = calloc<Pointer<mln_render_session>>();
    _presenterId = presenterId;

    final options = calloc<mln_runtime_options>();
    final cachePath = ':memory:'.toNativeUtf8();
    options.ref = _b.mln_runtime_options_default();
    options.ref.cache_path = cachePath.cast();
    final runtimeStatus = _b.mln_runtime_create(options, _outRuntime);
    calloc.free(options);
    calloc.free(cachePath); // "Copied during runtime creation."
    _diagnostics['runtimeCreateStatus'] = runtimeStatus;
    if (runtimeStatus != _statusOk) return _failCreate();
    _runtime = _outRuntime.value;

    final mapOptions = calloc<mln_map_options>();
    mapOptions.ref = _b.mln_map_options_default();
    mapOptions.ref.width = width;
    mapOptions.ref.height = height;
    mapOptions.ref.scale_factor = scale;
    mapOptions.ref.map_mode = _mapModeContinuous;
    final mapStatus = _b.mln_map_create(_runtime, mapOptions, _outMap);
    calloc.free(mapOptions);
    _diagnostics['mapCreateStatus'] = mapStatus;
    if (mapStatus != _statusOk) return _failCreate();
    _map = _outMap.value;

    final styleNative = styleUrl.toNativeUtf8();
    _diagnostics['setStyleStatus'] = _b.mln_map_set_style_url(
      _map,
      styleNative.cast(),
    );
    calloc.free(styleNative);
    _b.mln_map_request_repaint(_map);

    final descriptor = calloc<mln_metal_borrowed_texture_descriptor>();
    descriptor.ref = _b.mln_metal_borrowed_texture_descriptor_default();
    descriptor.ref.extent.width = width;
    descriptor.ref.extent.height = height;
    descriptor.ref.extent.scale_factor = scale;
    descriptor.ref.texture = Pointer<Void>.fromAddress(backTextureAddress);
    final attachStatus = _b.mln_metal_borrowed_texture_attach(
      _map,
      descriptor,
      _outSession,
    );
    calloc.free(descriptor);
    _diagnostics['attachStatus'] = attachStatus;
    if (attachStatus != _statusOk) return _failCreate();
    _session = _outSession.value;
    return true;
  }

  bool _failCreate() {
    dispose();
    return false;
  }

  static bool _sameCamera(MapCamera? a, MapCamera b) =>
      a != null &&
      a.center.latitude == b.center.latitude &&
      a.center.longitude == b.center.longitude &&
      a.zoom == b.zoom &&
      a.rotation == b.rotation;

  @override
  bool render(MapCamera camera) {
    if (!isReady) return false;
    // Already showing it: the settle condition, same role as the channel
    // era's sameCamera guard.
    if (_sameCamera(_lastRenderedCamera, camera)) return true;

    _camera.ref = _b.mln_camera_options_default();
    _camera.ref.fields =
        _cameraOptionCenter | _cameraOptionZoom | _cameraOptionBearing;
    _camera.ref.latitude = camera.center.latitude;
    _camera.ref.longitude = camera.center.longitude;
    _camera.ref.zoom = maplibreZoom(camera.zoom);
    _camera.ref.bearing = maplibreBearing(camera.rotation);
    _b.mln_map_jump_to(_map, _camera);
    _b.mln_map_request_repaint(_map);
    _jumpedCamera = camera;

    _pumpEvents();
    final clock = Stopwatch()..start();
    if (!_renderAndPresent()) return false;
    final ms = clock.elapsedMicroseconds / 1000.0;
    _renderMsInline = _renderMsInline == null
        ? ms
        : _renderMsInline! * 0.8 + ms * 0.2;

    _cameraRenders++;
    _renderedSinceLastTick = true;
    _lastRenderedCamera = camera;
    return true;
  }

  @override
  bool tick() {
    if (!isReady) return false;
    _pumpEvents();
    final decision = decideTick(
      updateAvailable: _updateAvailable,
      needsRepaint: _needsRepaint,
      renderedSinceLastTick: _renderedSinceLastTick,
    );
    _renderedSinceLastTick = false;
    switch (decision) {
      case TickDecision.skipIdle:
      case TickDecision.skipRenderedThisFrame:
        _skippedTicks++;
        return false;
      case TickDecision.render:
        if (!_renderAndPresent()) return false;
        _linkRenders++;
        // The content now on screen is whatever camera the map last jumped
        // to — which matters after a failed camera render, where this tick
        // is the retry that lands it.
        if (_jumpedCamera != null) _lastRenderedCamera = _jumpedCamera;
        return true;
    }
  }

  /// mln render (blocks until the GPU finishes) + blit-present. True only
  /// when both landed, so callers can treat it as "the front buffer changed".
  bool _renderAndPresent() {
    final clock = Stopwatch()..start();
    final status = _b.mln_render_session_render_update(_session);
    final elapsedMs = clock.elapsedMicroseconds / 1000.0;
    _diagnostics['lastRenderStatus'] = status;
    if (status != _statusOk) return false;

    final blit = _present(_presenterId);
    if (blit < 0) {
      _diagnostics['presentError'] = blit;
      return false;
    }
    _blitMs = _blitMs == null ? blit : _blitMs! * 0.8 + blit * 0.2;

    _updateAvailable = false;
    _frameCount++;
    if (elapsedMs > _maxRenderMs) _maxRenderMs = elapsedMs;
    // First frames pay style load and tile upload; not steady state.
    if (_frameCount > 30) {
      _steadyFrames++;
      _steadyRenderMs += elapsedMs;
      if (elapsedMs > _steadyMaxMs) _steadyMaxMs = elapsedMs;
    }
    _diagnostics['renderMsLast'] = _round2(elapsedMs);
    return true;
  }

  /// Drains the runtime event queue into flags. `_updateAvailable` is sticky:
  /// set here, cleared only by a successful render — per-tick clearing would
  /// lose updates that arrive while a render is skipped.
  void _pumpEvents() {
    _b.mln_runtime_run_once(_runtime);
    while (true) {
      _event.ref.size = sizeOf<mln_runtime_event>();
      _hasEvent.value = false;
      final status = _b.mln_runtime_poll_event(_runtime, _event, _hasEvent);
      if (status != _statusOk || !_hasEvent.value) break;
      switch (_event.ref.type) {
        case _eventUpdateAvailable:
          _updateAvailable = true;
        case _eventMapIdle:
          _idleEvents++;
        case _eventFrameFinished:
          if (_event.ref.payload != nullptr &&
              _event.ref.payload_size >=
                  sizeOf<mln_runtime_event_render_frame>()) {
            final frame = _event.ref.payload
                .cast<mln_runtime_event_render_frame>()
                .ref;
            _needsRepaint = frame.needs_repaint;
            _drawCalls = frame.stats.draw_call_count;
          }
        default:
          break;
      }
    }
  }

  @override
  void setStyle(String styleUrl) {
    if (!isReady) return;
    final native = styleUrl.toNativeUtf8();
    _diagnostics['setStyleStatus'] = _b.mln_map_set_style_url(
      _map,
      native.cast(),
    );
    calloc.free(native);
    _b.mln_map_request_repaint(_map);
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  @override
  Map<String, Object?> diagnostics() {
    return <String, Object?>{
      ..._diagnostics,
      'frameCount': _frameCount,
      'cameraRenders': _cameraRenders,
      'linkRenders': _linkRenders,
      'skippedTicks': _skippedTicks,
      'idleEvents': _idleEvents,
      'needsRepaint': _needsRepaint,
      'drawCalls': _drawCalls,
      'renderMsMax': _round2(_maxRenderMs),
      if (_steadyFrames > 0) ...{
        'renderMsAvgSteady': _round2(_steadyRenderMs / _steadyFrames),
        'renderMsMaxSteady': _round2(_steadyMaxMs),
      },
      if (_renderMsInline != null) 'renderMsInline': _round2(_renderMsInline!),
      if (_blitMs != null) 'blitMs': _round2(_blitMs!),
    };
  }

  @override
  void dispose() {
    if (_session != nullptr) {
      _b.mln_render_session_destroy(_session);
      _session = nullptr;
    }
    if (_map != nullptr) {
      _b.mln_map_destroy(_map);
      _map = nullptr;
    }
    if (_runtime != nullptr) {
      _b.mln_runtime_destroy(_runtime);
      _runtime = nullptr;
    }
    for (final pointer in <Pointer>[
      _camera,
      _event,
      _hasEvent,
      _outRuntime,
      _outMap,
      _outSession,
    ]) {
      if (pointer != nullptr) calloc.free(pointer);
    }
    _camera = nullptr;
    _event = nullptr;
    _hasEvent = nullptr;
    _outRuntime = nullptr;
    _outMap = nullptr;
    _outSession = nullptr;
    _lastRenderedCamera = null;
    _jumpedCamera = null;
  }
}
```

Note for the implementer: generated struct/field names must match ffigen's output — check `maplibre_bindings.dart` for the exact class names (`mln_camera_options` etc. keep their C names) and adjust field access only if ffigen renamed them (it preserves C names by default). `int` fields of `uint32_t` C type accept Dart ints directly.

- [ ] **Step 6: Export the new surface**

In `packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart`, add:

```dart
export 'src/basemap_renderer.dart';
```

- [ ] **Step 7: Analyze, format, full package tests**

```bash
cd packages/flutter_map_maplibre \
  && fvm dart format lib/src/basemap_renderer.dart lib/src/ffi/ffi_basemap_renderer.dart test/tick_gate_test.dart lib/flutter_map_maplibre.dart \
  && fvm flutter analyze && fvm flutter test
```

Expected: analyze clean, all tests pass (tick gate 4 + existing suite).

- [ ] **Step 8: Commit**

```bash
git add packages/flutter_map_maplibre
git commit -m "feat(flutter_map_maplibre): FFI basemap renderer with frame-granular tick gate"
```

---

### Task 6: Widget rewrite — same-frame render in build

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart` (rewrite)
- Modify: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart` (rewrite)

**Interfaces:**
- Consumes: `BasemapRenderer`, `decideTick` (Task 5); `TexturesCreateResult`, `createTextures`, `disposeTextures` (Task 3); existing `residualTransform`.
- Produces: `MapLibreBasemap` with new optional `rendererFactory` parameter (`BasemapRenderer Function()?`); everything else on the public constructor is unchanged (`styleUrl`, `onDiagnostics`, `applyResidualTransform`, `overRenderFactor`).

- [ ] **Step 1: Rewrite the widget**

Replace the contents of `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart` with:

```dart
import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import 'basemap_renderer.dart';
import 'ffi/ffi_basemap_renderer.dart';
import 'maplibre_channel.dart';
import 'residual_transform.dart';

/// A natively-rendered MapLibre vector basemap, for use as a `flutter_map`
/// layer in place of `TileLayer`.
///
/// Drop it in as the first child of a [FlutterMap]; everything above it —
/// markers, polylines, overlays — stays ordinary Flutter widgets:
///
/// ```dart
/// FlutterMap(
///   options: ...,
///   children: [
///     MapLibreBasemap(styleUrl: 'https://.../style.json'),
///     MarkerLayer(markers: ...),
///   ],
/// )
/// ```
///
/// The camera stays owned by `flutter_map`. Each build renders the frame
/// synchronously via dart:ffi before returning, so the texture content
/// matches the camera by construction and the basemap draws at identity —
/// no estimation, no stamping. The residual transform survives only as the
/// failure fallback, correcting against the renderer's ground-truth
/// [BasemapRenderer.lastRenderedCamera].
class MapLibreBasemap extends StatefulWidget {
  const MapLibreBasemap({
    super.key,
    required this.styleUrl,
    this.onDiagnostics,
    this.applyResidualTransform = true,
    this.overRenderFactor = 1.0,
    this.rendererFactory,
  }) : assert(overRenderFactor >= 1.0);

  /// MapLibre style JSON URL. Changing it swaps the style in place without
  /// tearing down the renderer, which is what makes light/dark switching
  /// cheap.
  final String styleUrl;

  /// Periodic render statistics, for callers that want to surface or log
  /// them.
  final ValueChanged<Map<String, Object?>>? onDiagnostics;

  /// Escape hatch for debugging: with this false a failed render is drawn
  /// uncorrected. Never disable in production.
  final bool applyResidualTransform;

  /// How much larger than the viewport to render, per axis. With the
  /// same-frame render the texture is never behind the camera on the happy
  /// path, so 1.0 (exact viewport) is the expected value; the margin only
  /// papers over failure frames.
  final double overRenderFactor;

  /// Test seam: build the renderer. Defaults to the FFI implementation.
  final BasemapRenderer Function()? rendererFactory;

  @override
  State<MapLibreBasemap> createState() => _MapLibreBasemapState();
}

class _MapLibreBasemapState extends State<MapLibreBasemap>
    with SingleTickerProviderStateMixin {
  final _channel = MapLibreChannel();
  late final BasemapRenderer _renderer =
      (widget.rendererFactory ?? FfiBasemapRenderer.new)();

  int? _textureId;

  /// The viewport size the current session was created for (unenlarged).
  Size? _viewportSize;

  /// [_viewportSize] scaled by [MapLibreBasemap.overRenderFactor]; what the
  /// texture is actually rendered at.
  Size? _renderSize;

  Ticker? _ticker;
  bool _creating = false;
  Timer? _diagnosticsTimer;

  @override
  void didUpdateWidget(MapLibreBasemap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.styleUrl != widget.styleUrl) {
      _renderer.setStyle(widget.styleUrl);
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _diagnosticsTimer?.cancel();
    _renderer.dispose();
    _channel.disposeTextures();
    super.dispose();
  }

  /// Ticker: lets the map animate itself (tile fades, transitions) between
  /// camera changes. When a tick presents a new frame the widget rebuilds so
  /// the transform stays true to the new content.
  void _onTick(Duration _) {
    if (_renderer.tick() && mounted) setState(() {});
  }

  void _startDiagnosticsPolling() {
    if (widget.onDiagnostics == null || _diagnosticsTimer != null) return;
    _diagnosticsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      widget.onDiagnostics?.call(_renderer.diagnostics());
    });
  }

  Future<void> _create(Size viewport, double devicePixelRatio) async {
    if (_creating) return;
    _creating = true;

    // Resize path: the borrowed-texture session cannot be resized in place.
    if (_textureId != null) {
      _renderer.dispose();
      await _channel.disposeTextures();
      _textureId = null;
    }

    final factor = widget.overRenderFactor;
    final renderSize = Size(viewport.width * factor, viewport.height * factor);

    final result = await _channel.createTextures(
      width: renderSize.width.round(),
      height: renderSize.height.round(),
      scale: devicePixelRatio,
    );
    if (!mounted ||
        !result.ok ||
        result.textureId == null ||
        result.backTextureAddress == null) {
      widget.onDiagnostics?.call(result.diagnostics);
      _creating = false;
      return;
    }

    final created = _renderer.create(
      backTextureAddress: result.backTextureAddress!,
      presenterId: result.textureId!,
      width: renderSize.width.round(),
      height: renderSize.height.round(),
      scale: devicePixelRatio,
      styleUrl: widget.styleUrl,
    );
    if (!created) {
      widget.onDiagnostics?.call(_renderer.diagnostics());
      _creating = false;
      return;
    }

    setState(() {
      _textureId = result.textureId;
      _viewportSize = viewport;
      _renderSize = renderSize;
    });
    _ticker ??= createTicker(_onTick)..start();
    _startDiagnosticsPolling();
    _creating = false;
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

        // Sizes churn every frame while a bottom sheet drags, hence the
        // tolerance. Compared against the unenlarged viewport.
        final current = _viewportSize;
        final needsCreate =
            current == null ||
            (current.width - size.width).abs() > 1 ||
            (current.height - size.height).abs() > 1;

        if (needsCreate && size.isFinite && !size.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _create(size, devicePixelRatio);
          });
        }

        final textureId = _textureId;
        final renderSize = _renderSize;

        if (textureId == null || renderSize == null) {
          return const SizedBox.shrink();
        }

        // The same-frame render: by the time this build returns, the front
        // buffer shows [camera] (on success). No stamp, no estimate.
        final rendered = _renderer.render(camera);
        final shown = _renderer.lastRenderedCamera;

        // First frame before any successful render: draw uncorrected rather
        // than hide the map (a hidden map is indistinguishable from a broken
        // renderer).
        final transform = (rendered || shown == null)
            ? Matrix4.identity()
            : widget.applyResidualTransform
            ? residualTransform(
                rendered: shown.withNonRotatedSize(renderSize),
                current: camera,
              )
            : Matrix4.identity();

        return Transform(
          transform: transform,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: renderSize.width,
            maxWidth: renderSize.width,
            minHeight: renderSize.height,
            maxHeight: renderSize.height,
            child: Texture(textureId: textureId),
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 2: Rewrite the widget tests**

Replace the contents of `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart` with:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:flutter_map_maplibre/src/maplibre_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Fake renderer: the widget's whole FFI world, scripted per test.
class _FakeRenderer implements BasemapRenderer {
  bool renderResult = true;
  bool tickResult = false;
  int renderCalls = 0;
  int tickCalls = 0;
  int disposeCalls = 0;
  MapCamera? _last;
  String? styleUrl;

  @override
  bool get isReady => true;

  @override
  MapCamera? get lastRenderedCamera => _last;

  @override
  bool create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  }) {
    this.styleUrl = styleUrl;
    return true;
  }

  @override
  bool render(MapCamera camera) {
    renderCalls++;
    if (!renderResult) return false;
    _last = camera;
    return true;
  }

  @override
  bool tick() {
    tickCalls++;
    final result = tickResult;
    tickResult = false;
    return result;
  }

  @override
  void setStyle(String styleUrl) => this.styleUrl = styleUrl;

  @override
  Map<String, Object?> diagnostics() => <String, Object?>{
    'renderMsInline': 2.5,
    'blitMs': 0.2,
  };

  @override
  void dispose() => disposeCalls++;
}

/// The cold path still goes over the channel; mock it.
void installChannelMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(MapLibreChannel.channel, (call) async {
        switch (call.method) {
          case 'createTextures':
            return <String, Object?>{
              'ok': true,
              'textureId': 1,
              'backTexture': 0xDEAD,
              'diagnostics': <String, Object?>{},
            };
          default:
            return null;
        }
      });
}

void main() {
  late _FakeRenderer renderer;
  late MapController controller;

  setUp(() {
    renderer = _FakeRenderer();
    installChannelMock();
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MapLibreChannel.channel, null);
  });

  Future<void> pumpMap(
    WidgetTester tester, {
    ValueChanged<Map<String, Object?>>? onDiagnostics,
  }) async {
    controller = MapController();
    await tester.pumpWidget(
      MaterialApp(
        home: FlutterMap(
          mapController: controller,
          options: const MapOptions(
            initialCenter: LatLng(59.437, 24.7536),
            initialZoom: 13,
          ),
          children: [
            MapLibreBasemap(
              styleUrl: 'https://example.com/style.json',
              onDiagnostics: onDiagnostics,
              rendererFactory: () => renderer,
            ),
          ],
        ),
      ),
    );
    // Frame 1 schedules _create post-frame; pump until the texture exists.
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
  }

  Matrix4 basemapTransform(WidgetTester tester) {
    final transform = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(MapLibreBasemap),
            matching: find.byType(Transform),
          )
          .first,
    );
    return transform.transform;
  }

  testWidgets('build renders the current camera and draws at identity', (
    tester,
  ) async {
    await pumpMap(tester);
    final calls = renderer.renderCalls;
    expect(calls, greaterThan(0));
    expect(basemapTransform(tester).isIdentity(), isTrue);

    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(renderer.renderCalls, greaterThan(calls));
    expect(renderer.lastRenderedCamera!.center.latitude, closeTo(59.45, 1e-9));
    expect(
      basemapTransform(tester).isIdentity(),
      isTrue,
      reason: 'same-frame render: the texture already shows this camera',
    );
  });

  testWidgets('a failed render falls back to the honest transform', (
    tester,
  ) async {
    await pumpMap(tester);
    expect(basemapTransform(tester).isIdentity(), isTrue);

    renderer.renderResult = false;
    controller.move(const LatLng(59.45, 24.80), 13);
    await tester.pump();
    expect(
      basemapTransform(tester).isIdentity(),
      isFalse,
      reason:
          'the front buffer still shows the old camera; the transform must '
          'correct against the renderer\'s ground truth',
    );

    // Recovery: the next successful build render snaps back to identity.
    renderer.renderResult = true;
    controller.move(const LatLng(59.46, 24.81), 13);
    await tester.pump();
    expect(basemapTransform(tester).isIdentity(), isTrue);
  });

  testWidgets('a tick that presents triggers a rebuild', (tester) async {
    await pumpMap(tester);
    final buildsBefore = renderer.renderCalls;

    renderer.tickResult = true;
    await tester.pump();
    await tester.pump();
    expect(
      renderer.renderCalls,
      greaterThan(buildsBefore),
      reason:
          'tick presented a frame → setState → rebuild → render (no-op on '
          'the renderer side, but the transform is recomputed)',
    );
  });

  testWidgets('reports renderer diagnostics on the polling timer', (
    tester,
  ) async {
    Map<String, Object?>? latest;
    await pumpMap(tester, onDiagnostics: (d) => latest = d);
    await tester.pump(const Duration(seconds: 1));
    expect(latest, isNotNull);
    expect(latest!['renderMsInline'], 2.5);
    expect(latest!['blitMs'], 0.2);
  });

  testWidgets('style change reaches the renderer', (tester) async {
    await pumpMap(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: FlutterMap(
          mapController: controller,
          options: const MapOptions(
            initialCenter: LatLng(59.437, 24.7536),
            initialZoom: 13,
          ),
          children: [
            MapLibreBasemap(
              styleUrl: 'https://example.com/dark.json',
              rendererFactory: () => renderer,
            ),
          ],
        ),
      ),
    );
    expect(renderer.styleUrl, 'https://example.com/dark.json');
  });
}
```

- [ ] **Step 3: Run the tests**

```bash
cd packages/flutter_map_maplibre && fvm flutter test
```

Expected: widget tests + tick gate tests PASS. (The old test file's channel-stamping tests are gone with the contract they tested.) The temporary `MLNFFI probe` debugPrint from Task 1 is deleted by this rewrite — verify it is not in the new file.

- [ ] **Step 4: Format and analyze**

```bash
cd packages/flutter_map_maplibre \
  && fvm dart format lib/src/maplibre_basemap.dart test/maplibre_basemap_test.dart \
  && fvm flutter analyze
```

Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add packages/flutter_map_maplibre
git commit -m "feat(flutter_map_maplibre): render same-frame in build via the FFI renderer"
```

---

### Task 7: Delete the channel hot path and update app diagnostics keys

**Files:**
- Delete: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.m`
- Delete: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MLNBridge.h`
- Delete: `packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre/MapLibreProbe.swift`
- Modify: `packages/flutter_map_maplibre/ios/.../FlutterMapMaplibrePlugin.swift`
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_channel.dart`
- Modify: `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`

**Interfaces:**
- Consumes: the Task 6 widget (must be the only consumer of the deleted surface).
- Produces: the final channel surface — `createTextures`, `disposeTextures`, `runProbe` only.

- [ ] **Step 1: Delete the native hot path**

```bash
cd packages/flutter_map_maplibre/ios/flutter_map_maplibre/Sources/flutter_map_maplibre
rm MLNBridge.m MLNBridge.h MapLibreProbe.swift
```

- [ ] **Step 2: Prune the plugin**

In `FlutterMapMaplibrePlugin.swift`: delete the `mapProbe`/`mapTextureId` fields, the `runMap`, `setCamera`, `setStyle`, `mapDiagnostics`, and `disposeMap` branches in `handle`, the whole `handleRunMap` method, and `currentMapDiagnostics()`. Keep: `createTextures`, `disposeTextures`, `disposePresenter()`, and the `runProbe`/`MetalProbe` path (the original spike probe, deliberately retained).

- [ ] **Step 3: Prune the channel client**

In `maplibre_channel.dart`: delete `BasemapCreateResult`, `create`, `setCamera`, `setStyle`, `diagnostics`, and `dispose`. Keep `TexturesCreateResult`, `createTextures`, `disposeTextures`, and the `channel` constant. Update the class doc comment to say the channel is cold-path only (texture lifecycle; the hot path is dart:ffi).

- [ ] **Step 4: Update the app-side diagnostics keys**

In `lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart`, the MLNDIAG line: replace `'push=${d['pushToTextureMs']} '` with `'render=${d['renderMsInline']} '` and add `'blit=${d['blitMs']} '` after it. In `_numbersPanel`, replace `'${row('pushToTextureMs')}'` with `'${row('renderMsInline')}'` and add `'${row('blitMs')}'` after it.

- [ ] **Step 5: Full verification**

```bash
cd packages/flutter_map_maplibre && fvm flutter test && fvm flutter analyze
cd ../.. && fvm dart format lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart packages/flutter_map_maplibre/lib/src/maplibre_channel.dart \
  && fvm flutter analyze \
  && fvm flutter build ios --profile --no-codesign 2>&1 | tail -5
```

Expected: package tests pass, both analyzes clean, iOS build succeeds with the deleted files gone.

- [ ] **Step 6: Commit**

```bash
git add packages/flutter_map_maplibre lib/screens/main_map/main_map_map_view/maplibre_basemap_layer.dart
git commit -m "refactor(flutter_map_maplibre): delete the method-channel hot path"
```

---

### Task 8: DEVICE VALIDATION — three phases (human + iPhone required)

No implementer subagent. The controller coordinates with the human partner, batch-reading logs when the human says a phase is done (never per-line monitoring).

- [ ] **Step 1: Run profile build on the iPhone 14 Pro**

```bash
fvm flutter run --profile -d 00008120-001E35E234EB401E
```

Human enables the MapLibre toggle, warms up the map (pan around until tiles settle), then runs the phases using the on-screen chips: **idle** (map stationary ~30s), **fling** (120Hz, flick and release repeatedly), **low-power** (enable Low Power Mode, flick and release).

- [ ] **Step 2: Evaluate against the spec's success criteria**

From the MLNDIAG lines per phase:
- Idle: `cam` and `link` counters frozen, `skip` advancing ~120/s (or 60 in low power).
- Fling: `render=` (inline EMA) low single-digit ms, `blit=` well under 1ms, no human-visible stutter.
- Low power: human verdict — fling-decel smoothness at parity with 120Hz; the trailing-viewport artifact gone.

- [ ] **Step 3: Record results**

Append a "Device validation results" section to
`docs/superpowers/specs/2026-07-23-maplibre-ffi-same-frame-render-design.md`
with the measured numbers and verdicts per phase; update
`.superpowers/sdd/progress.md`; commit:

```bash
git add docs/superpowers/specs/2026-07-23-maplibre-ffi-same-frame-render-design.md
git commit -m "docs(flutter_map_maplibre): record FFI same-frame device validation"
```

If low power still shows the artifact, that is a spec-level finding — stop and
analyze with the human before further changes (the estimation error is gone by
construction, so any residue has a different cause and needs fresh diagnosis).
