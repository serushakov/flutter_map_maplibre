// Native half of the Android FFI architecture (see
// docs/superpowers/specs/2026-07-25-flutter-map-maplibre-android-port.md).
//
// Split of responsibilities:
//   - JNI (platform thread): presenter lifecycle. Builds EGL objects, the GL
//     back texture MapLibre renders into, and the blit program — then UNBINDS
//     the context, because from that point on it lives on the map's owner
//     thread.
//   - FFI (map's owner thread): fmm_attach / fmm_present / fmm_debug_fill. All
//     mln_* calls happen on the caller's thread or inside fmm_attach, so the
//     map's owner thread is whichever thread calls these by construction —
//     the Dart UI thread for the synchronous renderer, the render worker
//     thread for WorkerBasemapRenderer (see fmm_worker.cpp).
//
// MapLibre renders into a texture we own (mln_opengl_borrowed_texture_attach),
// which we then blit onto the SurfaceProducer window surface. The
// surface-session path does not work here: the session creates its own context
// in our share group, and while a share group shares texture objects it does
// NOT share window surfaces, so the session renders into its own default
// framebuffer and our swap presents an untouched buffer.
//
// No buffer ring, unlike the iOS TexturePresenter: the SurfaceProducer's
// BufferQueue is the swapchain, and eglSwapBuffers publishes only completed
// frames. render_update leaves the session's context current on the calling
// thread, so present re-binds ours first.

#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>

#include <cstdint>
#include <ctime>
#include <mutex>
#include <unordered_map>

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <maplibre_native_c.h>
#include <maplibre_native_c/android.h>

namespace {

// Fullscreen triangle from gl_VertexID: no VBO, no VAO state to manage.
const char* kVertexShader = R"(#version 300 es
out vec2 v_uv;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  v_uv = p;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

const char* kFragmentShader = R"(#version 300 es
precision mediump float;
uniform sampler2D u_tex;
in vec2 v_uv;
out vec4 fragColor;
void main() { fragColor = texture(u_tex, v_uv); }
)";

// fmm_present / fmm_attach error codes (negative so present can share the
// "blit ms or negative" return convention with iOS).
constexpr double kErrUnknownPresenter = -2;
constexpr double kErrMakeCurrent = -3;
constexpr double kErrSwapFailed = -4;
constexpr double kErrSurfaceLost = -5;

struct Presenter {
  ANativeWindow* window = nullptr;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLConfig config = nullptr;
  EGLContext context = EGL_NO_CONTEXT;
  EGLSurface surface = EGL_NO_SURFACE;

  GLuint texture = 0;   // The borrowed texture MapLibre renders into.
  GLuint program = 0;   // Blit: texture -> window surface.
  GLint texUniform = -1;
  GLuint fillFbo = 0;   // Scratch FBO for fmm_debug_fill only.

  int logicalWidth = 0;
  int logicalHeight = 0;
  double scale = 1.0;
  int physicalWidth = 0;
  int physicalHeight = 0;

  // Set from the platform thread when the SurfaceProducer invalidates its
  // surface; checked (not locked — a stale read costs one extra frame) on the
  // Dart thread.
  bool surfaceLost = false;
};

// Keyed by Flutter texture id, so the FFI shims (called from Dart with no
// instance context) can reach the presenter. Same shape as the iOS
// PresenterRegistry.
std::mutex gPresentersMutex;
std::unordered_map<int64_t, Presenter*>& presenters() {
  static auto* map = new std::unordered_map<int64_t, Presenter*>();
  return *map;
}

Presenter* findPresenter(int64_t id) {
  std::lock_guard<std::mutex> lock(gPresentersMutex);
  auto it = presenters().find(id);
  return it == presenters().end() ? nullptr : it->second;
}

GLuint compileShader(GLenum type, const char* source) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);
  GLint ok = GL_FALSE;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

GLuint buildBlitProgram() {
  GLuint vs = compileShader(GL_VERTEX_SHADER, kVertexShader);
  if (!vs) return 0;
  GLuint fs = compileShader(GL_FRAGMENT_SHADER, kFragmentShader);
  if (!fs) {
    glDeleteShader(vs);
    return 0;
  }
  GLuint program = glCreateProgram();
  glAttachShader(program, vs);
  glAttachShader(program, fs);
  glLinkProgram(program);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint ok = GL_FALSE;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    glDeleteProgram(program);
    return 0;
  }
  return program;
}

