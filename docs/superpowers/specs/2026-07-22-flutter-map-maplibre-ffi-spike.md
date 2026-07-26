# maplibre-native-ffi spike — result and catches

Date: 2026-07-22
Status: **working on iOS simulator.** A real MapLibre vector map, served from
`tiles.example.com`, rendering inside a Flutter `Texture` widget with the
camera driven from the host.

Screenshot: `packages/flutter_map_maplibre/maplibre-ios-simulator.png`

## Result

```
runtimeCreateStatus: 0    mapCreateStatus: 0     setStyleStatus: 0
jumpToStatus: 0           attachStatus: 0        lastRenderStatus: 0
usageRenderTarget: true   deviceName: Apple iOS simulator GPU
frameCount: 402           (~10s wall clock, ~40fps)
```

The architecture works. `mln_metal_borrowed_texture_attach` takes a texture
derived from an IOSurface-backed `CVPixelBuffer` via `CVMetalTextureCache`,
MapLibre renders directly into it, and Flutter composites it with no copy.

Deliberately crude: one texture (tearing possible), the FFI's per-frame
`waitUntilCompleted()` stall left in, everything on the main thread via
`CADisplayLink`. **No upstream patches were needed to get this far** — the
buffer-rotation and async-completion changes are optimisations, not blockers.

## Catches, in the order they bit

### Build

1. **Rust is not needed on Apple.** `cmake/platform/apple.cmake` uses
   `platform/darwin/core/http_file_source.mm` (NSURLSession). The Rust/`rustls`
   dependency is Android-only. iOS needs only Xcode, CMake and Ninja.
2. **`mise` is not needed.** It is a task runner; `cmake --preset …` works
   directly.
3. **Nested submodules are fragile.** `git submodule update --init --recursive`
   aborts partway (on `vendor/earcut.hpp/glfw`), silently leaving ~11 later
   vendor submodules unpopulated, and configure then fails one missing CMake
   target at a time. Two extra traps: `vendor/maplibre-tile-spec` is pinned to
   a `cpp` branch and is skipped by a `--depth 1` recursion, and some
   submodules end up registered-but-empty, where plain `update --init` reports
   success and does nothing — they need `--force`.
   A directory containing only `.git` is the tell.
4. **The static archive is enormous.** 1.43 GB unstripped, 734 MB after
   `strip -S`. Not committable; must be built or fetched out of band.
5. **`strip -S` was a red herring but `ranlib` is cheap insurance.** Stripping
   can leave `__.SYMDEF` stale; `nm` scans members directly and still finds
   symbols while `ld` cannot. Not the actual failure here, but worth knowing.

### Integration

6. **The FFI forces iOS 14.3 minimum** (`CMAKE_OSX_DEPLOYMENT_TARGET` in the
   Apple presets). Non-issue for the host app, which targets 17.0, but it propagates to
   any consuming app and the error is a hard build failure.
7. **There is no x86_64 simulator preset — arm64 only.** Xcode builds a
   *universal* simulator binary by default (`ARCHS = arm64 x86_64`), so the
   x86_64 slice has nothing to link and fails with every symbol undefined.
   Requires `EXCLUDED_ARCHS[sdk=iphonesimulator*] = i386 x86_64`, and it must
   be set *after* `Generated.xcconfig` is included or Flutter's config wins.
   This was the single most misleading failure — it presents as "the archive
   isn't linked at all".
8. **SPM `.binaryTarget` did not link.** Flutter 3.44 generates SPM-layout
   plugins, and a `.binaryTarget` xcframework compiled fine but its static
   library was never passed to the linker. Switched the plugin to CocoaPods by
   renaming `Package.swift`; that is per-plugin and needs no global Flutter
   config change.
9. **`s.static_framework = true` is required.** As a dynamic framework the pod
   must resolve the C symbols at its own link step, which loses to link order.
