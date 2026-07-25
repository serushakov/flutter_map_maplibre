cmake_minimum_required(VERSION 3.18)
project(mln_jni C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Prebuilt maplibre-native-ffi artifacts. NOT committed — see .gitignore.
# Produced by:
#   ANDROID_HOME=~/Library/Android/sdk \
#   MLN_FFI_ANDROID_NDK_VERSION=28.2.13676358 \
#   cmake --preset android-arm64-egl && cmake --build --preset android-arm64-egl
# then copy include/ and the complete static archive into prebuilt/.
set(MLN_PREBUILT "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt")

add_library(maplibre_native_c STATIC IMPORTED)
set_target_properties(maplibre_native_c PROPERTIES
  IMPORTED_LOCATION "${MLN_PREBUILT}/${ANDROID_ABI}/libmaplibre-native-c.a")

add_library(mln_jni SHARED
  mln_jni.cpp
  fmm_worker.cpp
  dart_include/dart_api_dl.c)

target_include_directories(mln_jni PRIVATE
  "${MLN_PREBUILT}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/dart_include")

target_link_libraries(mln_jni
  maplibre_native_c
  android
  EGL
  GLESv3
  log
  z)
