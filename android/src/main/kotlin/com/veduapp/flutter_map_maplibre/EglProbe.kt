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
