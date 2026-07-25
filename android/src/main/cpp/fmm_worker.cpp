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
