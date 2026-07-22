// JNI shim over maplibre-native-ffi for Android.
//
// Mirrors the iOS MLNBridge: all EGL and MapLibre calls live here in C++, and
// Kotlin only drives the loop. Doing EGL here rather than in Kotlin keeps the
// context, the surface and the render session owned by one thread with no
// handle marshalling.
//
// MapLibre renders into a texture we own (mln_opengl_borrowed_texture_attach),
// which we then blit onto the window surface. The surface-session path does not
// work here: the session creates its own context in our share group, and while
// a share group shares texture objects it does NOT share window surfaces, so
// the session renders into its own default framebuffer and our swap presents an
// untouched buffer. Textures cross the share group; surfaces do not.

#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>

#include <string>

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

struct Renderer {
  ANativeWindow* window = nullptr;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLConfig config = nullptr;
  EGLContext context = EGL_NO_CONTEXT;
  EGLSurface surface = EGL_NO_SURFACE;

  GLuint texture = 0;
  GLuint program = 0;
  GLint texUniform = -1;

  int physicalWidth = 0;
  int physicalHeight = 0;

  mln_runtime* runtime = nullptr;
  mln_map* map = nullptr;
  mln_render_session* session = nullptr;

  int frameCount = 0;
  int lastStatus = 0;
  int attachStatus = -99;
  int swapped = -1;
  int glError = 0;
  bool styleLoaded = false;
  std::string lastEventMessage;
};

