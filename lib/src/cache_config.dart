import 'offline/maplibre_offline.dart';

/// Process-level cache configuration for the mln runtimes.
///
/// Spec: docs/superpowers/specs/2026-08-24-persistent-cache-and-offline-seeding.md.
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

  /// The configured cache directory, or null when unconfigured. The cache
  /// key file lives here, next to (not inside) the database, so it
  /// survives the purge.
  static String? get directory => _directory;

  /// The remote kill switch (spec: "Cache key"). An opaque token compared
  /// for difference against the persisted copy; a change means "what you
  /// have cached is suspect" and triggers a full destructive purge —
  /// regions deleted and reseeded, ambient cleared, live maps re-rendered.
  /// Callable at any time, any number of times, idempotent; completes when
  /// the purge (if any) has committed. Null means "not managing" and never
  /// purges. Wire it to Firebase Remote Config activation: unchanged keys
  /// are free.
  static Future<void> setCacheKey(String? key) =>
      MaplibreOffline.setCacheKey(key);

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