// Destroys EGL/GL state. The context may still be "current" on the Dart
// thread as a stale binding; EGL defers actual deletion until it is unbound,
// and the next presenter's makeCurrent replaces the binding.
void destroyPresenter(Presenter* p) {
  if (!p) return;
  if (p->display != EGL_NO_DISPLAY) {
    if (p->context != EGL_NO_CONTEXT &&
        eglMakeCurrent(p->display, p->surface, p->surface, p->context)) {
      if (p->fillFbo) glDeleteFramebuffers(1, &p->fillFbo);
      if (p->program) glDeleteProgram(p->program);
      if (p->texture) glDeleteTextures(1, &p->texture);
      eglMakeCurrent(p->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                     EGL_NO_CONTEXT);
    }
    if (p->surface != EGL_NO_SURFACE) eglDestroySurface(p->display, p->surface);
    if (p->context != EGL_NO_CONTEXT) eglDestroyContext(p->display, p->context);
    // No eglTerminate: the default display is one process-wide connection
    // (eglInitialize is not refcounted), so terminating it here would
    // invalidate every other live presenter's EGL objects mid-frame.
  }
  if (p->window) ANativeWindow_release(p->window);
  delete p;
}

double nowMs() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

}  // namespace

extern "C" {

// Must run before any HTTP: the Rust/rustls stack needs the Android context to
// reach the platform trust store. Without it every tile request fails TLS
// validation and the map renders its background colour and nothing else.
JNIEXPORT jint JNICALL
Java_io_ushakov_flutter_1map_1maplibre_MlnNative_nativeAndroidInit(
    JNIEnv* env, jclass clazz, jobject context) {
  return mln_android_init(env, clazz, context);
}

// Platform thread. Returns the GL back-texture name (> 0) on success, or a
// negative step code identifying the failing stage. The EGL context is left
// unbound: it becomes current on the map's owner thread via fmm_attach — the
// Dart UI thread for the synchronous renderer, the render worker thread for
// WorkerBasemapRenderer (see fmm_worker.cpp).
JNIEXPORT jlong JNICALL
Java_io_ushakov_flutter_1map_1maplibre_MlnNative_nativePresenterCreate(
    JNIEnv* env, jclass, jlong presenterId, jobject jsurface, jint width,
    jint height, jdouble scale) {
  auto* p = new Presenter();
  p->logicalWidth = width;
  p->logicalHeight = height;
  p->scale = scale;
  p->physicalWidth = static_cast<int>(width * scale + 0.5);
  p->physicalHeight = static_cast<int>(height * scale + 0.5);

  p->window = ANativeWindow_fromSurface(env, jsurface);
  if (!p->window) {
    destroyPresenter(p);
    return -1;
  }

  p->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (p->display == EGL_NO_DISPLAY ||
      !eglInitialize(p->display, nullptr, nullptr)) {
    destroyPresenter(p);
    return -2;
  }

  // EGL_PBUFFER_BIT is required by the FFI for texture sessions (the session
  // needs a surfaceless-ish context of its own); EGL_WINDOW_BIT is required
  // for our own blit target. The config must satisfy both.
  const EGLint configAttrs[] = {EGL_RENDERABLE_TYPE,
                                EGL_OPENGL_ES3_BIT,
                                EGL_SURFACE_TYPE,
                                EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
                                EGL_RED_SIZE,
                                8,
                                EGL_GREEN_SIZE,
                                8,
                                EGL_BLUE_SIZE,
                                8,
                                EGL_ALPHA_SIZE,
                                8,
                                EGL_DEPTH_SIZE,
                                24,
                                EGL_STENCIL_SIZE,
                                8,
                                EGL_NONE};
  EGLint numConfigs = 0;
  if (!eglChooseConfig(p->display, configAttrs, &p->config, 1, &numConfigs) ||
      numConfigs == 0) {
    destroyPresenter(p);
    return -3;
  }

  const EGLint contextAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  p->context =
      eglCreateContext(p->display, p->config, EGL_NO_CONTEXT, contextAttrs);
  if (p->context == EGL_NO_CONTEXT) {
    destroyPresenter(p);
    return -4;
  }

  p->surface =
      eglCreateWindowSurface(p->display, p->config, p->window, nullptr);
  if (p->surface == EGL_NO_SURFACE) {
    destroyPresenter(p);
    return -5;
  }

  if (!eglMakeCurrent(p->display, p->surface, p->surface, p->context)) {
    destroyPresenter(p);
    return -6;
  }

  // The texture MapLibre draws into. Physical pixels — the descriptor extent
  // stays logical and carries the scale factor separately (same split as the
  // Metal path on iOS, where mismatching the two is rejected outright).
  glGenTextures(1, &p->texture);
  glBindTexture(GL_TEXTURE_2D, p->texture);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, p->physicalWidth, p->physicalHeight,
               0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, 0);

  p->program = buildBlitProgram();
  if (!p->program) {
    destroyPresenter(p);
    return -7;
  }
  p->texUniform = glGetUniformLocation(p->program, "u_tex");

  // Hand the context off to the map's owner thread: an EGL context can be
  // current on one thread at a time, and every later call happens over
  // there — the Dart UI thread for the synchronous renderer, the render
  // worker thread for WorkerBasemapRenderer (see fmm_worker.cpp).
  eglMakeCurrent(p->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

  {
    std::lock_guard<std::mutex> lock(gPresentersMutex);
    presenters()[presenterId] = p;
  }
  return static_cast<jlong>(p->texture);
}

// Platform thread, from the SurfaceProducer destroyed callback. The presenter
// stays registered so fmm_present can report kErrSurfaceLost instead of
// touching a dead surface.
JNIEXPORT void JNICALL
Java_io_ushakov_flutter_1map_1maplibre_MlnNative_nativePresenterInvalidate(
    JNIEnv*, jclass, jlong presenterId) {
  if (auto* p = findPresenter(presenterId)) p->surfaceLost = true;
}

JNIEXPORT void JNICALL
Java_io_ushakov_flutter_1map_1maplibre_MlnNative_nativePresenterDestroy(
    JNIEnv*, jclass, jlong presenterId) {
  Presenter* p = nullptr;
  {
    std::lock_guard<std::mutex> lock(gPresentersMutex);
    auto it = presenters().find(presenterId);
    if (it != presenters().end()) {
      p = it->second;
      presenters().erase(it);
    }
  }
  destroyPresenter(p);
}

// --- FFI, called from the map's owner thread ------------------------------
// (the Dart UI thread for the synchronous renderer, the render worker thread
// for WorkerBasemapRenderer; see fmm_worker.cpp)

// Attaches the presenter's back texture to the map as an OpenGL borrowed
// texture render target. The descriptor's handles are all process-global
// native objects, so it is built here rather than marshalled through Dart.
// Runs on the caller's thread — the same thread that created the map —
// satisfying mln's owner-thread affinity. Leaves our context current.
__attribute__((visibility("default"))) int32_t fmm_attach(
    int64_t map, int64_t presenterId, int64_t* outSession) {
  auto* p = findPresenter(presenterId);
  if (!p) return static_cast<int32_t>(kErrUnknownPresenter);
  if (!outSession || !map) return MLN_STATUS_INVALID_ARGUMENT;

  if (!eglMakeCurrent(p->display, p->surface, p->surface, p->context)) {
    return static_cast<int32_t>(kErrMakeCurrent);
  }

  mln_opengl_borrowed_texture_descriptor descriptor =
      mln_opengl_borrowed_texture_descriptor_default();
  descriptor.extent.width = static_cast<uint32_t>(p->logicalWidth);
  descriptor.extent.height = static_cast<uint32_t>(p->logicalHeight);
  descriptor.extent.scale_factor = p->scale;
  descriptor.context.platform = MLN_OPENGL_CONTEXT_PLATFORM_EGL;
  descriptor.context.data.egl.display = p->display;
  descriptor.context.data.egl.config = p->config;
  descriptor.context.data.egl.share_context = p->context;
  descriptor.context.data.egl.get_proc_address =
      reinterpret_cast<void*>(&eglGetProcAddress);
  descriptor.texture = p->texture;
  descriptor.target = GL_TEXTURE_2D;

  mln_render_session* session = nullptr;
  const mln_status status = mln_opengl_borrowed_texture_attach(
      reinterpret_cast<mln_map*>(map), &descriptor, &session);
  *outSession = reinterpret_cast<int64_t>(session);
  return static_cast<int32_t>(status);
}

// Blit + swap. Called immediately after a successful render_update, which
// leaves the SESSION's context current on this thread — so ours is re-bound
// first. Returns blit+swap wall-clock ms, or a negative error code.
// SurfaceProducer notifies the engine itself on queue; no
// textureFrameAvailable equivalent is needed (unlike iOS).
__attribute__((visibility("default"))) double fmm_present(
    int64_t presenterId) {
  auto* p = findPresenter(presenterId);
  if (!p) return kErrUnknownPresenter;
  if (p->surfaceLost) return kErrSurfaceLost;

  const double started = nowMs();

  // Cross-context sync. On entry the SESSION's context is still current on
  // this thread (render_update leaves it that way), so a fence created here
  // orders everything the session just submitted. Sync objects are shared
  // across the share group; glWaitSync in our context is a server-side wait —
  // the GPU serializes, the CPU does not stall (unlike the glFinish this
  // replaces). No context current (first present, or present-after-fill in
  // our own context) simply means nothing foreign to wait for.
  GLsync fence = nullptr;
  if (eglGetCurrentContext() != EGL_NO_CONTEXT) {
    fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glFlush();  // The fence must reach the GPU before another context waits.
  }

  // The session runs on its own context; rebind ours before touching the
  // window surface. Textures are shared across the group, surfaces are not.
  if (!eglMakeCurrent(p->display, p->surface, p->surface, p->context)) {
    if (fence) glDeleteSync(fence);
    return kErrMakeCurrent;
  }

  if (fence) {
    glWaitSync(fence, 0, GL_TIMEOUT_IGNORED);
    glDeleteSync(fence);
  }

  glViewport(0, 0, p->physicalWidth, p->physicalHeight);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glUseProgram(p->program);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, p->texture);
  glUniform1i(p->texUniform, 0);
  glDrawArrays(GL_TRIANGLES, 0, 3);

  if (glGetError() != GL_NO_ERROR) return kErrSwapFailed;
  if (!eglSwapBuffers(p->display, p->surface)) return kErrSwapFailed;
  return nowMs() - started;
}