10. **A `module.modulemap` inside the xcframework's `Headers/` breaks the
    build.** With that directory on `HEADER_SEARCH_PATHS`, Xcode's
    explicitly-built modules fail to resolve *system* modules — `simd`,
    `_Builtin_float`, `_DarwinFoundation1/2/3`. Flutter then blames a
    "CocoaPods and Swift Package Manager" conflict, which is a red herring.
11. **Import the C API from Objective-C, not Swift.** Sidestepping the Swift
    module entirely — a small ObjC wrapper (`MLNBridge`) that `#include`s
    `maplibre_native_c.h`, exposed to Swift through the pod's umbrella header —
    avoids catch 10 completely. This is the single highest-leverage decision in
    the integration.
12. **Do not both `-l` and `-force_load` the archive** — 29 duplicate symbols.
    Once the arch problem (7) is fixed, CocoaPods' own `-l` suffices.

### API

13. **The texture must be sized in *physical* pixels; the extent is
    *logical*.** `mln_metal_borrowed_texture_attach` returns
    `MLN_STATUS_INVALID_ARGUMENT` (-1) when
    `texture.width != extent.width * extent.scale_factor`. Everything else
    returns 0, so the failure is isolated and easy to misread as a Metal
    problem.

## What this does not answer

- **Physical device.** Everything here is the simulator, whose Metal is
  `MTLSimDriver`. The FFI's own CI never executes on an iOS device either.
- **Performance.** ~40fps was measured with the `waitUntilCompleted()` stall,
  on a simulator, at 512x512 logical. It says nothing about a full-screen map
  at device density under gesture load.
- **Tearing.** Single-buffered, so a torn frame is possible and simply was not
  observed. Buffer rotation still needs the ~100 LOC upstream change.
- **Android.** Untouched. The EGL surface path is a different integration with
  its own catches, and the FFI never tests Android at all.

## Reproducing

```bash
# 1. Clone and fully populate submodules (see catch 3 — expect to repair some)
git clone https://github.com/maplibre/maplibre-native-ffi
cd maplibre-native-ffi && git submodule update --init --recursive

# 2. Build
cmake --preset ios-simulator-arm64-metal
cmake --build --preset ios-simulator-arm64-metal

# 3. Package (strip first; the archive is 1.4GB)
strip -S build/ios-simulator-arm64-metal/maplibre_native_c_static-complete-static/libmaplibre-native-c.a
xcodebuild -create-xcframework -library <stripped>.a -headers <include> \
  -output MaplibreNativeC.xcframework
# then DELETE Headers/module.modulemap (catch 10)
```

The plugin side is `packages/flutter_map_maplibre/ios/flutter_map_maplibre.podspec`
plus `MLNBridge.{h,m}`.

---

## Android (2026-07-22, later)

**Status: does not work.** Builds, links, runs, renders frames — no visible map.

### What works

- Rust cross-compiles to `aarch64-linux-android` (`libmaplibre_native_platform.a`).
  Rust is **mandatory** on Android: `cmake/platform/android.cmake` includes
  `mln_rust` unconditionally for `http_file_source.cpp` and `image.cpp`. It is
  *not* needed on Apple, which uses NSURLSession.
- FFI builds with NDK 28.2.13676358 — the version pinned in the FFI's own
  `mise.toml`, which happened to be installed already.
- The presets read `$env{ANDROID_HOME}` and `$env{MLN_FFI_ANDROID_NDK_VERSION}`,
  not `ANDROID_NDK_HOME`.
- A JNI shim creates an EGL context directly on Flutter's `SurfaceProducer`
  surface, and `mln_opengl_surface_attach` returns `MLN_STATUS_OK`.
- The `Choreographer` loop runs at 590+ frames with `render_update` returning OK
  and `eglSwapBuffers` returning true.
- `libmln_jni.so` is **18.7 MB** in a debug APK — all of MapLibre after
  dead-stripping, versus `libflutter.so` at 37.6 MB. The 431 MB static archive
  is an intermediate, not a payload.

### What fails

The Flutter texture stays empty. The screen shows the Scaffold background, not
the style's background colour — so MapLibre's output is not reaching the
SurfaceProducer at all. This is not a tiles or TLS problem: if the renderer were
drawing into our surface we would see its background even with zero tiles.

