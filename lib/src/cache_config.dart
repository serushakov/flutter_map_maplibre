/// Process-level cache configuration for the mln runtimes.
///
/// Spec: docs/superpowers/specs/2026-08-24-persistent-cache-and-offline-seeding.md.
/// This is the durable-path slice only (plus the ambient byte cap); the
/// cache key and offline seeding facade are separate steps.
///
/// Runtimes are shared (per-thread on iOS, one per Android worker), so the
/// cache path and budget are runtime configuration, not widget parameters:
/// two widgets must never disagree about the same database.
class MaplibreCache {
  MaplibreCache._();

  static String? _directory;
  static int? _maxAmbientBytes;
  static bool _runtimeExists = false;

  /// Call once, before the first `MapLibreBasemap` is built. Unconfigured,
  /// runtimes keep today's `:memory:` database and nothing persists.
  ///
  /// [directory] must exist and be writable (the caller owns the choice —
  /// this package deliberately has no path_provider dependency).
  /// [maxAmbientBytes] caps the evictable (ambient) class only; offline
  /// region resources are pinned outside it.
  static void configure({required String directory, int? maxAmbientBytes}) {
    if (_runtimeExists) {
      throw StateError(
        'MaplibreCache.configure must run before the first runtime is '
        'created (build a MapLibreBasemap only after configuring).',
      );
    }
    _directory = directory;
    _maxAmbientBytes = maxAmbientBytes;
  }

  /// The database path runtimes should use. `:memory:` when unconfigured.
  static String get databasePath =>
      _directory == null ? ':memory:' : '$_directory/maplibre_cache.db';

  /// Ambient byte cap, or null to keep MapLibre's default.
  static int? get maxAmbientBytes => _maxAmbientBytes;

  /// Runtime creation sites call this so a late configure() fails loudly
  /// instead of silently splitting state across two databases.
  static void markRuntimeCreated() => _runtimeExists = true;

  /// Test seam.
  static void resetForTesting() {
    _directory = null;
    _maxAmbientBytes = null;
    _runtimeExists = false;
  }
}
