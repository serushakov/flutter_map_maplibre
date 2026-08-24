// fmm_worker.cpp — dedicated owner thread for the mln runtime/map/session.
// The mln C API is owner-thread affine; Dart isolates have no fixed OS
// thread, so the owner must be a thread we control. Dart posts commands
// (strict FIFO, RENDER coalescing only) and receives completions over a
// NativePort. See docs/superpowers/specs/2026-07-26-render-worker-thread-design.md.

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
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

// Local failure codes, chosen outside mln_status's 0..-5 range so they never
// overlap a real mln status.
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
  std::string cache_path;         // kCreate; ":memory:" when unconfigured
  uint64_t max_cache_size = 0;    // kCreate; 0 keeps MapLibre's default
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
    options.cache_path = cmd.cache_path.c_str();
    if (cmd.max_cache_size > 0) {
      options.flags |= MLN_RUNTIME_OPTION_MAXIMUM_CACHE_SIZE;
      options.maximum_cache_size = cmd.max_cache_size;
    }
    int32_t runtime_status = mln_runtime_create(&options, &runtime_);
    // -1000 marks "stage not attempted" — kept well outside mln_status's
    // 0..-5 range (unlike -1, which collides with
    // MLN_STATUS_INVALID_ARGUMENT). The Dart side only ever checks == 0, so
    // this sentinel choice is not part of the wire ABI.
    constexpr int32_t kNotAttempted = -1000;
    int32_t map_status = kNotAttempted, style_status = kNotAttempted,
            attach_status = kNotAttempted;
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
    // jumpMs means "jump cost attributable to this frame" — clear it once
    // reported so a later, jump-free RENDERED doesn't re-report a stale cost.
    last_jump_ms_ = 0;
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

// ---------------------------------------------------------------------------
// Offline worker — a second, map-less owner thread for the offline seeding
// facade (spec 2026-08-24). Own thread → own mln runtime is legal on
// Android; it shares the SQLite database file with the render workers'
// runtimes (probe-validated). Commands mirror Dart's OfflineLink; every
// native handle (op results, snapshots, lists) is consumed on this thread
// and only plain values cross the port.

// Completion kinds on the offline worker's port. Mirrored in
// worker_offline_link.dart; keep in sync.
constexpr int64_t kOfflineCreated = 100;       // [kind, runtime_status]
constexpr int64_t kOfflineRegionCreated = 101; // [kind, req, status, region]
constexpr int64_t kOfflineAck = 102;           // [kind, req, status]
constexpr int64_t kOfflineList = 103;   // [kind, req, status, n, n×11 items]
constexpr int64_t kOfflineStatus = 104; // [kind, req(0=push), region, 8×counters]
constexpr int64_t kOfflineDeleted = 105;     // [kind, req, status]
constexpr int64_t kOfflineAmbientDone = 106; // [kind, req, status]
constexpr int64_t kOfflineRegionError = 107; // [kind, region, fatal, message]
constexpr int64_t kOfflineDestroyed = 108;   // [kind]

// Local failure code for "commands against a runtime that never came up",
// outside mln_status's range (matching kErrNoSession's convention).
constexpr int32_t kErrNoRuntime = -101;

// A value in an offline completion message: int64, double, string or bytes.
struct OVal {
  enum Kind { kInt, kDouble, kString, kBytes } kind = kInt;
  int64_t i = 0;
  double d = 0;
  std::string s;
  std::vector<uint8_t> bytes;
};
OVal OI(int64_t v) {
  OVal val;
  val.kind = OVal::kInt;
  val.i = v;
  return val;
}
OVal OD(double v) {
  OVal val;
  val.kind = OVal::kDouble;
  val.d = v;
  return val;
}
OVal OS(std::string v) {
  OVal val;
  val.kind = OVal::kString;
  val.s = std::move(v);
  return val;
}
OVal OB(std::vector<uint8_t> v) {
  OVal val;
  val.kind = OVal::kBytes;
  val.bytes = std::move(v);
  return val;
}

enum class OCmd {
  kCreate,
  kRegionCreate,
  kSetObserved,
  kSetDownloadState,
  kList,
  kDelete,
  kGetStatus,
  kAmbient,
  kPump,
  kDestroy,
};

