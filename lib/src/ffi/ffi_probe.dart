import 'dart:ffi';

import 'maplibre_bindings.dart';

/// Confirms the statically linked maplibre_native_c symbols are visible to
/// dart:ffi in this build — the go/no-go gate for the FFI port (spec, risk 1).
/// Returns a one-line diagnostic for the MLNFFI log.
String probeMaplibreFfi() {
  try {
    final bindings = MaplibreBindings(DynamicLibrary.process());
    final version = bindings.mln_c_version();
    final backends = bindings.mln_supported_render_backend_mask();
    return 'ok version=$version backends=0x${backends.toRadixString(16)}';
  } catch (e) {
    return 'FAILED: $e';
  }
}