// Debug only: clear the back texture to a solid colour through a scratch FBO,
// so a following fmm_present proves the whole presentation path without
// MapLibre involved (the Android analogue of iOS Checkpoint B).
__attribute__((visibility("default"))) int32_t fmm_debug_fill(
    int64_t presenterId, double red, double green, double blue) {
  auto* p = findPresenter(presenterId);
  if (!p) return static_cast<int32_t>(kErrUnknownPresenter);

  if (!eglMakeCurrent(p->display, p->surface, p->surface, p->context)) {
    return static_cast<int32_t>(kErrMakeCurrent);
  }
  if (!p->fillFbo) glGenFramebuffers(1, &p->fillFbo);
  glBindFramebuffer(GL_FRAMEBUFFER, p->fillFbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         p->texture, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return -1;
  }
  glClearColor(static_cast<float>(red), static_cast<float>(green),
               static_cast<float>(blue), 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  return 0;
}

// Keeps every mln_* function Dart looks up via dart:ffi alive in the .so.
// Nothing native references most of these any more (the spike-era JNI loop
// that did is gone), and without a reference the linker's --gc-sections
// strips exactly the symbols Dart needs — which fails only at runtime, as a
// lookup exception. MLN_API carries default visibility, so a reference is
// all it takes to keep them exported.
__attribute__((used, visibility("default"))) void* const fmm_keep_alive[] = {
    reinterpret_cast<void*>(&mln_c_version),
    reinterpret_cast<void*>(&mln_supported_render_backend_mask),
    reinterpret_cast<void*>(&mln_runtime_options_default),
    reinterpret_cast<void*>(&mln_runtime_create),
    reinterpret_cast<void*>(&mln_runtime_destroy),
    reinterpret_cast<void*>(&mln_runtime_run_once),
    reinterpret_cast<void*>(&mln_runtime_poll_event),
    reinterpret_cast<void*>(&mln_map_options_default),
    reinterpret_cast<void*>(&mln_map_create),
    reinterpret_cast<void*>(&mln_map_destroy),
    reinterpret_cast<void*>(&mln_map_set_style_url),
    reinterpret_cast<void*>(&mln_map_request_repaint),
    reinterpret_cast<void*>(&mln_map_jump_to),
    reinterpret_cast<void*>(&mln_camera_options_default),
    reinterpret_cast<void*>(&mln_render_session_render_update),
    reinterpret_cast<void*>(&mln_render_session_destroy),
};

}  // extern "C"
