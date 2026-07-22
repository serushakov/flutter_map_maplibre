// JNI shim over maplibre-native-ffi for Android.
//
// Mirrors the iOS MLNBridge: all EGL and MapLibre calls live here in C++, and
// Kotlin only drives the loop. Doing EGL here rather than in Kotlin keeps the
// context, the surface and the render session owned by one thread with no
// handle marshalling.

#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>

#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <string>

#include <maplibre_native_c.h>
#include <maplibre_native_c/android.h>

namespace {

struct Renderer {
  ANativeWindow* window = nullptr;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLConfig config = nullptr;
  EGLContext context = EGL_NO_CONTEXT;
  EGLSurface surface = EGL_NO_SURFACE;

  mln_runtime* runtime = nullptr;
  mln_map* map = nullptr;
  mln_render_session* session = nullptr;

  int frameCount = 0;
  int lastStatus = 0;
  int swapped = -1;
  std::string error;
};

Renderer* asRenderer(jlong handle) {
  return reinterpret_cast<Renderer*>(handle);
}

void destroyRenderer(Renderer* r) {
  if (!r) return;
  if (r->session) mln_render_session_destroy(r->session);
  if (r->map) mln_map_destroy(r->map);
  if (r->runtime) mln_runtime_destroy(r->runtime);
  if (r->display != EGL_NO_DISPLAY) {
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

  const EGLint configAttrs[] = {EGL_RENDERABLE_TYPE,
                                EGL_OPENGL_ES3_BIT,
                                EGL_SURFACE_TYPE,
                                EGL_WINDOW_BIT,
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

  mln_opengl_surface_descriptor descriptor =
      mln_opengl_surface_descriptor_default();
  descriptor.extent.width = static_cast<uint32_t>(width);
  descriptor.extent.height = static_cast<uint32_t>(height);
  descriptor.extent.scale_factor = scale;
  descriptor.context.platform = MLN_OPENGL_CONTEXT_PLATFORM_EGL;
  descriptor.context.data.egl.display = r->display;
  descriptor.context.data.egl.config = r->config;
  descriptor.context.data.egl.share_context = r->context;
  descriptor.context.data.egl.get_proc_address =
      reinterpret_cast<void*>(&eglGetProcAddress);
  descriptor.surface = r->surface;

  if (mln_opengl_surface_attach(r->map, &descriptor, &r->session) !=
      MLN_STATUS_OK) {
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
  } while (hasEvent);

  r->lastStatus = mln_render_session_render_update(r->session);
  if (r->lastStatus == MLN_STATUS_OK) {
    // The FFI documents EGL surface sessions as presenting via eglSwapBuffers.
    // Swapping here as well is how we find out whether it actually does: if
    // the map only appears with this line, the session is not presenting.
    r->swapped = eglSwapBuffers(r->display, r->surface) ? 1 : 0;
    r->frameCount++;
    return JNI_TRUE;
  }
  return JNI_FALSE;
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

JNIEXPORT void JNICALL
Java_com_veduapp_flutter_1map_1maplibre_MlnNative_nativeDestroy(JNIEnv*, jclass,
                                                                jlong handle) {
  destroyRenderer(asRenderer(handle));
}

}  // extern "C"