struct OfflineCommand {
  OCmd type;
  int64_t request_id = 0;
  int64_t region_id = 0;
  std::string cache_path;
  uint64_t max_cache_size = 0;
  std::string style_url;
  double south = 0, west = 0, north = 0, east = 0;
  double min_zoom = 0, max_zoom = 0, pixel_ratio = 1.0;
  bool flag = false;  // observed / download-active / include_ideographs
  uint32_t ambient_op = 0;
  std::vector<uint8_t> metadata;
};

class OfflineWorker {
 public:
  explicit OfflineWorker(Dart_Port port) : port_(port) {
    std::thread([this] { Run(); }).detach();
  }

  void Post(OfflineCommand cmd) {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.push_back(std::move(cmd));
    cv_.notify_one();
  }

 private:
  void Run() {
    for (;;) {
      OfflineCommand cmd;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        if (pending_.empty()) {
          cv_.wait(lock, [this] { return !queue_.empty(); });
        } else {
          // Operations are in flight: self-pump on a short cadence so
          // completions post promptly instead of waiting for the Dart
          // side's slow timer.
          const bool got = cv_.wait_for(lock, std::chrono::milliseconds(50),
                                        [this] { return !queue_.empty(); });
          if (!got) {
            lock.unlock();
            Pump();
            continue;
          }
        }
        cmd = std::move(queue_.front());
        queue_.pop_front();
      }
      switch (cmd.type) {
        case OCmd::kCreate:
          Create(cmd);
          break;
        case OCmd::kRegionCreate:
          RegionCreate(cmd);
          break;
        case OCmd::kSetObserved:
          SetObserved(cmd);
          break;
        case OCmd::kSetDownloadState:
          SetDownloadState(cmd);
          break;
        case OCmd::kList:
          List(cmd);
          break;
        case OCmd::kDelete:
          Delete(cmd);
          break;
        case OCmd::kGetStatus:
          GetStatus(cmd);
          break;
        case OCmd::kAmbient:
          Ambient(cmd);
          break;
        case OCmd::kPump:
          Pump();
          break;
        case OCmd::kDestroy:
          Destroy();
          PostMessage({OI(kOfflineDestroyed)});
          delete this;
          return;
      }
    }
  }

  struct PendingOp {
    OCmd kind;
    int64_t request_id;
    int64_t region_id;
  };

  void Create(const OfflineCommand& cmd) {
    mln_runtime_options options = mln_runtime_options_default();
    options.cache_path = cmd.cache_path.c_str();
    if (cmd.max_cache_size > 0) {
      options.flags |= MLN_RUNTIME_OPTION_MAXIMUM_CACHE_SIZE;
      options.maximum_cache_size = cmd.max_cache_size;
    }
    const int32_t status = mln_runtime_create(&options, &runtime_);
    PostMessage({OI(kOfflineCreated), OI(status)});
  }

  // Starts an async op; on start failure posts the terminal completion for
  // [kind] immediately, else records it for HandleOpCompleted.
  void Track(int32_t start_status, uint64_t op_id, OCmd kind,
             int64_t request_id, int64_t region_id) {
    if (start_status != kStatusOk) {
      PostTerminal(kind, request_id, region_id, start_status, 0);
      return;
    }
    pending_[op_id] = PendingOp{kind, request_id, region_id};
  }

  // The one completion each command kind promises, for failure paths and
  // ack-style successes.
  void PostTerminal(OCmd kind, int64_t request_id, int64_t region_id,
                    int32_t status, int64_t created_region_id) {
    switch (kind) {
      case OCmd::kRegionCreate:
        PostMessage({OI(kOfflineRegionCreated), OI(request_id), OI(status),
                     OI(created_region_id)});
        break;
      case OCmd::kSetObserved:
      case OCmd::kSetDownloadState:
        PostMessage({OI(kOfflineAck), OI(request_id), OI(status)});
        break;
      case OCmd::kList:
        PostMessage(
            {OI(kOfflineList), OI(request_id), OI(status), OI(0)});
        break;
      case OCmd::kDelete:
        PostMessage({OI(kOfflineDeleted), OI(request_id), OI(status)});
        break;
      case OCmd::kGetStatus:
        // Failure only; success posts a full kOfflineStatus.
        PostMessage({OI(kOfflineAck), OI(request_id), OI(status)});
        break;
      case OCmd::kAmbient:
        PostMessage({OI(kOfflineAmbientDone), OI(request_id), OI(status)});
        break;
      default:
        break;
    }
  }

  void RegionCreate(const OfflineCommand& cmd) {
    if (runtime_ == nullptr) {
      PostTerminal(OCmd::kRegionCreate, cmd.request_id, 0, kErrNoRuntime, 0);
      return;
    }
    mln_offline_region_definition def;
    std::memset(&def, 0, sizeof def);
    def.size = sizeof def;
    def.type = MLN_OFFLINE_REGION_DEFINITION_TILE_PYRAMID;
    mln_offline_tile_pyramid_region_definition& tp = def.data.tile_pyramid;
    tp.size = sizeof tp;
    tp.style_url = cmd.style_url.c_str();
    tp.bounds.southwest.latitude = cmd.south;
    tp.bounds.southwest.longitude = cmd.west;
    tp.bounds.northeast.latitude = cmd.north;
    tp.bounds.northeast.longitude = cmd.east;
    tp.min_zoom = cmd.min_zoom;
    tp.max_zoom = cmd.max_zoom;
    tp.pixel_ratio = static_cast<float>(cmd.pixel_ratio);
    tp.include_ideographs = cmd.flag;
    uint64_t op_id = 0;
    const int32_t status = mln_runtime_offline_region_create_start(
        runtime_, &def, cmd.metadata.empty() ? nullptr : cmd.metadata.data(),
        cmd.metadata.size(), &op_id);
    Track(status, op_id, OCmd::kRegionCreate, cmd.request_id, 0);
  }

  void SetObserved(const OfflineCommand& cmd) {
    if (runtime_ == nullptr) {
      PostTerminal(OCmd::kSetObserved, cmd.request_id, 0, kErrNoRuntime, 0);
      return;
    }
    uint64_t op_id = 0;
    const int32_t status = mln_runtime_offline_region_set_observed_start(
        runtime_, cmd.region_id, cmd.flag, &op_id);
    Track(status, op_id, OCmd::kSetObserved, cmd.request_id, cmd.region_id);
  }

  void SetDownloadState(const OfflineCommand& cmd) {
    if (runtime_ == nullptr) {
      PostTerminal(OCmd::kSetDownloadState, cmd.request_id, 0, kErrNoRuntime,
                   0);
      return;
    }
    uint64_t op_id = 0;
    const int32_t status = mln_runtime_offline_region_set_download_state_start(
        runtime_, cmd.region_id,
        cmd.flag ? MLN_OFFLINE_REGION_DOWNLOAD_ACTIVE
                 : MLN_OFFLINE_REGION_DOWNLOAD_INACTIVE,
        &op_id);
    Track(status, op_id, OCmd::kSetDownloadState, cmd.request_id,
          cmd.region_id);
  }

  void List(const OfflineCommand& cmd) {
    if (runtime_ == nullptr) {
      PostTerminal(OCmd::kList, cmd.request_id, 0, kErrNoRuntime, 0);
      return;
    }
    uint64_t op_id = 0;
    const int32_t status =
        mln_runtime_offline_regions_list_start(runtime_, &op_id);
    Track(status, op_id, OCmd::kList, cmd.request_id, 0);
  }

  void Delete(const OfflineCommand& cmd) {
    if (runtime_ == nullptr) {
      PostTerminal(OCmd::kDelete, cmd.request_id, 0, kErrNoRuntime, 0);
      return;
    }
    uint64_t op_id = 0;
    const int32_t status = mln_runtime_offline_region_delete_start(
        runtime_, cmd.region_id, &op_id);
    Track(status, op_id, OCmd::kDelete, cmd.request_id, cmd.region_id);
  }

  void GetStatus(const OfflineCommand& cmd) {
    if (runtime_ == nullptr) {
      PostTerminal(OCmd::kGetStatus, cmd.request_id, 0, kErrNoRuntime, 0);
      return;
    }
    uint64_t op_id = 0;
    const int32_t status = mln_runtime_offline_region_get_status_start(
        runtime_, cmd.region_id, &op_id);
    Track(status, op_id, OCmd::kGetStatus, cmd.request_id, cmd.region_id);
  }

  void Ambient(const OfflineCommand& cmd) {
    if (runtime_ == nullptr) {
      PostTerminal(OCmd::kAmbient, cmd.request_id, 0, kErrNoRuntime, 0);
      return;
    }
    uint64_t op_id = 0;
    const int32_t status = mln_runtime_run_ambient_cache_operation_start(
        runtime_, cmd.ambient_op, &op_id);
    Track(status, op_id, OCmd::kAmbient, cmd.request_id, 0);
  }

  void Pump() {
    if (runtime_ == nullptr) return;
    mln_runtime_run_once(runtime_);
    for (;;) {
      mln_runtime_event event;
      std::memset(&event, 0, sizeof event);
      event.size = sizeof event;
      bool has = false;
      if (mln_runtime_poll_event(runtime_, &event, &has) != kStatusOk ||
          !has) {
        break;
      }
      HandleEvent(event);
    }
  }

  void HandleEvent(const mln_runtime_event& event) {
    switch (event.type) {
      case MLN_RUNTIME_EVENT_OFFLINE_OPERATION_COMPLETED: {
        if (event.payload == nullptr) break;
        const auto* done = reinterpret_cast<
            const mln_runtime_event_offline_operation_completed*>(
            event.payload);
        HandleOpCompleted(done->operation_id, done->result_status);
        break;
      }
      case MLN_RUNTIME_EVENT_OFFLINE_REGION_STATUS_CHANGED: {
        if (event.payload == nullptr) break;
        const auto* payload =
            reinterpret_cast<const mln_runtime_event_offline_region_status*>(
                event.payload);
        PostStatus(0, payload->region_id, payload->status);
        break;
      }
      case MLN_RUNTIME_EVENT_OFFLINE_REGION_RESPONSE_ERROR: {
        if (event.payload == nullptr) break;
        const auto* payload = reinterpret_cast<
            const mln_runtime_event_offline_region_response_error*>(
            event.payload);
        PostMessage({OI(kOfflineRegionError), OI(payload->region_id), OI(0),
                     OS("resource response error (reason " +
                        std::to_string(payload->reason) + ")")});
        break;
      }
      case MLN_RUNTIME_EVENT_OFFLINE_REGION_TILE_COUNT_LIMIT_EXCEEDED: {
        if (event.payload == nullptr) break;
        const auto* payload = reinterpret_cast<
            const mln_runtime_event_offline_region_tile_count_limit*>(
            event.payload);
        PostMessage({OI(kOfflineRegionError), OI(payload->region_id), OI(1),
                     OS("tile count limit " + std::to_string(payload->limit) +
                        " reached")});
        break;
      }
      default:
        break;
    }
  }

  void HandleOpCompleted(uint64_t op_id, int32_t result_status) {
    const auto found = pending_.find(op_id);
    if (found == pending_.end()) return;
    const PendingOp op = found->second;
    pending_.erase(found);
    if (result_status != kStatusOk) {
      PostTerminal(op.kind, op.request_id, op.region_id, result_status, 0);
      return;
    }
    switch (op.kind) {
      case OCmd::kRegionCreate:
        TakeCreatedRegion(op_id, op.request_id);
        break;
      case OCmd::kList:
        TakeRegionList(op_id, op.request_id);
        break;
      case OCmd::kGetStatus: {
        mln_offline_region_status status;
        std::memset(&status, 0, sizeof status);
        status.size = sizeof status;
        const int32_t take = mln_runtime_offline_region_get_status_take_result(
            runtime_, op_id, &status);
        if (take != kStatusOk) {
          PostTerminal(op.kind, op.request_id, op.region_id, take, 0);
        } else {
          PostStatus(op.request_id, op.region_id, status);
        }
        break;
      }
      default:
        PostTerminal(op.kind, op.request_id, op.region_id, kStatusOk, 0);
        break;
    }
  }

  void TakeCreatedRegion(uint64_t op_id, int64_t request_id) {
    mln_offline_region_snapshot* snapshot = nullptr;
    int32_t status = mln_runtime_offline_region_create_take_result(
        runtime_, op_id, &snapshot);
    int64_t region_id = 0;
    if (status == kStatusOk) {
      mln_offline_region_info info;
      std::memset(&info, 0, sizeof info);
      info.size = sizeof info;
      status = mln_offline_region_snapshot_get(snapshot, &info);
      if (status == kStatusOk) region_id = info.id;
      mln_offline_region_snapshot_destroy(snapshot);
    }
    PostMessage({OI(kOfflineRegionCreated), OI(request_id), OI(status),
                 OI(region_id)});
  }

  void TakeRegionList(uint64_t op_id, int64_t request_id) {
    mln_offline_region_list* list = nullptr;
    int32_t status =
        mln_runtime_offline_regions_list_take_result(runtime_, op_id, &list);
    std::vector<OVal> message = {OI(kOfflineList), OI(request_id)};
    std::vector<OVal> items;
    size_t count = 0;
    if (status == kStatusOk) {
      status = mln_offline_region_list_count(list, &count);
      for (size_t i = 0; i < count && status == kStatusOk; i++) {
        mln_offline_region_info info;
        std::memset(&info, 0, sizeof info);
        info.size = sizeof info;
        status = mln_offline_region_list_get(list, i, &info);
        if (status != kStatusOk) break;
        if (info.definition.type != MLN_OFFLINE_REGION_DEFINITION_TILE_PYRAMID) {
          continue;  // this package never creates geometry regions
        }
        const mln_offline_tile_pyramid_region_definition& tp =
            info.definition.data.tile_pyramid;
        items.push_back(OI(info.id));
        items.push_back(OS(tp.style_url == nullptr ? "" : tp.style_url));
        items.push_back(OD(tp.bounds.southwest.latitude));
        items.push_back(OD(tp.bounds.southwest.longitude));
        items.push_back(OD(tp.bounds.northeast.latitude));
        items.push_back(OD(tp.bounds.northeast.longitude));
        items.push_back(OD(tp.min_zoom));
        items.push_back(OD(tp.max_zoom));
        items.push_back(OD(tp.pixel_ratio));
        items.push_back(OI(tp.include_ideographs ? 1 : 0));
        std::vector<uint8_t> metadata;
        if (info.metadata != nullptr && info.metadata_size > 0) {
          metadata.assign(info.metadata, info.metadata + info.metadata_size);
        }
        items.push_back(OB(std::move(metadata)));
      }
      mln_offline_region_list_destroy(list);
    }
    message.push_back(OI(status));
    message.push_back(OI(static_cast<int64_t>(items.size() / 11)));
    for (OVal& item : items) message.push_back(std::move(item));
    PostVector(message);
  }

  void PostStatus(int64_t request_id, int64_t region_id,
                  const mln_offline_region_status& status) {
    PostMessage({OI(kOfflineStatus), OI(request_id), OI(region_id),
                 OI(status.download_state),
                 OI(static_cast<int64_t>(status.completed_resource_count)),
                 OI(static_cast<int64_t>(status.completed_resource_size)),
                 OI(static_cast<int64_t>(status.completed_tile_count)),
                 OI(static_cast<int64_t>(status.required_tile_count)),
                 OI(static_cast<int64_t>(status.required_resource_count)),
                 OI(status.required_resource_count_is_precise ? 1 : 0),
                 OI(status.complete ? 1 : 0)});
  }

  void Destroy() {
    if (runtime_ != nullptr) {
      for (const auto& entry : pending_) {
        mln_runtime_offline_operation_discard(runtime_, entry.first);
      }
      pending_.clear();
      mln_runtime_destroy(runtime_);
      runtime_ = nullptr;
    }
  }

  void PostMessage(std::initializer_list<OVal> values) {
    std::vector<OVal> vector(values.size());
    size_t i = 0;
    for (const OVal& v : values) vector[i++] = v;
    PostVector(vector);
  }

  void PostVector(std::vector<OVal>& values) {
    std::vector<Dart_CObject> items(values.size());
    std::vector<Dart_CObject*> pointers(values.size());
    for (size_t i = 0; i < values.size(); i++) {
      OVal& v = values[i];
      switch (v.kind) {
        case OVal::kInt:
          items[i].type = Dart_CObject_kInt64;
          items[i].value.as_int64 = v.i;
          break;
        case OVal::kDouble:
          items[i].type = Dart_CObject_kDouble;
          items[i].value.as_double = v.d;
          break;
        case OVal::kString:
          items[i].type = Dart_CObject_kString;
          items[i].value.as_string = const_cast<char*>(v.s.c_str());
          break;
        case OVal::kBytes:
          items[i].type = Dart_CObject_kTypedData;
          items[i].value.as_typed_data.type = Dart_TypedData_kUint8;
          items[i].value.as_typed_data.length =
              static_cast<intptr_t>(v.bytes.size());
          items[i].value.as_typed_data.values =
              v.bytes.empty() ? nullptr : v.bytes.data();
          break;
      }
      pointers[i] = &items[i];
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
  std::deque<OfflineCommand> queue_;

  // Owner-thread state: touched only on the worker thread after
  // construction.
  mln_runtime* runtime_ = nullptr;
  std::unordered_map<uint64_t, PendingOp> pending_;
};

OfflineWorker* AsOfflineWorker(int64_t handle) {
  return reinterpret_cast<OfflineWorker*>(handle);
}

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
    const char* style_url, int64_t presenter_id, const char* cache_path,
    uint64_t max_cache_size) {
  Command cmd;
  cmd.type = CmdType::kCreate;
  cmd.width = width;
  cmd.height = height;
  cmd.scale = scale;
  cmd.url = style_url;  // copied on the calling thread; caller frees after
  cmd.presenter_id = presenter_id;
  cmd.cache_path = cache_path;  // same copy-on-this-thread contract
  cmd.max_cache_size = max_cache_size;
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

// --- offline worker ---------------------------------------------------------
// All pointer arguments are copied on the calling thread; the caller frees
// them after the call returns.

__attribute__((visibility("default"))) int64_t fmm_offline_start(
    int64_t port) {
  return reinterpret_cast<int64_t>(
      new OfflineWorker(static_cast<Dart_Port>(port)));
}

__attribute__((visibility("default"))) void fmm_offline_post_create(
    int64_t worker, const char* cache_path, uint64_t max_cache_size) {
  OfflineCommand cmd;
  cmd.type = OCmd::kCreate;
  cmd.cache_path = cache_path;
  cmd.max_cache_size = max_cache_size;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_offline_post_region_create(
    int64_t worker, int64_t request_id, const char* style_url, double south,
    double west, double north, double east, double min_zoom, double max_zoom,
    double pixel_ratio, int32_t include_ideographs, const uint8_t* metadata,
    intptr_t metadata_size) {
  OfflineCommand cmd;
  cmd.type = OCmd::kRegionCreate;
  cmd.request_id = request_id;
  cmd.style_url = style_url;
  cmd.south = south;
  cmd.west = west;
  cmd.north = north;
  cmd.east = east;
  cmd.min_zoom = min_zoom;
  cmd.max_zoom = max_zoom;
  cmd.pixel_ratio = pixel_ratio;
  cmd.flag = include_ideographs != 0;
  if (metadata != nullptr && metadata_size > 0) {
    cmd.metadata.assign(metadata, metadata + metadata_size);
  }
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_offline_post_set_observed(
    int64_t worker, int64_t request_id, int64_t region_id, int32_t observed) {
  OfflineCommand cmd;
  cmd.type = OCmd::kSetObserved;
  cmd.request_id = request_id;
  cmd.region_id = region_id;
  cmd.flag = observed != 0;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void
fmm_offline_post_set_download_state(int64_t worker, int64_t request_id,
                                    int64_t region_id, int32_t active) {
  OfflineCommand cmd;
  cmd.type = OCmd::kSetDownloadState;
  cmd.request_id = request_id;
  cmd.region_id = region_id;
  cmd.flag = active != 0;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_offline_post_list(
    int64_t worker, int64_t request_id) {
  OfflineCommand cmd;
  cmd.type = OCmd::kList;
  cmd.request_id = request_id;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_offline_post_delete(
    int64_t worker, int64_t request_id, int64_t region_id) {
  OfflineCommand cmd;
  cmd.type = OCmd::kDelete;
  cmd.request_id = request_id;
  cmd.region_id = region_id;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_offline_post_get_status(
    int64_t worker, int64_t request_id, int64_t region_id) {
  OfflineCommand cmd;
  cmd.type = OCmd::kGetStatus;
  cmd.request_id = request_id;
  cmd.region_id = region_id;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_offline_post_ambient(
    int64_t worker, int64_t request_id, uint32_t operation) {
  OfflineCommand cmd;
  cmd.type = OCmd::kAmbient;
  cmd.request_id = request_id;
  cmd.ambient_op = operation;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_offline_post_pump(
    int64_t worker) {
  OfflineCommand cmd;
  cmd.type = OCmd::kPump;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

__attribute__((visibility("default"))) void fmm_offline_post_destroy(
    int64_t worker) {
  OfflineCommand cmd;
  cmd.type = OCmd::kDestroy;
  AsOfflineWorker(worker)->Post(std::move(cmd));
}

}  // extern "C"
