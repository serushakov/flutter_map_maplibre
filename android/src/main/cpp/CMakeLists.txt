cmake_minimum_required(VERSION 3.18)
project(mln_jni C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Prebuilt maplibre-native-ffi archive. Too big for git: a GitHub release
# asset (made by scripts/package_native.sh), fetched here at configure time.
# The headers in prebuilt/include/ are tracked. A local build instead:
#   ANDROID_HOME=~/Library/Android/sdk \
#   MLN_FFI_ANDROID_NDK_VERSION=28.2.13676358 \
#   cmake --preset android-arm64-egl && cmake --build --preset android-arm64-egl
# then copy the complete static archive into prebuilt/<abi>/.
set(MLN_PREBUILT "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt")
set(MLN_NATIVE_URL
  "https://github.com/serushakov/flutter_map_maplibre/releases/download/native-94e6f08/mln-android.zip")
set(MLN_NATIVE_SHA256
  "2d161f489d5c8396f46a7a0c050014196c7beada90017b4e7623c3c70bfe9c16")

# A stamp records which asset is unpacked, so bumping the hash re-fetches.
# An archive with no stamp is a local build and is left alone. The lock
# serialises parallel configures (one per variant).
set(_mln_archive "${MLN_PREBUILT}/arm64-v8a/libmaplibre-native-c.a")
set(_mln_stamp "${MLN_PREBUILT}/.mln-native-sha")
file(LOCK "${MLN_PREBUILT}/.mln-native.lock")
set(_mln_stamped FALSE)
if(EXISTS "${_mln_stamp}")
  file(READ "${_mln_stamp}" _mln_have)
  string(STRIP "${_mln_have}" _mln_have)
  if(_mln_have STREQUAL MLN_NATIVE_SHA256)
    set(_mln_stamped TRUE)
  endif()
endif()
if(NOT _mln_stamped AND NOT (EXISTS "${_mln_archive}" AND NOT EXISTS "${_mln_stamp}"))
  message(STATUS "flutter_map_maplibre: downloading ${MLN_NATIVE_URL}")
  set(_mln_zip "${MLN_PREBUILT}/mln-android.zip")
  file(DOWNLOAD "${MLN_NATIVE_URL}" "${_mln_zip}"
    EXPECTED_HASH SHA256=${MLN_NATIVE_SHA256}
    TLS_VERIFY ON
    STATUS _mln_status)
  list(GET _mln_status 0 _mln_code)
  if(NOT _mln_code EQUAL 0)
    message(FATAL_ERROR "flutter_map_maplibre: native download failed: ${_mln_status}")
  endif()
  file(REMOVE_RECURSE "${MLN_PREBUILT}/arm64-v8a" "${MLN_PREBUILT}/licenses")
  file(ARCHIVE_EXTRACT INPUT "${_mln_zip}" DESTINATION "${MLN_PREBUILT}")
  file(REMOVE "${_mln_zip}")
  file(WRITE "${_mln_stamp}" "${MLN_NATIVE_SHA256}")
endif()
file(LOCK "${MLN_PREBUILT}/.mln-native.lock" RELEASE)

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