Renderer* asRenderer(jlong handle) {
  return reinterpret_cast<Renderer*>(handle);
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

void destroyRenderer(Renderer* r) {
  if (!r) return;
  if (r->session) mln_render_session_destroy(r->session);
  if (r->map) mln_map_destroy(r->map);
  if (r->runtime) mln_runtime_destroy(r->runtime);
  if (r->display != EGL_NO_DISPLAY) {
    if (r->context != EGL_NO_CONTEXT) {
      eglMakeCurrent(r->display, r->surface, r->surface, r->context);
      if (r->program) glDeleteProgram(r->program);
      if (r->texture) glDeleteTextures(1, &r->texture);
    }
    eglMakeCurrent(r->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (r->surface != EGL_NO_SURFACE) eglDestroySurface(r->display, r->surface);
    if (r->context != EGL_NO_CONTEXT) eglDestroyContext(r->display, r->context);
    eglTerminate(r->display);
  }
  if (r->window) ANativeWindow_release(r->window);
  delete r;
}

}  // namespace

extern "C" {

// Must run before any HTTP: the Rust/rustls stack needs the Android context to
// reach the platform trust store. Without it every tile request fails TLS
// validation and the map renders its background colour and nothing else.
JNIEXPORT jint JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeAndroidInit(
    JNIEnv* env, jclass clazz, jobject context) {
  return mln_android_init(env, clazz, context);
}

JNIEXPORT jlong JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeCreate(
    JNIEnv* env, jclass, jobject jsurface, jint width, jint height,
    jdouble scale, jstring jstyleUrl) {
  auto* r = new Renderer();

  r->physicalWidth = static_cast<int>(width * scale + 0.5);
  r->physicalHeight = static_cast<int>(height * scale + 0.5);

  r->window = ANativeWindow_fromSurface(env, jsurface);
  if (!r->window) {
    destroyRenderer(r);
    return 0;
  }

  r->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (r->display == EGL_NO_DISPLAY || !eglInitialize(r->display, nullptr, nullptr)) {
    destroyRenderer(r);
    return 0;
  }

  // EGL_PBUFFER_BIT is required by the FFI for texture sessions (the session
  // needs a surfaceless-ish context of its own); EGL_WINDOW_BIT is required for
  // our own blit target. The config must satisfy both.
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
  if (!eglChooseConfig(r->display, configAttrs, &r->config, 1, &numConfigs) ||
      numConfigs == 0) {
    destroyRenderer(r);
    return 0;
  }

  const EGLint contextAttrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  r->context =
      eglCreateContext(r->display, r->config, EGL_NO_CONTEXT, contextAttrs);
  if (r->context == EGL_NO_CONTEXT) {
    destroyRenderer(r);
    return 0;
  }

  r->surface =
      eglCreateWindowSurface(r->display, r->config, r->window, nullptr);
  if (r->surface == EGL_NO_SURFACE) {
    destroyRenderer(r);
    return 0;
  }

  if (!eglMakeCurrent(r->display, r->surface, r->surface, r->context)) {
    destroyRenderer(r);
    return 0;
  }

  // The texture MapLibre draws into. Physical pixels — the descriptor extent
  // stays logical and carries the scale factor separately (same split as the
  // Metal path on iOS, where mismatching the two is rejected outright).
  glGenTextures(1, &r->texture);
  glBindTexture(GL_TEXTURE_2D, r->texture);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, r->physicalWidth, r->physicalHeight, 0,
               GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, 0);

  r->program = buildBlitProgram();
  if (!r->program) {
    destroyRenderer(r);
    return 0;
  }
  r->texUniform = glGetUniformLocation(r->program, "u_tex");

  mln_runtime_options runtimeOptions = mln_runtime_options_default();
  runtimeOptions.cache_path = ":memory:";
  if (mln_runtime_create(&runtimeOptions, &r->runtime) != MLN_STATUS_OK) {
    destroyRenderer(r);
    return 0;
  }

  mln_map_options mapOptions = mln_map_options_default();
  mapOptions.width = static_cast<uint32_t>(width);
  mapOptions.height = static_cast<uint32_t>(height);
  mapOptions.scale_factor = scale;
  mapOptions.map_mode = MLN_MAP_MODE_CONTINUOUS;
  if (mln_map_create(r->runtime, &mapOptions, &r->map) != MLN_STATUS_OK) {
    destroyRenderer(r);
    return 0;
  }

  const char* styleUrl = env->GetStringUTFChars(jstyleUrl, nullptr);
  mln_map_set_style_url(r->map, styleUrl);
  env->ReleaseStringUTFChars(jstyleUrl, styleUrl);
  mln_map_request_repaint(r->map);

  mln_opengl_borrowed_texture_descriptor descriptor =
      mln_opengl_borrowed_texture_descriptor_default();
  descriptor.extent.width = static_cast<uint32_t>(width);
  descriptor.extent.height = static_cast<uint32_t>(height);
  descriptor.extent.scale_factor = scale;
  descriptor.context.platform = MLN_OPENGL_CONTEXT_PLATFORM_EGL;
  descriptor.context.data.egl.display = r->display;
  descriptor.context.data.egl.config = r->config;
  descriptor.context.data.egl.share_context = r->context;
  descriptor.context.data.egl.get_proc_address =
      reinterpret_cast<void*>(&eglGetProcAddress);
  descriptor.texture = r->texture;
  descriptor.target = GL_TEXTURE_2D;

  r->attachStatus =
      mln_opengl_borrowed_texture_attach(r->map, &descriptor, &r->session);
  if (r->attachStatus != MLN_STATUS_OK) {
    destroyRenderer(r);
    return 0;
  }

  return reinterpret_cast<jlong>(r);
}

JNIEXPORT jboolean JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeRender(JNIEnv*, jclass,
                                                               jlong handle) {
  auto* r = asRenderer(handle);
  if (!r || !r->runtime || !r->session) return JNI_FALSE;

  mln_runtime_run_once(r->runtime);

  mln_runtime_event event{};
  event.size = static_cast<uint32_t>(sizeof(event));
  bool hasEvent = false;
  do {
    hasEvent = false;
    if (mln_runtime_poll_event(r->runtime, &event, &hasEvent) != MLN_STATUS_OK) {
      break;
    }
    if (!hasEvent) break;
    // Style and render failures are otherwise completely silent: the map just
    // renders nothing, which is indistinguishable from a broken texture path.
    if (event.type == MLN_RUNTIME_EVENT_MAP_STYLE_LOADED) {
      r->styleLoaded = true;
    } else if (event.type == MLN_RUNTIME_EVENT_MAP_LOADING_FAILED ||
               event.type == MLN_RUNTIME_EVENT_MAP_RENDER_ERROR) {
      r->lastEventMessage.assign(
          event.message ? event.message : "(no message)",
          event.message ? event.message_size : 12);
    }
  } while (hasEvent);

  r->lastStatus = mln_render_session_render_update(r->session);
  if (r->lastStatus != MLN_STATUS_OK) return JNI_FALSE;

  // The session runs on its own context; rebind ours before touching the
  // window surface. Textures are shared across the group, surfaces are not.
  if (!eglMakeCurrent(r->display, r->surface, r->surface, r->context)) {
    return JNI_FALSE;
  }

  // Crude cross-context sync for the spike: glFinish on the consumer side does
  // not order the producer's commands, so a torn frame is possible. A proper
  // fix is an EGLSync fence created after render_update.
  glFinish();

  glViewport(0, 0, r->physicalWidth, r->physicalHeight);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glUseProgram(r->program);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, r->texture);
  glUniform1i(r->texUniform, 0);
  glDrawArrays(GL_TRIANGLES, 0, 3);

  r->glError = static_cast<int>(glGetError());
  r->swapped = eglSwapBuffers(r->display, r->surface) ? 1 : 0;
  r->frameCount++;
  return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeSetCamera(
    JNIEnv*, jclass, jlong handle, jdouble lat, jdouble lng, jdouble zoom,
    jdouble bearing) {
  auto* r = asRenderer(handle);
  if (!r || !r->map) return;
  mln_camera_options camera = mln_camera_options_default();
  camera.fields = MLN_CAMERA_OPTION_CENTER | MLN_CAMERA_OPTION_ZOOM |
                  MLN_CAMERA_OPTION_BEARING;
  camera.latitude = lat;
  camera.longitude = lng;
  camera.zoom = zoom;
  camera.bearing = bearing;
  mln_map_jump_to(r->map, &camera);
  mln_map_request_repaint(r->map);
}

JNIEXPORT void JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeSetStyle(
    JNIEnv* env, jclass, jlong handle, jstring jstyleUrl) {
  auto* r = asRenderer(handle);
  if (!r || !r->map) return;
  const char* styleUrl = env->GetStringUTFChars(jstyleUrl, nullptr);
  mln_map_set_style_url(r->map, styleUrl);
  env->ReleaseStringUTFChars(jstyleUrl, styleUrl);
  mln_map_request_repaint(r->map);
}

JNIEXPORT jint JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeFrameCount(JNIEnv*,
                                                                   jclass,
                                                                   jlong handle) {
  auto* r = asRenderer(handle);
  return r ? r->frameCount : 0;
}

JNIEXPORT jint JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeSwapped(JNIEnv*, jclass,
                                                                jlong handle) {
  auto* r = asRenderer(handle);
  return r ? r->swapped : -2;
}

JNIEXPORT jint JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeAttachStatus(
    JNIEnv*, jclass, jlong handle) {
  auto* r = asRenderer(handle);
  return r ? r->attachStatus : -99;
}

JNIEXPORT jint JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeGlError(JNIEnv*, jclass,
                                                                jlong handle) {
  auto* r = asRenderer(handle);
  return r ? r->glError : -1;
}

JNIEXPORT jboolean JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeStyleLoaded(
    JNIEnv*, jclass, jlong handle) {
  auto* r = asRenderer(handle);
  return (r && r->styleLoaded) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeLastEvent(
    JNIEnv* env, jclass, jlong handle) {
  auto* r = asRenderer(handle);
  if (!r || r->lastEventMessage.empty()) return nullptr;
  return env->NewStringUTF(r->lastEventMessage.c_str());
}

JNIEXPORT void JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeDestroy(JNIEnv*, jclass,
                                                                jlong handle) {
  destroyRenderer(asRenderer(handle));
}

}  // extern "C"
