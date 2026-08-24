import '../ffi/maplibre_bindings.dart';
import '../ffi/mln_library.dart';

/// Process-global switch over MapLibre's own network layer.
///
/// Forcing offline makes the online source stop issuing requests entirely,
/// so a session renders purely from the cache database — the tool for
/// testing offline behavior deterministically (airplane mode without the
/// airplane). Callable before any runtime exists.
///
/// Not a substitute for reacting to real connectivity: MapLibre already
/// fails fast when the device is offline, and holding this flag long-term
/// keeps online requests permanently pending, which can stop the map from
/// ever reaching idle (see the spec's probe caveats).
///
/// iOS-verified; on Android the render/offline workers link the mln
/// library into the app's shared library, where this symbol may not be
/// exported — the call throws [ArgumentError] if the lookup fails, so
/// wrap it when used outside a test harness.
class MaplibreNetwork {
  MaplibreNetwork._();

  static final MaplibreBindings _b = MaplibreBindings(mlnLibrary);

  // MLN_NETWORK_STATUS_ONLINE = 1, MLN_NETWORK_STATUS_OFFLINE = 2.
  static const _online = 1;
  static const _offline = 2;

  /// Returns the mln status (0 = OK).
  static int setOffline(bool offline) =>
      _b.mln_network_status_set(offline ? _offline : _online);
}
