# Render Worker Thread (Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Android mln rendering off the Flutter UI thread onto a dedicated native worker thread so hard-pan fps recovers from ~46 to raster-class (≥90).

**Architecture:** A C++ worker thread (`fmm_worker.cpp`) owns runtime/map/session and executes a strict-FIFO command queue (`CREATE/PUMP/JUMP/RENDER/SET_STYLE/DESTROY`), coalescing stale `RENDER`s (`SUPERSEDED`) and posting completions to the UI isolate via `Dart_PostCObject_DL`. A new `WorkerBasemapRenderer` facade keeps the exact decision state machine of `FfiBasemapRenderer` in Dart, with flags updated from port messages instead of return values. iOS keeps the synchronous `FfiBasemapRenderer`.

**Tech Stack:** dart:ffi + dart:isolate NativePorts, vendored `dart_api_dl`, C++17 (std::thread), existing mln_jni.cpp presenter/`fmm_attach`/`fmm_present`, Flutter 3.44.5 via fvm.

**Spec:** `docs/superpowers/specs/2026-07-26-render-worker-thread-design.md`

## Global Constraints

- All Flutter/Dart commands prefixed with `fvm` (project rule).
- After editing/creating any `.dart` file, run `fvm dart format <files>` (skip generated files).
- Android only: iOS behavior must not change (except `create()` becoming `Future<bool>`, sync-completing there).
- Branch `maplibre`, worktree `.claude/worktrees/maplibre-perf`. Do NOT push.
- Package test command: `cd packages/flutter_map_maplibre && fvm flutter test`.
- C++ compile gate (no C++ unit tests exist): `cd packages/flutter_map_maplibre/example && fvm flutter build apk --debug --target-platform android-arm64`.
- Completion message kinds (int, first element of every port message): `0=CREATED, 1=EVENTS, 2=RENDERED, 3=SUPERSEDED, 4=DESTROYED` — must match between `fmm_worker.cpp` and `worker_basemap_renderer.dart`.
- The worker executes commands strictly in post order; the ONLY scheduling logic is RENDER coalescing.
- **Spec deviation (approved rationale below, Task 5):** the spec's "dispose hands `_channel.disposeTextures` to the facade as post-DESTROYED cleanup" is dropped. The Kotlin plugin holds ONE presenter per engine and `createTextures` disposes the previous one itself, so a deferred callback could destroy a *successor* presenter on the resize path. Instead the widget keeps today's call order; out-of-order teardown is safe because mln's own GL context keeps the share group alive and `fmm_present` against a destroyed presenter soft-fails through the registry mutex. Task 5 amends the spec.

## File Structure

- `packages/flutter_map_maplibre/android/src/main/cpp/dart_include/` — vendored Dart API DL (new, Task 2)
- `packages/flutter_map_maplibre/android/src/main/cpp/fmm_worker.cpp` — worker thread (new, Tasks 2–3)
- `packages/flutter_map_maplibre/android/src/main/cpp/CMakeLists.txt` — add sources/includes (Task 2)
- `packages/flutter_map_maplibre/lib/src/basemap_renderer.dart` — `create()` → `Future<bool>` (Task 1)
- `packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart` — async create signature (Task 1)
- `packages/flutter_map_maplibre/lib/src/ffi/worker_link.dart` — `WorkerLink` + `FfiWorkerLink` (new, Task 4)
- `packages/flutter_map_maplibre/lib/src/ffi/worker_basemap_renderer.dart` — the facade (new, Task 4)
- `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart` — await create (Task 1), factory + settle-on-issue (Task 5)
- `packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart` — export facade (Task 5)
- `packages/flutter_map_maplibre/example/lib/main.dart` — A/B FAB (Task 6)
- `packages/flutter_map_maplibre/test/worker_basemap_renderer_test.dart` — facade tests (new, Task 4)

---

### Task 1: `BasemapRenderer.create()` becomes `Future<bool>`

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/basemap_renderer.dart:68`
- Modify: `packages/flutter_map_maplibre/lib/src/ffi/ffi_basemap_renderer.dart:167`
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart:323` (`_create`)
- Modify: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart` (fake renderer)

**Interfaces:**
- Produces: `Future<bool> create({required int backTextureAddress, required int presenterId, required int width, required int height, required double scale, required String styleUrl})` on `BasemapRenderer` — Task 4's facade implements this async, the widget awaits it.

- [ ] **Step 1: Change the interface**

In `basemap_renderer.dart`, change the `create` declaration to:

```dart
  /// Creates runtime, map, and render session, attaching the borrowed back
  /// texture. Synchronous on iOS (the future completes before it returns);
  /// a worker-thread round-trip on Android. Returns false on failure
  /// (details land in [diagnostics]).
  Future<bool> create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  });