**Eliminated:** the widget withholding the `Texture` until the first camera push
resolves. Drawing it from the first frame changes nothing.

**Leading hypothesis:** `mln_opengl_surface_attach` creates its own EGL context
in our share group and renders into its own framebuffer rather than the window
surface we supplied, so our `eglSwapBuffers` presents an untouched surface. The
clear-to-red probe worked precisely because *we* drew into the surface directly.

### Next steps for whoever picks this up

1. Read `src/render/opengl/opengl_surface_session.cpp` and `egl_context.cpp` in
   maplibre-native-ffi to establish who owns `eglMakeCurrent` and who is
   expected to call `eglSwapBuffers`. The example app
   (`examples/android-map/.../EglGraphicsContext.kt`) does its EGL in Kotlin and
   may sequence this differently from the JNI shim here.
2. Surface `mln_android_init`'s return value in the periodic diagnostics — it is
   currently only in the create response and so has never been read.
3. Capture `MLN_RUNTIME_EVENT_MAP_LOADING_FAILED` in `nativeRender` the way the
   iOS bridge does, so style failures stop being invisible.

---

## Android, working (2026-07-22, later still)

**Status: working.** A real MapLibre vector map from `tiles.example.com`
renders inside a Flutter `Texture` on Android, camera driven from the host —
`styleLoaded: true`, `lastEvent: null`, `glError: 0`, `attachStatus: 0`.

Screenshot: `packages/flutter_map_maplibre/maplibre-android-emulator.png`

Getting there took two fixes (wrong render target, then TLS) and three
falsified hypotheses; both are written up below because the dead ends are the
expensive part to rediscover.

### The two faults, and why they hid each other

The blank texture was **two stacked failures**, and the earlier writeup got the
diagnosis wrong by reasoning from a symptom that could not carry the weight put
on it.

**Fault 1 — wrong render target.** The surface session was the wrong API.
`mln_opengl_surface_attach` creates its own EGL context in the supplied share
group. A share group shares *texture objects*; it does **not** share window
surfaces. So the session rendered into its own default framebuffer while our
`eglSwapBuffers` presented an untouched buffer. The clear-to-red probe passed
precisely because *we* drew into the surface directly.

Fix: `mln_opengl_borrowed_texture_attach` — the exact analogue of the Metal path
that already worked on iOS. We own a `GL_TEXTURE_2D`, MapLibre renders into it,
and a fullscreen-triangle shader blits it to the window surface. Android costs
one GPU-side blit that iOS does not, because `SurfaceProducer` will not accept a
raw texture name.

**Fault 2 — TLS.** `rustls` needs a companion Java class,
`org.rustls.platformverifier.CertificateVerifier`, that ships as an AAR inside
the Rust crate and is never published to Maven Central. Without it every
handshake dies with `ClassNotFoundException` → the style never loads → MapLibre
has nothing to draw.

**The reasoning error worth remembering:** the earlier note argued "the screen
shows Scaffold grey, not the style's background colour, so this is not a tiles
or TLS problem." That inference is invalid — *with no style loaded there is no
background colour to draw*. Fault 2 produced exactly the evidence used to rule
fault 2 out. What actually broke the deadlock was not cleverer deduction but
capturing `MLN_RUNTIME_EVENT_MAP_LOADING_FAILED` (step 3 above) and letting the
renderer say what was wrong: `loading style failed: io: unexpected error:
failed to call native verifier`. Instrument before theorising.

### Packaging the verifier

Consuming the AAR would force **every host app** to declare a custom Maven
repository, because Gradle resolves a library's POM dependencies in the *app's*
context, not the library's — confirmed by a failing build. The AAR contains
nothing but a 9K `classes.jar` (empty `R.txt`, no resources, no transitive
deps), so the jar is vendored at
`android/prebuilt/rustls-platform-verifier-0.1.1.jar` and consumed with
`implementation(files(...))`. Local file deps are packaged into the consuming
APK with zero host configuration. Verified present in `classes.dex`.

