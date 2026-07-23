#include <maplibre_native_c.h>

// Dart resolves mln_* through dlsym on the app image
// (DynamicLibrary.process()). The C API is linked as a static archive, so any
// function the linker considers unused is dead-stripped and dlsym returns
// null. This table references every symbol the Dart bindings call, keeping
// them alive through the app link. Update it whenever ffigen.yaml's function
// list changes.
__attribute__((used)) void* const mln_ffi_symbol_keeper[] = {
  (void*)mln_c_version,
  (void*)mln_supported_render_backend_mask,
  (void*)mln_runtime_options_default,
  (void*)mln_runtime_create,
  (void*)mln_runtime_destroy,
  (void*)mln_runtime_run_once,
  (void*)mln_runtime_poll_event,
  (void*)mln_map_options_default,
  (void*)mln_map_create,
  (void*)mln_map_destroy,
  (void*)mln_map_set_style_url,
  (void*)mln_map_request_repaint,
  (void*)mln_camera_options_default,
  (void*)mln_map_jump_to,
  (void*)mln_metal_borrowed_texture_descriptor_default,
  (void*)mln_metal_borrowed_texture_attach,
  (void*)mln_render_session_render_update,
  (void*)mln_render_session_destroy,
};