```

- [ ] **Step 2: Update FfiBasemapRenderer**

In `ffi_basemap_renderer.dart`, change `bool create({` to `Future<bool> create({` and add `async` before the body brace. Body unchanged (a sync body in an async method completes the future synchronously enough for the widget's await). `_failCreate` keeps returning `bool`.

- [ ] **Step 3: Update the widget**

In `maplibre_basemap.dart` `_create`, change:

```dart
    final created = _renderer.create(
```
to
```dart
    final created = await _renderer.create(
```

- [ ] **Step 4: Update the widget-test fake**

In `test/maplibre_basemap_test.dart`, the `_FakeRenderer.create` override becomes `Future<bool> create({...}) async { ... }` returning what it returned before.

- [ ] **Step 5: Run tests, format, commit**

```bash
cd packages/flutter_map_maplibre && fvm flutter test
fvm dart format lib/src/basemap_renderer.dart lib/src/ffi/ffi_basemap_renderer.dart lib/src/maplibre_basemap.dart test/maplibre_basemap_test.dart
git add -A && git commit -m "refactor(maplibre): create() returns Future<bool> for the async worker renderer"
```

Expected: all tests pass (352 baseline).

---

### Task 2: Vendor dart_api_dl + CMake wiring + `fmm_dart_init`

**Files:**
- Create: `packages/flutter_map_maplibre/android/src/main/cpp/dart_include/` (copied)
- Create: `packages/flutter_map_maplibre/android/src/main/cpp/fmm_worker.cpp` (init export only)
- Modify: `packages/flutter_map_maplibre/android/src/main/cpp/CMakeLists.txt`

**Interfaces:**
- Produces: FFI export `intptr_t fmm_dart_init(void* data)` — Task 4's `FfiWorkerLink` calls it once with `NativeApi.initializeApiDLData`.

- [ ] **Step 1: Copy the Dart API DL sources from the pinned SDK**

```bash
cd packages/flutter_map_maplibre/android/src/main/cpp
mkdir -p dart_include
cp -R ~/fvm/versions/3.44.5/bin/cache/dart-sdk/include/* dart_include/
```

(`dart_api_dl.c` includes `internal/dart_api_dl_impl.h`, so copy the whole `include/` tree. These files are BSD-licensed and meant for vendoring.)

- [ ] **Step 2: Create fmm_worker.cpp with just the init export**

```cpp
// fmm_worker.cpp — dedicated owner thread for the mln runtime/map/session.
// The mln C API is owner-thread affine; Dart isolates have no fixed OS
// thread, so the owner must be a thread we control. Dart posts commands
// (strict FIFO, RENDER coalescing only) and receives completions over a
// NativePort. See docs/superpowers/specs/2026-07-26-render-worker-thread-design.md.

#include <cstdint>

#include "dart_api_dl.h"

extern "C" {

__attribute__((visibility("default"))) intptr_t fmm_dart_init(void* data) {
  return Dart_InitializeApiDL(data);
}

}  // extern "C"
```

- [ ] **Step 3: Wire CMake**

In `CMakeLists.txt`: change `project(mln_jni CXX)` to `project(mln_jni C CXX)` (dart_api_dl.c is C); change the library line and includes to:

```cmake
add_library(mln_jni SHARED
  mln_jni.cpp
  fmm_worker.cpp
  dart_include/dart_api_dl.c)

target_include_directories(mln_jni PRIVATE
  "${MLN_PREBUILT}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/dart_include")
```

- [ ] **Step 4: Compile gate**

```bash
cd packages/flutter_map_maplibre/example && fvm flutter build apk --debug --target-platform android-arm64
```

Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "build(maplibre): vendor dart_api_dl and stub fmm_worker.cpp"
```

(If `dart_include/` is huge, that is fine — it is a one-time vendored copy pinned to the SDK that ships the engine.)

---

### Task 3: The worker thread (`fmm_worker.cpp`)

**Files:**
- Modify: `packages/flutter_map_maplibre/android/src/main/cpp/fmm_worker.cpp`

**Interfaces:**
- Consumes: `fmm_attach(int64_t map, int64_t presenter_id, int64_t* out_session)` and `fmm_present(int64_t presenter_id)` — defined in `mln_jni.cpp`, declared here `extern "C"`.
- Produces FFI exports (Task 4 binds them):
  - `int64_t fmm_worker_start(int64_t port)` → opaque worker handle
  - `void fmm_worker_post_create(int64_t worker, int32_t width, int32_t height, double scale, const char* style_url, int64_t presenter_id)`
  - `void fmm_worker_post_pump(int64_t worker)`
  - `void fmm_worker_post_jump(int64_t worker, double lat, double lng, double zoom, double bearing, int64_t gen)`
  - `void fmm_worker_post_render(int64_t worker, int64_t gen)`
  - `void fmm_worker_post_set_style(int64_t worker, const char* url)`
  - `void fmm_worker_post_destroy(int64_t worker)` — worker frees itself after posting `DESTROYED`; never post to the handle again.
- Produces completion messages (Dart `List` of int/double):
  - `CREATED`: `[0, runtimeStatus, mapStatus, setStyleStatus, attachStatus]`
  - `EVENTS`: `[1, updates, idles, needsRepaintKnown, needsRepaint, drawCalls, pumpMs]`
  - `RENDERED`: `[2, gen, renderStatus, renderMs, blitRc, jumpMs]` (blitRc `double`: <0 present error code, else blit ms)
  - `SUPERSEDED`: `[3, gen]`
  - `DESTROYED`: `[4]`

- [ ] **Step 1: Confirm the C API signatures**

Open `packages/flutter_map_maplibre/android/src/main/cpp/prebuilt/include/maplibre_native_c.h` and confirm the exact signatures/field names used below (`mln_runtime_options_default`, `mln_runtime_create`, `mln_map_options_default`, `mln_map_create`, `mln_map_set_style_url`, `mln_map_request_repaint`, `mln_map_jump_to`, `mln_camera_options_default`, `mln_runtime_run_once`, `mln_runtime_poll_event`, `mln_runtime_event` fields `size/type/payload/payload_size`, `mln_runtime_event_render_frame` fields `needs_repaint/stats.draw_call_count`, `mln_render_session_render_update`, `mln_render_session_destroy`, `mln_map_destroy`, `mln_runtime_destroy`). They mirror what `ffi_basemap_renderer.dart` calls through the generated bindings; adjust the code below only where the header disagrees.

- [ ] **Step 2: Write the worker**

Replace `fmm_worker.cpp` with:

```cpp
// fmm_worker.cpp — dedicated owner thread for the mln runtime/map/session.
// The mln C API is owner-thread affine; Dart isolates have no fixed OS
// thread, so the owner must be a thread we control. Dart posts commands
// (strict FIFO, RENDER coalescing only) and receives completions over a
// NativePort. See docs/superpowers/specs/2026-07-26-render-worker-thread-design.md.

#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <maplibre_native_c.h>

#include "dart_api_dl.h"

// Defined in mln_jni.cpp (same shared library).
extern "C" int32_t fmm_attach(int64_t map, int64_t presenter_id,
                              int64_t* out_session);
extern "C" double fmm_present(int64_t presenter_id);

namespace {

// Completion kinds — first element of every posted message. Mirrored in
// worker_basemap_renderer.dart; keep in sync.
constexpr int64_t kCreated = 0;
constexpr int64_t kEvents = 1;
constexpr int64_t kRendered = 2;
constexpr int64_t kSuperseded = 3;
constexpr int64_t kDestroyed = 4;

// ABI constants from the vendored headers (same values the Dart renderer
// uses; see ffi_basemap_renderer.dart).
constexpr int32_t kStatusOk = 0;             // MLN_STATUS_OK
constexpr int32_t kEventMapIdle = 8;         // MLN_RUNTIME_EVENT_MAP_IDLE
constexpr int32_t kEventUpdateAvailable = 9; // ..._MAP_RENDER_UPDATE_AVAILABLE
constexpr int32_t kEventFrameFinished = 14;  // ..._MAP_RENDER_FRAME_FINISHED
constexpr int32_t kCameraCenter = 1 << 0;
constexpr int32_t kCameraZoom = 1 << 1;
constexpr int32_t kCameraBearing = 1 << 2;
constexpr int32_t kMapModeContinuous = 0;

// Local failure codes (never overlap mln statuses, which are >= 0).
constexpr int32_t kErrNoSession = -100;

double NowMs() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

enum class CmdType { kCreate, kPump, kJump, kRender, kSetStyle, kDestroy };

struct Command {
  CmdType type;
  int32_t width = 0;
  int32_t height = 0;
  double scale = 1.0;
  int64_t presenter_id = 0;
  std::string url;  // kCreate style URL / kSetStyle
  double lat = 0, lng = 0, zoom = 0, bearing = 0;
  int64_t gen = 0;  // kJump / kRender
};

// A value in a completion message: int64 or double.
struct Val {
  bool is_double;
  int64_t i;
  double d;
};
Val I(int64_t v) { return Val{false, v, 0}; }
Val D(double v) { return Val{true, 0, v}; }

class Worker {
 public:
  explicit Worker(Dart_Port port) : port_(port) {
    std::thread([this] { Run(); }).detach();
  }

  void Post(Command cmd) {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push_back(std::move(cmd));
    cv_.notify_one();
  }

 private:
  void Run() {
    for (;;) {
      Command cmd;
      bool superseded = false;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this] { return !queue_.empty(); });
        cmd = std::move(queue_.front());
        queue_.pop_front();
        if (cmd.type == CmdType::kRender) {
          // Latest-wins for the expensive op: a newer RENDER in the queue
          // supersedes this one. JUMPs are cheap and all apply in order.
          for (const Command& pending : queue_) {
            if (pending.type == CmdType::kRender) {
              superseded = true;
              break;
            }
          }
        }
      }
      if (superseded) {
        PostMessage({I(kSuperseded), I(cmd.gen)});
        continue;
      }
      switch (cmd.type) {
        case CmdType::kCreate:
          Create(cmd);
          break;
        case CmdType::kPump:
          Pump();
          break;
        case CmdType::kJump:
          Jump(cmd);
          break;
        case CmdType::kRender:
          Render(cmd);
          break;
        case CmdType::kSetStyle:
          SetStyle(cmd);
          break;
        case CmdType::kDestroy:
          Destroy();
          PostMessage({I(kDestroyed)});
          delete this;
          return;
      }
    }
  }

  void Create(const Command& cmd) {
    mln_runtime_options options = mln_runtime_options_default();
    options.cache_path = ":memory:";
    int32_t runtime_status = mln_runtime_create(&options, &runtime_);
    int32_t map_status = -1, style_status = -1, attach_status = -1;
    if (runtime_status == kStatusOk) {
      mln_map_options map_options = mln_map_options_default();
      map_options.width = cmd.width;
      map_options.height = cmd.height;
      map_options.scale_factor = cmd.scale;
      map_options.map_mode = kMapModeContinuous;
      map_status = mln_map_create(runtime_, &map_options, &map_);
    }
    if (map_status == kStatusOk) {
      style_status = mln_map_set_style_url(map_, cmd.url.c_str());
      mln_map_request_repaint(map_);
      int64_t session_addr = 0;
      attach_status = fmm_attach(reinterpret_cast<int64_t>(map_),
                                 cmd.presenter_id, &session_addr);
      session_ = reinterpret_cast<mln_render_session*>(session_addr);
      presenter_id_ = cmd.presenter_id;
    }
    if (runtime_status != kStatusOk || map_status != kStatusOk ||
        attach_status != kStatusOk) {
      Destroy();  // tear down partials; the facade will post kDestroy too
    }
    PostMessage({I(kCreated), I(runtime_status), I(map_status),
                 I(style_status), I(attach_status)});
  }

  void Pump() {
    if (runtime_ == nullptr) return;
    const double t0 = NowMs();
    mln_runtime_run_once(runtime_);
    const double pump_ms = NowMs() - t0;
    int64_t updates = 0, idles = 0;
    int64_t needs_repaint_known = 0, needs_repaint = 0;
    int64_t draw_calls = last_draw_calls_;
    for (;;) {
      mln_runtime_event event;
      std::memset(&event, 0, sizeof event);
      event.size = sizeof event;
      bool has = false;
      if (mln_runtime_poll_event(runtime_, &event, &has) != kStatusOk || !has) {
        break;
      }
      switch (event.type) {
        case kEventUpdateAvailable:
          updates++;
          break;
        case kEventMapIdle:
          idles++;
          break;
        case kEventFrameFinished:
          if (event.payload != nullptr &&
              event.payload_size >=
                  sizeof(mln_runtime_event_render_frame)) {
            const auto* frame =
                reinterpret_cast<const mln_runtime_event_render_frame*>(
                    event.payload);
            needs_repaint_known = 1;
            needs_repaint = frame->needs_repaint ? 1 : 0;
            draw_calls = frame->stats.draw_call_count;
          }
          break;
        default:
          break;
      }
    }
    last_draw_calls_ = draw_calls;
    PostMessage({I(kEvents), I(updates), I(idles), I(needs_repaint_known),
                 I(needs_repaint), I(draw_calls), D(pump_ms)});
  }

  void Jump(const Command& cmd) {
    if (map_ == nullptr) return;
    mln_camera_options camera = mln_camera_options_default();
    camera.fields = kCameraCenter | kCameraZoom | kCameraBearing;
    camera.latitude = cmd.lat;
    camera.longitude = cmd.lng;
    camera.zoom = cmd.zoom;
    camera.bearing = cmd.bearing;
    const double t0 = NowMs();
    mln_map_jump_to(map_, &camera);
    last_jump_ms_ = NowMs() - t0;
    mln_map_request_repaint(map_);
  }

  void Render(const Command& cmd) {
    if (session_ == nullptr) {
      PostMessage({I(kRendered), I(cmd.gen), I(kErrNoSession), D(0.0),
                   D(-1.0), D(0.0)});
      return;
    }
    const double t0 = NowMs();
    const int32_t status = mln_render_session_render_update(session_);
    const double render_ms = NowMs() - t0;
    double blit_rc = -1.0;
    if (status == kStatusOk) blit_rc = fmm_present(presenter_id_);
    PostMessage({I(kRendered), I(cmd.gen), I(status), D(render_ms),
                 D(blit_rc), D(last_jump_ms_)});
  }

  void SetStyle(const Command& cmd) {
    if (map_ == nullptr) return;
    mln_map_set_style_url(map_, cmd.url.c_str());
    mln_map_request_repaint(map_);
  }

  void Destroy() {
    if (session_ != nullptr) {
      mln_render_session_destroy(session_);
      session_ = nullptr;
    }
    if (map_ != nullptr) {
      mln_map_destroy(map_);
      map_ = nullptr;
    }
    if (runtime_ != nullptr) {
      mln_runtime_destroy(runtime_);
      runtime_ = nullptr;
    }
  }

  void PostMessage(std::initializer_list<Val> values) {
    std::vector<Dart_CObject> items(values.size());
    std::vector<Dart_CObject*> pointers(values.size());
    size_t i = 0;
    for (const Val& v : values) {
      if (v.is_double) {
        items[i].type = Dart_CObject_kDouble;
        items[i].value.as_double = v.d;
      } else {
        items[i].type = Dart_CObject_kInt64;
        items[i].value.as_int64 = v.i;
      }
      pointers[i] = &items[i];
      i++;
    }
    Dart_CObject message;
    message.type = Dart_CObject_kArray;
    message.value.as_array.length = static_cast<intptr_t>(items.size());
    message.value.as_array.values = pointers.data();
    Dart_PostCObject_DL(port_, &message);
  }

  const Dart_Port port_;
  std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<Command> queue_;

  // Owner-thread state: touched only on the worker thread after construction.
  mln_runtime* runtime_ = nullptr;
  mln_map* map_ = nullptr;
  mln_render_session* session_ = nullptr;
  int64_t presenter_id_ = 0;
  int64_t last_draw_calls_ = 0;
  double last_jump_ms_ = 0;
};

Worker* AsWorker(int64_t handle) { return reinterpret_cast<Worker*>(handle); }

}  // namespace

extern "C" {

__attribute__((visibility("default"))) intptr_t fmm_dart_init(void* data) {
  return Dart_InitializeApiDL(data);
}

__attribute__((visibility("default"))) int64_t fmm_worker_start(int64_t port) {
  return reinterpret_cast<int64_t>(new Worker(static_cast<Dart_Port>(port)));
}

__attribute__((visibility("default"))) void fmm_worker_post_create(
    int64_t worker, int32_t width, int32_t height, double scale,
    const char* style_url, int64_t presenter_id) {
  Command cmd;
  cmd.type = CmdType::kCreate;
  cmd.width = width;
  cmd.height = height;
  cmd.scale = scale;
  cmd.url = style_url;  // copied on the calling thread; caller frees after
  cmd.presenter_id = presenter_id;
  AsWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_worker_post_pump(
    int64_t worker) {
  Command cmd;
  cmd.type = CmdType::kPump;
  AsWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_worker_post_jump(
    int64_t worker, double lat, double lng, double zoom, double bearing,
    int64_t gen) {
  Command cmd;
  cmd.type = CmdType::kJump;
  cmd.lat = lat;
  cmd.lng = lng;
  cmd.zoom = zoom;
  cmd.bearing = bearing;
  cmd.gen = gen;
  AsWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_worker_post_render(
    int64_t worker, int64_t gen) {
  Command cmd;
  cmd.type = CmdType::kRender;
  cmd.gen = gen;
  AsWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_worker_post_set_style(
    int64_t worker, const char* url) {
  Command cmd;
  cmd.type = CmdType::kSetStyle;
  cmd.url = url;
  AsWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_worker_post_destroy(
    int64_t worker) {
  Command cmd;
  cmd.type = CmdType::kDestroy;
  AsWorker(worker)->Post(std::move(cmd));
}

}  // extern "C"
```

Notes for the implementer:
- `CmdType` and `Command` must be visible to the `extern "C"` block — they are, via the anonymous namespace above it (`using` not needed; qualify as written).
- If the header check (Step 1) shows a field/name difference, fix the code to match the header, not vice versa.

- [ ] **Step 3: Compile gate**

```bash
cd packages/flutter_map_maplibre/example && fvm flutter build apk --debug --target-platform android-arm64
```

Expected: builds clean. Also verify the exports survived the linker:

```bash
~/Library/Android/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-nm -D --defined-only \
  build/app/intermediates/merged_native_libs/debug/mergeDebugNativeLibs/out/lib/arm64-v8a/libmln_jni.so 2>/dev/null | grep fmm_worker || \
  echo "check the .so path under example/build/ (find . -name libmln_jni.so)"
```

Expected: `fmm_worker_start`, all six `fmm_worker_post_*`, `fmm_dart_init` listed.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(maplibre): native render worker thread with FIFO command queue"
```

---

### Task 4: `WorkerLink` + `WorkerBasemapRenderer` facade + tests

**Files:**
- Create: `packages/flutter_map_maplibre/lib/src/ffi/worker_link.dart`
- Create: `packages/flutter_map_maplibre/lib/src/ffi/worker_basemap_renderer.dart`
- Test: `packages/flutter_map_maplibre/test/worker_basemap_renderer_test.dart`

**Interfaces:**
- Consumes: Task 3's FFI exports; Task 1's `Future<bool> create(...)`; existing pure logic `decideTick`, `decideSleep`, `frameCapSatisfied` from `basemap_renderer.dart`; `maplibreZoom`/`maplibreBearing` from `camera_conventions.dart`.
- Produces: `class WorkerBasemapRenderer implements BasemapRenderer` with constructor `WorkerBasemapRenderer({WorkerLink? link, Duration Function()? arrivalClock})` and `@visibleForTesting void handleCompletion(Object? message)`. Task 5 wires it as the Android default; Task 6 constructs it in the example.

- [ ] **Step 1: Write worker_link.dart**

```dart
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'mln_library.dart';

typedef _InitNative = IntPtr Function(Pointer<Void>);
typedef _StartNative = Int64 Function(Int64);
typedef _PostCreateNative =
    Void Function(Int64, Int32, Int32, Double, Pointer<Utf8>, Int64);
typedef _PostVoidNative = Void Function(Int64);
typedef _PostJumpNative =
    Void Function(Int64, Double, Double, Double, Double, Int64);
typedef _PostRenderNative = Void Function(Int64, Int64);
typedef _PostStyleNative = Void Function(Int64, Pointer<Utf8>);

/// The command side of the worker protocol, injectable so the facade's
/// state machine is testable without native code. Cameras arrive here
/// already converted to mln conventions (raw doubles): the link is dumb.
abstract interface class WorkerLink {
  /// Starts a fresh worker posting completions to [completions].
  /// Returns false when the native side is unavailable (init failed).
  bool start(SendPort completions);

  void postCreate({
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
    required int presenterId,
  });
  void postPump();
  void postJump({
    required double lat,
    required double lng,
    required double zoom,
    required double bearing,
    required int gen,
  });
  void postRender(int gen);
  void postSetStyle(String url);

  /// After this the worker frees itself once the queue drains; this link
  /// instance must not be posted to again (the facade starts a fresh link
  /// per session).
  void postDestroy();
}

/// dart:ffi implementation over fmm_worker_* (Android only).
class FfiWorkerLink implements WorkerLink {
  static final int Function(Pointer<Void>) _init = mlnLibrary
      .lookupFunction<_InitNative, int Function(Pointer<Void>)>(
        'fmm_dart_init',
      );
  static final int Function(int) _start = mlnLibrary
      .lookupFunction<_StartNative, int Function(int)>('fmm_worker_start');
  static final void Function(int, int, int, double, Pointer<Utf8>, int)
  _postCreate = mlnLibrary.lookupFunction<
    _PostCreateNative,
    void Function(int, int, int, double, Pointer<Utf8>, int)
  >('fmm_worker_post_create');
  static final void Function(int) _postPump = mlnLibrary
      .lookupFunction<_PostVoidNative, void Function(int)>(
        'fmm_worker_post_pump',
      );
  static final void Function(int, double, double, double, double, int)
  _postJump = mlnLibrary.lookupFunction<
    _PostJumpNative,
    void Function(int, double, double, double, double, int)
  >('fmm_worker_post_jump');
  static final void Function(int, int) _postRender = mlnLibrary
      .lookupFunction<_PostRenderNative, void Function(int, int)>(
        'fmm_worker_post_render',
      );
  static final void Function(int, Pointer<Utf8>) _postStyle = mlnLibrary
      .lookupFunction<_PostStyleNative, void Function(int, Pointer<Utf8>)>(
        'fmm_worker_post_set_style',
      );
  static final void Function(int) _postDestroy = mlnLibrary
      .lookupFunction<_PostVoidNative, void Function(int)>(
        'fmm_worker_post_destroy',
      );

  static bool? _dartApiReady;

  int _worker = 0;

  @override
  bool start(SendPort completions) {
    _dartApiReady ??= _init(NativeApi.initializeApiDLData) == 0;
    if (!_dartApiReady!) return false;
    _worker = _start(completions.nativePort);
    return _worker != 0;
  }

  @override
  void postCreate({
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
    required int presenterId,
  }) {
    final url = styleUrl.toNativeUtf8();
    _postCreate(_worker, width, height, scale, url, presenterId);
    calloc.free(url); // the worker copied it on this thread
  }

  @override
  void postPump() => _postPump(_worker);

  @override
  void postJump({
    required double lat,
    required double lng,
    required double zoom,
    required double bearing,
    required int gen,
  }) => _postJump(_worker, lat, lng, zoom, bearing, gen);

  @override
  void postRender(int gen) => _postRender(_worker, gen);

  @override
  void postSetStyle(String url) {
    final native = url.toNativeUtf8();
    _postStyle(_worker, native);
    calloc.free(native);
  }

  @override
  void postDestroy() => _postDestroy(_worker);
}
```

- [ ] **Step 2: Write the failing tests**

`test/worker_basemap_renderer_test.dart`. The fake link records calls; tests drive completions through `handleCompletion` directly (the real ReceivePort listener calls the same method). A controllable arrival clock drives the busy-pipeline heuristic.

```dart
import 'package:flutter_map/flutter_map.dart';
// src imports: the public exports only land in Task 5.
import 'package:flutter_map_maplibre/src/ffi/worker_basemap_renderer.dart';
import 'package:flutter_map_maplibre/src/ffi/worker_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

MapCamera cameraAt(double lat, double lng, {double zoom = 14}) =>
    MapCamera(
      crs: const Epsg3857(),
      center: LatLng(lat, lng),
      zoom: zoom,
      rotation: 0,
      nonRotatedSize: const Size(400, 800),
      size: const Size(400, 800),
    );

class FakeLink implements WorkerLink {
  final calls = <String>[];
  bool startResult = true;

  @override
  bool start(completions) {
    calls.add('start');
    return startResult;
  }

  @override
  void postCreate({
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
    required int presenterId,
  }) => calls.add('create:$width:$height:$presenterId');

  @override
  void postPump() => calls.add('pump');

  @override
  void postJump({
    required double lat,
    required double lng,
    required double zoom,
    required double bearing,
    required int gen,
  }) => calls.add('jump:$gen');

  @override
  void postRender(int gen) => calls.add('render:$gen');

  @override
  void postSetStyle(String url) => calls.add('style:$url');

  @override
  void postDestroy() => calls.add('destroy');
}

Future<WorkerBasemapRenderer> createdRenderer(
  FakeLink link, {
  Duration Function()? arrivalClock,
}) async {
  final renderer = WorkerBasemapRenderer(
    link: link,
    arrivalClock: arrivalClock,
  );
  final pending = renderer.create(
    backTextureAddress: 7,
    presenterId: 42,
    width: 400,
    height: 800,
    scale: 3.0,
    styleUrl: 'https://example.com/style.json',
  );
  renderer.handleCompletion([0, 0, 0, 0, 0]); // CREATED, all OK
  expect(await pending, isTrue);
  return renderer;
}

void main() {
  test('create posts start+create and completes on CREATED', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    expect(link.calls, ['start', 'create:400:800:42']);
    expect(renderer.isReady, isTrue);
  });

  test('create failure completes false and destroys the worker', () async {
    final link = FakeLink();
    final renderer = WorkerBasemapRenderer(link: link);
    final pending = renderer.create(
      backTextureAddress: 7,
      presenterId: 42,
      width: 400,
      height: 800,
      scale: 3.0,
      styleUrl: 's',
    );
    renderer.handleCompletion([0, 0, 0, 0, 5]); // attach failed
    expect(await pending, isFalse);
    expect(renderer.isReady, isFalse);
    expect(link.calls.last, 'destroy');
  });

  test('render posts pump+jump+render and never re-posts the same camera',
      () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    link.calls.clear();
    final camera = cameraAt(59.43, 24.75);
    expect(renderer.render(camera), isFalse); // async: never "on screen now"
    expect(link.calls, ['pump', 'jump:1', 'render:1']);
    link.calls.clear();
    renderer.render(camera); // same camera, still in flight
    expect(link.calls, isEmpty);
  });

  test('RENDERED publishes through the latency FIFO on a busy pipeline',
      () async {
    final link = FakeLink();
    var arrival = Duration.zero;
    final renderer =
        await createdRenderer(link, arrivalClock: () => arrival);
    final a = cameraAt(59.43, 24.75);
    final b = cameraAt(59.44, 24.76);
    renderer.render(a);
    renderer.render(b);
    // Two RENDERED arrive 8ms apart: busy pipeline, FIFO depth 1 holds the
    // newest back one promotion.
    arrival = const Duration(milliseconds: 8);
    renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]);
    arrival = const Duration(milliseconds: 16);
    renderer.handleCompletion([2, 2, 0, 10.0, 1.5, 0.1]);
    expect(renderer.lastRenderedCamera!.center.latitude, a.center.latitude);
    renderer.tick(); // idle tick promotes the pending frame
    expect(renderer.lastRenderedCamera!.center.latitude, b.center.latitude);
  });

  test('RENDERED after an idle gap publishes immediately', () async {
    final link = FakeLink();
    var arrival = Duration.zero;
    final renderer =
        await createdRenderer(link, arrivalClock: () => arrival);
    final a = cameraAt(59.43, 24.75);
    renderer.render(a);
    arrival = const Duration(milliseconds: 100); // idle > 25ms
    renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]);
    expect(renderer.lastRenderedCamera!.center.latitude, a.center.latitude);
  });

  test('SUPERSEDED is never published and is counted', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.render(cameraAt(59.43, 24.75));
    renderer.handleCompletion([3, 1]); // SUPERSEDED gen 1
    expect(renderer.lastRenderedCamera, isNull);
    expect(renderer.diagnostics()['superseded'], 1);
  });

  test('frameCap defers the RENDER post but not the JUMP', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    // First render uncapped so _sincePresent resets at a known point; only
    // then set the cap — the second render lands well inside the window.
    renderer.render(cameraAt(59.43, 24.75));
    renderer.frameCap = const Duration(seconds: 100);
    link.calls.clear();
    renderer.render(cameraAt(59.44, 24.76));
    expect(link.calls, ['pump', 'jump:2']); // capped: no render post
    expect(renderer.diagnostics()['cappedTicks'], 1);
  });

  test('EVENTS drives flags and canSleep', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    expect(renderer.canSleep, isFalse); // no idle seen yet
    final camera = cameraAt(59.43, 24.75);
    renderer.render(camera);
    renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]); // publish
    renderer.tick(); // promote if pending
    renderer.handleCompletion([1, 0, 1, 1, 0, 50, 0.5]); // EVENTS: idle seen
    expect(renderer.canSleep, isTrue);
    renderer.handleCompletion([1, 1, 0, 0, 0, 50, 0.5]); // update available
    expect(renderer.canSleep, isFalse);
  });

  test('tick returns true only when new content arrived', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.render(cameraAt(59.43, 24.75));
    expect(renderer.tick(), isFalse);
    renderer.handleCompletion([2, 1, 0, 10.0, 1.5, 0.1]);
    expect(renderer.tick(), isTrue);
    expect(renderer.tick(), isFalse);
  });

  test('failed RENDERED does not publish and counts the streak', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.render(cameraAt(59.43, 24.75));
    renderer.handleCompletion([2, 1, 7, 10.0, -3.0, 0.1]); // render failed
    expect(renderer.lastRenderedCamera, isNull);
    expect(renderer.diagnostics()['failStreak'], 1);
    expect(renderer.canSleep, isFalse); // unpublished jump vetoes sleep
  });

  test('dispose posts destroy; create-after-dispose starts fresh', () async {
    final link = FakeLink();
    final renderer = await createdRenderer(link);
    renderer.dispose();
    expect(link.calls.last, 'destroy');
    renderer.handleCompletion([4]); // DESTROYED
    expect(renderer.isReady, isFalse);
    final pending = renderer.create(
      backTextureAddress: 7,
      presenterId: 43,
      width: 400,
      height: 800,
      scale: 3.0,
      styleUrl: 's',
    );
    renderer.handleCompletion([0, 0, 0, 0, 0]);
    expect(await pending, isTrue);
    expect(link.calls.where((c) => c == 'start').length, 2);
  });
}
```

Adjust `MapCamera` construction to whatever the existing tests in this package use (see `test/maplibre_basemap_test.dart` / `render_admission_test.dart`) — reuse their helper if one exists rather than inventing a new one.

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd packages/flutter_map_maplibre && fvm flutter test test/worker_basemap_renderer_test.dart
```

Expected: compile errors — `WorkerBasemapRenderer`/`WorkerLink` undefined.

- [ ] **Step 4: Write worker_basemap_renderer.dart**

```dart
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';

import '../basemap_renderer.dart';
import '../camera_conventions.dart';
import 'worker_link.dart';

/// [BasemapRenderer] over the native render worker thread (Android).
///
/// The worker owns runtime/map/session on a dedicated OS thread (the mln C
/// API is owner-thread affine and Dart isolates have no fixed OS thread).
/// This facade keeps the exact decision state machine of FfiBasemapRenderer
/// in Dart — flags, latency FIFO, diagnostics — but every flag update comes
/// from a completion message instead of a synchronous return value. Dart
/// still chooses every camera and places every texture; only *when* renders
/// execute moved.
class WorkerBasemapRenderer implements BasemapRenderer {
  WorkerBasemapRenderer({WorkerLink? link, Duration Function()? arrivalClock})
    : _makeLink = (link == null ? FfiWorkerLink.new : () => link),
      _arrivalClock = arrivalClock;

  /// Completion message kinds — first element of every port message.
  /// Mirrored in fmm_worker.cpp; keep in sync.
  static const _kCreated = 0;
  static const _kEvents = 1;
  static const _kRendered = 2;
  static const _kSuperseded = 3;
  static const _kDestroyed = 4;

  /// See FfiBasemapRenderer.androidPresentLatencyFrames — same latch model,
  /// now keyed on completion arrival times. Re-tune on device.
  static int presentLatencyFrames = 1;

  /// Completions arriving closer together than this ran against a busy
  /// pipeline (same constant and rationale as FfiBasemapRenderer).
  static const _pipelineBusy = Duration(milliseconds: 25);

  final WorkerLink Function() _makeLink;
  final Duration Function()? _arrivalClock;
  final Stopwatch _arrivalStopwatch = Stopwatch()..start();
  Duration get _now => _arrivalClock?.call() ?? _arrivalStopwatch.elapsed;

  WorkerLink? _link;
  ReceivePort? _port;
  Completer<bool>? _createCompleter;
  Timer? _portCloseFallback;

  bool _ready = false;

  int _gen = 0;
  final Map<int, MapCamera> _inFlight = {};
  final Map<int, Duration> _issuedAt = {};
  MapCamera? _jumpedCamera;
  MapCamera? _lastRenderedCamera;
  final List<MapCamera> _pendingRenderedCameras = [];
  Duration _lastArrival = Duration.zero;

  bool _updateAvailable = false;
  bool _needsRepaint = false;
  bool _idleSinceLastJump = false;
  bool _renderPostedSinceLastTick = false;
  bool _presentedSinceLastTick = false;

  @override
  Duration? frameCap;
  final Stopwatch _sincePresent = Stopwatch()..start();

  // Diagnostics, mirroring FfiBasemapRenderer where the concept survives.
  final _diagnostics = <String, Object?>{};
  int _frameCount = 0;
  int _cameraRenders = 0;
  int _linkRenders = 0;
  int _skippedTicks = 0;
  int _cappedTicks = 0;
  int _idleEvents = 0;
  int _superseded = 0;
  int _drawCalls = 0;
  int _failStreak = 0;
  double _maxRenderMs = 0;
  int _steadyFrames = 0;
  double _steadyRenderMs = 0;
  double _steadyMaxMs = 0;
  double? _renderMs;
  double? _blitMs;
  double? _pumpMs;
  double? _jumpMs;
  double? _completionLagMs;
  double _completionLagMsMax = 0;

  @override
  bool get isReady => _ready;

  @override
  MapCamera? get lastRenderedCamera => _lastRenderedCamera;

  @override
  bool get canSleep =>
      _ready &&
      decideSleep(
        idleSinceLastJump: _idleSinceLastJump,
        updateAvailable: _updateAvailable,
        needsRepaint: _needsRepaint,
        unpublishedJump: !identical(_jumpedCamera, _lastRenderedCamera),
      );

  @override
  Future<bool> create({
    required int backTextureAddress,
    required int presenterId,
    required int width,
    required int height,
    required double scale,
    required String styleUrl,
  }) {
    assert(!_ready, 'dispose before re-creating');
    _resetSessionState();
    final link = _makeLink();
    final port = ReceivePort();
    if (!link.start(port.sendPort)) {
      port.close();
      _diagnostics['workerStartFailed'] = true;
      return Future.value(false);
    }
    _link = link;
    _port = port;
    port.listen(handleCompletion);
    final completer = Completer<bool>();
    _createCompleter = completer;
    link.postCreate(
      width: width,
      height: height,
      scale: scale,
      styleUrl: styleUrl,
      presenterId: presenterId,
    );
    return completer.future;
  }

  void _resetSessionState() {
    _gen = 0;
    _inFlight.clear();
    _issuedAt.clear();
    _jumpedCamera = null;
    _lastRenderedCamera = null;
    _pendingRenderedCameras.clear();
    _updateAvailable = false;
    _needsRepaint = false;
    _idleSinceLastJump = false;
    _renderPostedSinceLastTick = false;
    _presentedSinceLastTick = false;
    _failStreak = 0;
  }

  static bool _sameCamera(MapCamera? a, MapCamera b) =>
      a != null &&
      a.center.latitude == b.center.latitude &&
      a.center.longitude == b.center.longitude &&
      a.zoom == b.zoom &&
      a.rotation == b.rotation;

  @override
  bool render(MapCamera camera) {
    final link = _link;
    if (!_ready || link == null) return false;
    // Settled or already in flight: nothing to issue. Unlike the sync
    // renderer this returns false even when the front buffer already shows
    // [camera] — the Android widget path never trusts the sync-present
    // shortcut anyway (syncPresent = false).
    final newestRendered = _pendingRenderedCameras.isNotEmpty
        ? _pendingRenderedCameras.last
        : _lastRenderedCamera;
    if (_sameCamera(newestRendered, camera)) return false;
    if (_sameCamera(_jumpedCamera, camera)) return false;

    link.postPump();
    _gen++;
    link.postJump(
      lat: camera.center.latitude,
      lng: camera.center.longitude,
      zoom: maplibreZoom(camera.zoom),
      bearing: maplibreBearing(camera.rotation),
      gen: _gen,
    );
    _jumpedCamera = camera;
    _idleSinceLastJump = false;

    if (!frameCapSatisfied(
      frameCap: frameCap,
      sinceLastPresent: _sincePresent.elapsed,
    )) {
      _cappedTicks++;
      return false;
    }
    _postRender(link, _gen, camera);
    _cameraRenders++;
    return false;
  }

  void _postRender(WorkerLink link, int gen, MapCamera camera) {
    _sincePresent.reset();
    _inFlight[gen] = camera;
    _issuedAt[gen] = _now;
    link.postRender(gen);
    _renderPostedSinceLastTick = true;
  }

  @override
  bool tick() {
    final link = _link;
    if (!_ready || link == null) return false;
    link.postPump();
    final decision = decideTick(
      updateAvailable: _updateAvailable,
      needsRepaint: _needsRepaint,
      renderedSinceLastTick: _renderPostedSinceLastTick,
    );
    _renderPostedSinceLastTick = false;
    switch (decision) {
      case TickDecision.skipIdle:
      case TickDecision.skipRenderedThisFrame:
        // One tick = one engine frame — the latch cadence; drain one entry.
        if (_pendingRenderedCameras.isNotEmpty) {
          _lastRenderedCamera = _pendingRenderedCameras.removeAt(0);
        }
        _skippedTicks++;
      case TickDecision.render:
        if (!frameCapSatisfied(
          frameCap: frameCap,
          sinceLastPresent: _sincePresent.elapsed,
        )) {
          _cappedTicks++;
        } else {
          final jumped = _jumpedCamera;
          if (jumped != null) {
            _gen++;
            _postRender(link, _gen, jumped);
            _linkRenders++;
          }
        }
    }
    final presented = _presentedSinceLastTick;
    _presentedSinceLastTick = false;
    return presented;
  }

  @override
  bool pumpWork() {
    final link = _link;
    if (!_ready || link == null) return false;
    link.postPump();
    // Flags are one round-trip stale; the next insurance-pump tick (or any
    // completion-driven wake) observes the fresh ones.
    return _updateAvailable || _needsRepaint;
  }

  @override
  void setStyle(String styleUrl) {
    final link = _link;
    if (!_ready || link == null) return;
    link.postSetStyle(styleUrl);
    _idleSinceLastJump = false;
  }

  /// Handles one completion message from the worker. Public for tests; the
  /// ReceivePort listener is exactly this method.
  @visibleForTesting
  void handleCompletion(Object? message) {
    final list = message as List<Object?>;
    switch (list[0] as int) {
      case _kCreated:
        _diagnostics['runtimeCreateStatus'] = list[1];
        _diagnostics['mapCreateStatus'] = list[2];
        _diagnostics['setStyleStatus'] = list[3];
        _diagnostics['attachStatus'] = list[4];
        final ok =
            list[1] == 0 && list[2] == 0 && list[3] == 0 && list[4] == 0;
        _ready = ok;
        final completer = _createCompleter;
        _createCompleter = null;
        if (!ok) _teardownLink();
        completer?.complete(ok);
      case _kEvents:
        if ((list[1] as int) > 0) _updateAvailable = true;
        final idles = list[2] as int;
        if (idles > 0) {
          _idleEvents += idles;
          _idleSinceLastJump = true;
        }
        if (list[3] == 1) _needsRepaint = list[4] == 1;
        _drawCalls = list[5] as int;
        _pumpMs = _ewma(_pumpMs, list[6] as double);
      case _kRendered:
        _handleRendered(
          gen: list[1] as int,
          status: list[2] as int,
          renderMs: list[3] as double,
          blitRc: list[4] as double,
          jumpMs: list[5] as double,
        );
      case _kSuperseded:
        final gen = list[1] as int;
        _inFlight.remove(gen);
        _issuedAt.remove(gen);
        _superseded++;
      case _kDestroyed:
        _closePort();
    }
  }

  void _handleRendered({
    required int gen,
    required int status,
    required double renderMs,
    required double blitRc,
    required double jumpMs,
  }) {
    final camera = _inFlight.remove(gen);
    final issuedAt = _issuedAt.remove(gen);
    if (issuedAt != null) {
      final lag = (_now - issuedAt).inMicroseconds / 1000.0;
      _completionLagMs = _ewma(_completionLagMs, lag);
      if (lag > _completionLagMsMax) _completionLagMsMax = lag;
    }
    _diagnostics['lastRenderStatus'] = status;
    if (status != 0 || blitRc < 0) {
      if (blitRc < 0) _diagnostics['presentError'] = blitRc;
      _failStreak++;
      _diagnostics['failStreak'] = _failStreak;
      if (_failStreak == 1 || _failStreak % 240 == 0) {
        debugPrint('MLNERR worker render status=$status blit=$blitRc '
            'streak=$_failStreak');
      }
      return;
    }
    _diagnostics.remove('presentError');
    if (_failStreak > 0) {
      debugPrint('MLNERR recovered after streak=$_failStreak');
      _failStreak = 0;
      _diagnostics.remove('failStreak');
    }
    _updateAvailable = false;
    _frameCount++;
    _renderMs = _ewma(_renderMs, renderMs);
    _blitMs = _ewma(_blitMs, blitRc);
    _jumpMs = _ewma(_jumpMs, jumpMs);
    if (renderMs > _maxRenderMs) _maxRenderMs = renderMs;
    if (_frameCount > 30) {
      _steadyFrames++;
      _steadyRenderMs += renderMs;
      if (renderMs > _steadyMaxMs) _steadyMaxMs = renderMs;
    }
    _presentedSinceLastTick = true;
    if (camera == null) return;

    // The latch model, keyed on completion arrival gaps: back-to-back
    // completions mean a busy pipeline (the engine latches a frame late);
    // an isolated completion after an idle gap is on screen this frame.
    final gap = _now - _lastArrival;
    _lastArrival = _now;
    if (presentLatencyFrames > 0 && gap < _pipelineBusy) {
      _pendingRenderedCameras.add(camera);
      while (_pendingRenderedCameras.length > presentLatencyFrames) {
        _lastRenderedCamera = _pendingRenderedCameras.removeAt(0);
      }
    } else {
      _pendingRenderedCameras.clear();
      _lastRenderedCamera = camera;
    }
  }

  static double? _ewma(double? prev, double value) =>
      prev == null ? value : prev * 0.8 + value * 0.2;

  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  @override
  Map<String, Object?> diagnostics() {
    return <String, Object?>{
      ..._diagnostics,
      'frameCount': _frameCount,
      'cameraRenders': _cameraRenders,
      'linkRenders': _linkRenders,
      'skippedTicks': _skippedTicks,
      'cappedTicks': _cappedTicks,
      'idleEvents': _idleEvents,
      'needsRepaint': _needsRepaint,
      'drawCalls': _drawCalls,
      'superseded': _superseded,
      'rendersInFlight': _inFlight.length,
      'renderMsMax': _round2(_maxRenderMs),
      if (_steadyFrames > 0) ...{
        'renderMsAvgSteady': _round2(_steadyRenderMs / _steadyFrames),
        'renderMsMaxSteady': _round2(_steadyMaxMs),
      },
      if (_renderMs != null) 'renderMs': _round2(_renderMs!),
      if (_blitMs != null) 'blitMs': _round2(_blitMs!),
      if (_pumpMs != null) 'pumpMs': _round2(_pumpMs!),
      if (_jumpMs != null) 'jumpMs': _round2(_jumpMs!),
      if (_completionLagMs != null) ...{
        'completionLagMs': _round2(_completionLagMs!),
        'completionLagMsMax': _round2(_completionLagMsMax),
      },
    };
  }

  void _teardownLink() {
    _link?.postDestroy();
    _link = null;
    _ready = false;
    // If DESTROYED never arrives (engine teardown races), don't leak the
    // port — an open ReceivePort pins the isolate.
    _portCloseFallback ??= Timer(const Duration(seconds: 2), _closePort);
  }

  void _closePort() {
    _portCloseFallback?.cancel();
    _portCloseFallback = null;
    _port?.close();
    _port = null;
  }

  @override
  void dispose() {
    _teardownLink();
    _createCompleter?.complete(false);
    _createCompleter = null;
    _resetSessionState();
  }
}
```

- [ ] **Step 5: Run the tests**

```bash
cd packages/flutter_map_maplibre && fvm flutter test test/worker_basemap_renderer_test.dart
```

Expected: all pass. Iterate on the facade (not the tests) until they do — except where a test contradicts the interface docs, in which case fix the test and say so in the commit message.

- [ ] **Step 6: Run the whole suite, format, commit**

```bash
cd packages/flutter_map_maplibre && fvm flutter test
fvm dart format lib/src/ffi/worker_link.dart lib/src/ffi/worker_basemap_renderer.dart test/worker_basemap_renderer_test.dart
git add -A && git commit -m "feat(maplibre): WorkerBasemapRenderer facade over the render worker"
```

---

### Task 5: Widget wiring + export + spec amendment

**Files:**
- Modify: `packages/flutter_map_maplibre/lib/src/maplibre_basemap.dart` (factory default ~line 124, settle clear ~line 533)
- Modify: `packages/flutter_map_maplibre/lib/flutter_map_maplibre.dart`
- Modify: `docs/superpowers/specs/2026-07-26-render-worker-thread-design.md`
- Test: `packages/flutter_map_maplibre/test/maplibre_basemap_test.dart`

**Interfaces:**
- Consumes: `WorkerBasemapRenderer()` (Task 4).
- Produces: Android default renderer is the worker; `WorkerBasemapRenderer` and `WorkerLink` are public exports for the example app (Task 6).

- [ ] **Step 1: Default factory per platform**

In `maplibre_basemap.dart`, add the import and change the renderer field:

```dart
import 'ffi/worker_basemap_renderer.dart';
```

```dart
  late final BasemapRenderer _renderer =
      (widget.rendererFactory ?? _defaultRenderer)();

  /// Android renders on the worker thread (admitted renders cost ~10ms and
  /// must not block the UI thread); iOS keeps the validated synchronous
  /// same-frame path.
  static BasemapRenderer _defaultRenderer() =>
      Platform.isAndroid ? WorkerBasemapRenderer() : FfiBasemapRenderer();
```

- [ ] **Step 2: Settle clears on issue**

Around line 533, change:

```dart
        final rendered = admit && _renderer.render(target);
        if (rendered) _settleForced = false;
```
to
```dart
        final rendered = admit && _renderer.render(target);
        // Cleared on issue, not on landing: the async renderer never
        // returns true, and a lost render is already covered by the
        // unpublished-jump sleep veto and tick retries.
        if (admit) _settleForced = false;
```

- [ ] **Step 3: Export**

In `flutter_map_maplibre.dart`, alongside the existing ffi export add:

```dart
export 'src/ffi/worker_basemap_renderer.dart';
export 'src/ffi/worker_link.dart';
```

- [ ] **Step 4: Amend the spec**

In `docs/superpowers/specs/2026-07-26-render-worker-thread-design.md`, replace the §2 bullet starting `- \`dispose()\`: posts \`DESTROY\`; on \`DESTROYED\` runs an injected cleanup` and the §3 bullet starting `- Renderer disposal hands \`_channel.disposeTextures\`` with:

```markdown
- `dispose()`: posts `DESTROY` and closes the `ReceivePort` when
  `DESTROYED` arrives (2 s fallback timer so a lost message never pins the
  isolate). **Amended from the original design:** no injected cleanup
  callback. The Kotlin plugin holds one presenter per engine and
  `createTextures` disposes the previous presenter itself, so a deferred
  callback could destroy a successor presenter on the resize path. The
  widget keeps today's call order (`dispose()` then `disposeTextures()`);
  destroying the presenter before the worker finishes tearing down the
  session is safe because mln's own GL context keeps the share group (and
  the back texture) alive, and a straggler `fmm_present` fails soft through
  the presenter-registry mutex.
```

- [ ] **Step 5: Widget test for settle-on-issue**

In `test/maplibre_basemap_test.dart`, if a test asserts `_settleForced` behavior via a failing-render fake (render returns false), update its expectation: after an admitted-but-failed render, a subsequent same-camera build must NOT re-force a settle render (the settle window re-arms through `_manageSettle` instead). If no such test exists, add one keyed on the fake renderer's recorded render calls: force a settle (pump the 300ms timer via `tester.pump(const Duration(milliseconds: 350))`), make the fake's `render` return false, rebuild same camera, and assert exactly one settle-forced render call was issued.

- [ ] **Step 6: Run, format, commit**

```bash
cd packages/flutter_map_maplibre && fvm flutter test
fvm dart format lib/src/maplibre_basemap.dart lib/flutter_map_maplibre.dart test/maplibre_basemap_test.dart
git add -A && git commit -m "feat(maplibre): worker renderer is the Android default; settle clears on issue"
```

---

### Task 6: Example app A/B FAB

**Files:**
- Modify: `packages/flutter_map_maplibre/example/lib/main.dart`

**Interfaces:**
- Consumes: `WorkerBasemapRenderer` / `FfiBasemapRenderer` exports.

- [ ] **Step 1: Add the toggle**

In `_MapPageState`: add state and a factory, and key the basemap so flipping recreates the whole session (the renderer is a `late final` on the widget state):

```dart
  bool _useWorker = true;
```

At the `MapLibreBasemap(` call site (~line 100):

```dart
              MapLibreBasemap(
                key: ValueKey('renderer-$_useWorker'),
                rendererFactory: _useWorker
                    ? WorkerBasemapRenderer.new
                    : FfiBasemapRenderer.new,
```

(keep the existing arguments). Next to the existing FABs (~line 139) add:

```dart
                    FloatingActionButton.small(
                      heroTag: 'renderer',
                      onPressed: () => setState(() => _useWorker = !_useWorker),
                      child: Text(_useWorker ? 'wkr' : 'ffi'),
                    ),
```

- [ ] **Step 2: Build, format, commit**

```bash
cd packages/flutter_map_maplibre/example && fvm flutter build apk --debug --target-platform android-arm64
fvm dart format lib/main.dart
git add -A && git commit -m "feat(maplibre): example FAB to A/B worker vs sync renderer"
```

---

### Task 7: On-device validation (manual, with the user's device)

**Files:** none (results recorded as a spec addendum).

This task needs the OnePlus 8 Pro (adb serial `ca4bbe3f`) and the user's eyes. It is the spec's validation gate, not automatable.

- [ ] **Step 1: Profile build of the example app; smoke-test worker renderer**

```bash
cd packages/flutter_map_maplibre/example && fvm flutter build apk --profile --target-platform android-arm64
adb -s ca4bbe3f install -r build/app/outputs/flutter-apk/app-profile.apk
```

Verify: map renders, pans, markers glued (the example's latency-cycle FAB re-tunes `WorkerBasemapRenderer.presentLatencyFrames` — point it at the new static).

- [ ] **Step 2: Profile build of Vedu; soak-rec A/B**

```bash
fvm flutter build apk --profile --target-platform android-arm64
adb -s ca4bbe3f install -r build/app/outputs/flutter-apk/app-profile.apk
```

Same protocol as the 2026-07-26 measurement: debug panel `rec` → hard pan 20–30 s → `stop`, once with the maplibre toggle on (worker) and once with raster tiles; capture `SOAK` lines via `adb logcat -s flutter`.

- [ ] **Step 3: Judge against the gate**

- Hard-pan fps ≥ 90 (was ~46) with UI `buildAvg` near ~3 ms.
- `underRenderPx` no worse than the sync renderer's runs.
- User's flick-the-dot test passes after latch re-tuning.

- [ ] **Step 4: Record results**

Append the numbers to `docs/superpowers/specs/2026-07-26-render-worker-thread-design.md` as a "Validation results" section; commit as `docs(maplibre): worker-thread validation results`.
