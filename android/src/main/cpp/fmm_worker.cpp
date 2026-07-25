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

#include <EGL/egl.h>
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
    if (runtime_ == nullptr) {
      // Completion symmetry with Render(): every command posts, even
      // against a dead session, so a facade can never wedge waiting.
      PostMessage({I(kEvents), I(0), I(0), I(0), I(0), I(0), D(0.0)});
      return;
    }
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
    // The render path leaves the presenter's context current on this thread;
    // a context current on a (soon-dead) thread blocks the platform thread's
    // destroyPresenter cleanup with EGL_BAD_ACCESS. Release before exit.
    EGLDisplay display = eglGetCurrentDisplay();
    if (display != EGL_NO_DISPLAY) {
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
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