### What is still blocked

HTTPS fails on the API 33 emulator with `invalid peer certificate: Revoked`
against **both** `tiles.example.com` (Let's Encrypt YE1) and
`demotiles.maplibre.org` (Google Trust Services WE1) — two different CAs, both
certificates valid, device clock correct. Every host fails, so this is not our
server and not our certificate.

**Root cause found — it is not the emulator.** Installing Android 16 / API 36
and re-running reproduces `Revoked` exactly. The "stale trust store" theory was
wrong twice over: both chains cross-sign down to roots trusted for a decade
(`ISRG Root X1`, 2015; `GlobalSign Root CA`, 1998), so no plausible image lacks
them.

The failure is inside `rustls-platform-verifier`'s extra PKIX pass. **The exact
throwing check is still unidentified** — see the falsified hypotheses below.

What is established:

- Decompiling `CertificateVerifier.class` shows it runs the normal Android trust
  check (`X509TrustManagerExtensions.checkServerTrusted`) and then a **second,
  stricter pass**: `CertPathValidator` + `PKIXRevocationChecker`. Any
  `CertPathValidatorException` from that pass is mapped to `StatusCode.Revoked`.
  **"Revoked" is a catch-all label, not a finding that anything was revoked.**
  This label is what made the bug so slow to diagnose — it asserts a specific
  cause the code never actually established.
- No other TLS client on the device runs that second pass, which is why the
  certificate works everywhere else (the production app on Android, browsers) and
  why iOS never hit it: Apple builds use NSURLSession, with no Rust or rustls in
  the picture at all.

**This will fail on physical devices too** — it is an upstream incompatibility,
not a lab artifact, and it blocks the Android leg for real users.

#### Hypotheses tested and falsified

Recorded because each looked convincing and cost real time:

1. ~~Stale emulator trust store.~~ Installed Android 16 / API 36; `Revoked`
   reproduces identically. Both chains also cross-sign to roots trusted for a
   decade.
2. ~~Missing roots.~~ Pulled `/system/etc/security/cacerts` (149 certs, and
   `/apex/com.android.conscrypt/cacerts` matches): ISRG Root X1, ISRG Root X2,
   GTS Root R4 and GlobalSign Root CA are all present.
3. ~~Revocation checking failing closed with OCSP discontinued.~~ Neither cert
   carries an OCSP responder URL and neither server staples one — but the
   verifier sets `EnumSet.of(SOFT_FAIL, ONLY_END_ENTITY)`, and `SOFT_FAIL`
   exists precisely to tolerate undetermined revocation status. This was
   committed as the root cause in `ba9f1ff` and is **wrong**.

Getting the real answer needs the actual exception, which the `Revoked` mapping
discards. The cheapest route is a throwaway Android instrumentation test that
calls `CertPathValidator.validate` against these chains directly and prints the
exception — not more inference from bytecode strings.

#### Resolution: bypass the verifier

`patches/0001-android-webpki-roots.patch` (against maplibre-native-ffi
`94e6f08`) switches the Rust HTTP stack from `RootCerts::PlatformVerifier` to
`RootCerts::WebPki` **on Android only**; other platforms keep the system trust
store. `ureq`'s `rustls` feature already bundles `webpki-roots`, so this is a
one-line selection change with no new dependency.

The map loaded immediately. That is also the confirmation the diagnosis never
got directly: removing the verifier removes the failure, so the verifier was
the cause even though the specific failing check was never identified.

Trade-offs, both real:

- **User-installed and enterprise CAs are ignored for map traffic.** Debugging
  proxies (Charles, mitmproxy) can no longer intercept tile requests. Every
  other request in the app is unaffected, since only the FFI uses this stack.
- **The root store is baked into the binary** and updates only on rebuild.

`mln_android_init` and the vendored verifier jar are still required — the Rust
side calls `rustls_platform_verifier::android::init_with_env` regardless of
which root store is selected, and removing it is a larger upstream change than
this one line.

Fix options, cheapest first:

1. **Rebuild the FFI's Rust with `webpki-roots` instead of `platform-verifier`**
   (`src/platform/rust/Cargo.toml`, the `ureq` feature list). Bundles the
   Mozilla root store and bypasses the Android verifier entirely. We control
   this build. Trade-off: roots are baked in, so updating them needs a rebuild,
   and user-installed or enterprise CAs stop being honoured — the latter also
   breaks debugging proxies like Charles/mitmproxy.
2. **Bump `rustls-platform-verifier`** (FFI pins 0.6.2, Android component
   0.1.1) to a release that tolerates absent OCSP.
3. **Report upstream** to maplibre-native-ffi and/or rustls-platform-verifier.

Either of 1 or 2 requires rebuilding the Rust static library and relinking
`libmln_jni.so`; the toolchain for that is already set up.

### Known issue: no camera until the first push

The renderer is created without a camera, so MapLibre starts at its own default
(lat 0, lng 0, zoom 0) and the host pushes the real camera immediately after.
Two consequences:

- `MLNBridge` hardcodes Tallinn (`59.437, 24.7536`, zoom 13) at init. Harmless
  for this app, wrong for a general package, and it hid the issue on iOS
  entirely — the map looked right no matter what the host asked for.
- The widget hides the texture until the first push resolves, so a slow push
  shows nothing rather than the wrong place.

**An attempt to pass the camera at creation was made and reverted.** Recorded
so it is not retried blind:

- Threading lat/lng/zoom/bearing through `create` on both platforms made the
  map render **blank** — style background, no features.
- Panning fixed it instantly, so a later `setCamera` with the same values
  works.
- Re-applying the camera on `MAP_STYLE_LOADED` (on the theory that style load
  resets it) did **not** help.
- Native diagnostics then showed the stored camera was already correct:
  `59.4370,24.7536 z13.00 b0.0`, `styleLoaded: true`, no error, still blank.

So the camera value, the style and the render path are all fine, and
`mln_map_jump_to` at or before attach simply does not take effect the way the
same call does later. Three hypotheses failed; the next step is to find what
`setCamera` does differently after the session is live — probably ordering
against `mln_opengl_borrowed_texture_attach` — rather than another guess.

### Reproducing the HTTP proof

```bash
# background-only style, no tiles, no TLS
echo '{"version":8,"name":"bg","sources":{},"layers":[
  {"id":"bg","type":"background","paint":{"background-color":"#00C853"}}]}' > style.json
python3 -m http.server 8765
# point the example at http://10.0.2.2:8765/style.json (emulator alias for host)
```

This isolates the graphics path from the network completely and is the right
first move if the texture ever goes blank again.

## Camera conventions (2026-07-23)

First hands-on run on the simulator: rendering smooth, but dragging moved the
map faster than the finger, and rotation broke the alignment entirely. Neither
was the residual transform — it works in `flutter_map`'s space on both sides,
so it stays correct however wrong the texture is. Both were unit mismatches at
the Dart→native boundary, where the camera crosses into MapLibre's conventions:

1. **Zoom is 512-based, not 256.** `Epsg3857.scale` is `256 · 2^z`;
   `mbgl::util::tileSize_D` is 512. The same view is therefore one zoom level
   lower in MapLibre's numbering, and an unconverted value renders at exactly
   twice the intended scale. The centre still tracks correctly, which is why it
   reads as a *pan* bug rather than a zoom bug.
2. **Bearing is the negative of rotation.** `flutter_map` rotates the content
   (`latLngToScreenOffset` turns points by `+rotationRad`); MapLibre's bearing
   turns the camera. `flutter_map` rotation 90° is MapLibre bearing 270°.

Both live in `lib/src/camera_conventions.dart`. The tests derive the expected
values from `flutter_map`'s own projection rather than restating the constants,
so they check the relationship rather than the arithmetic: the zoom test
asserts both worlds are the same pixel width, and the bearing test asks which
compass direction `latLngToScreenOffset` actually puts at the top of the screen.

Worth noting how quietly these fail. Both produce a map that renders, pans,
zooms and looks entirely plausible in a screenshot — only interaction reveals
them.

## First device impressions + bottleneck analysis (2026-07-23)

Running on a physical iPhone 16 Pro (profile build), the map "behaves like
native Mapbox" — smooth, real vector zoom, labels laying out live. Three
artefacts remain, in priority order.

### The visible lag is a bookkeeping lie, not slowness

The map trails the Flutter marker layer slightly while panning, and markedly
under Low Power Mode. This is *not* the renderer being too slow: the residual
transform is mathematically exact (proven by tests), so a correctly-attributed
stale frame lands pixel-perfect no matter how many frames behind it is.

The trailing means `_rendered` is dishonest — it claims the texture holds a
newer camera than it does. We set `_rendered = camera` when the setCamera
*channel round-trip* resolves, but that is before the native renderer has drawn
that camera into the texture and before Flutter has sampled it. The transform
then corrects against a camera not yet on screen, leaving residual lag. Low
Power Mode throttles CPU/GPU and deepens the pipeline, so the texture falls
further behind the claim and the error grows — exactly the observed behaviour.

Fix: stamp each rendered frame with the camera it was actually drawn at (the
native side knows this at MAP_RENDER_FRAME_FINISHED) and drive the transform
from that, rather than from the optimistic push. Falsifiable prediction: this
should *reduce* trailing and, unlike a speed fix, should improve most visibly
under Low Power Mode.

### Throughput ceiling: single texture + waitUntilCompleted

The FFI blocks the render thread on GPU completion every frame, serialising
CPU-encode and GPU-execute instead of overlapping them, and one texture means
Flutter cannot sample while MapLibre writes. Double-buffering removes the stall
and the tearing risk together. This is the cap that keeps 120Hz out of reach.

### Waste: render-every-tick and a per-frame channel hop

The renderer renders unconditionally (counters added to measure it); and the
camera is pushed over a method channel every frame, serialised through the
platform thread. The architectural endgame is dart:ffi: Dart calls
mln_map_jump_to directly and synchronously, which removes the channel *and*
makes the honest-staleness fix above trivial (the push and the render attribute
to the same camera in the same call).

### Integration

Wired into the host app behind a debug-menu toggle ("Native MapLibre basemap"), raster
TileLayer still the default. Two host-app portability fixes were required and
are documented in the commit: latlong2 constraint relaxed to flutter_map's own
range, and the podspec's app-target search path moved off an example-relative
path onto Flutter's plugin symlink.

## Running the integrated app on a device — two non-MapLibre walls (2026-07-23)

Neither was caused by the package; both are the host app's own build/signing setup
surfacing for the first time because the app had never been installed directly
on a device (it ships only via TestFlight).

1. **PurchasesHybridCommon const-extraction error.** After `pod install`
   regenerated the Pods project, the profile build failed with "Cannot open
   constant extraction protocol list input file ...
   PurchasesHybridCommon_const_extract_protocols.json". This is a known Xcode
   incremental-build bug (RevenueCat), not a code fault: the build reached
   "Xcode build done" and only the const-extraction phase of a *different* pod
   failed. Clearing DerivedData for the Runner and rebuilding fixes it. (If it
   were the MapLibre xcframework path, the failure would be a linker
   `-lmln-stripped not found`, at link, not a const-extraction step.)

2. **Distribution-only signing.** Every build config (Debug/Profile/Release,
   Runner + AppWidget) is Manual / Apple Distribution / `match AppStore`, so
   `flutter run` signs for the App Store and the install is rejected with
   0xe800801f "Attempted to install a Beta profile". The host app has no development
   signing path because it deploys through TestFlight. For local device
   testing, the configs were temporarily flipped to Automatic signing with the
   existing Apple Development cert (team YVG657396L), built, then reverted with
   `git checkout ios/Runner.xcodeproj/project.pbxproj` — the match/TestFlight
   pipeline is left untouched. A permanent fix would add a development lane to
   fastlane match rather than change the committed project.
