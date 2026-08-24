import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;

import '../cache_config.dart';
import '../ffi/ffi_basemap_renderer.dart';
import '../ffi/worker_basemap_renderer.dart';
import 'ffi_offline_link.dart';
import 'offline_link.dart';
import 'offline_types.dart';
import 'tile_count.dart' as tile_math;
import 'worker_offline_link.dart';

/// Offline seeding facade
/// (docs/superpowers/specs/2026-08-24-persistent-cache-and-offline-seeding.md).
///
/// One static state machine over an [OfflineLink], platform-independent and
/// fake-testable. The link (and with it the shared runtime user refcount and
/// the pump timer) exists only while there is work: pending requests or
/// unfinished downloads. When the last one drains, the link is disposed —
/// so an idle app keeps today's lifecycle, while an active download keeps
/// the runtime alive even after the last map disposes.
class MaplibreOffline {
  MaplibreOffline._();

  /// Test seam: replaces the platform link factory.
  @visibleForTesting
  static OfflineLink Function()? debugLinkFactory;

  /// Debug aid: print every [OfflineEvent] the link delivers.
  static bool debugLogEvents = false;

  /// How often the facade pumps the link while work is in flight. The
  /// renderers' ticker parks on idle, so downloads need their own driver;
  /// this is deliberately slow — progress, not frames.
  static Duration pumpInterval = const Duration(milliseconds: 500);

  static OfflineLink? _link;
  static Timer? _pumpTimer;
  static int _requestSeq = 0;
  static int _groupSeq = 0;
  static final Map<int, Completer<Object?>> _pendingRequests = {};
  static final Map<String, _RegionGroup> _groups = {};
  static final Map<int, _RegionGroup> _groupByRegion = {};

  /// Depth of composite operations in flight (createRegion's multi-command
  /// sequence must not lose the link between steps).
  static int _busy = 0;

  /// Pure Web-Mercator estimate of the tile count a region over [bounds]
  /// at zooms [minZoom]..[maxZoom] would pin. Over-counts safely (see
  /// `estimateTileCount` in tile_count.dart). The estimate is per-pyramid:
  /// seeding multiple styles over the same bounds shares tiles by URL, so
  /// the budget compares against this un-multiplied number.
  static int estimateTileCount({
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
  }) => tile_math.estimateTileCount(
    south: bounds.south,
    west: bounds.west,
    north: bounds.north,
    east: bounds.east,
    minZoom: minZoom,
    maxZoom: maxZoom,
  );

  /// Seeds [bounds] at zooms [minZoom]..[maxZoom] for every style in
  /// [styleUrls] as one unit: one handle, combined progress, deleted
  /// together. Seed both themes — forgetting dark is exactly the bug
  /// someone ships; thanks to URL-keyed dedup the second theme costs
  /// kilobytes when the styles share tile sources.
  ///
  /// Throws [TileBudgetExceeded] before touching native when the
  /// Web-Mercator estimate exceeds [maxTiles]. The download continues
  /// while the app runs regardless of whether a map widget is live;
  /// it does not resume on the next launch by itself (re-create the same
  /// region: already-present rows pin instantly, only missing ones fetch).
  ///
  /// [includeIdeographs] pre-downloads CJK glyph ranges — large, and only
  /// useful if users will pan there offline.
  static Future<OfflineRegionHandle> createRegion({
    required List<String> styleUrls,
    required LatLngBounds bounds,
    required int minZoom,
    required int maxZoom,
    int? maxTiles,
    double pixelRatio = 1.0,
    bool includeIdeographs = false,
  }) async {
    if (styleUrls.isEmpty) {
      throw ArgumentError('styleUrls must not be empty');
    }
    final estimate = estimateTileCount(
      bounds: bounds,
      minZoom: minZoom,
      maxZoom: maxZoom,
    );
    if (maxTiles != null && estimate > maxTiles) {
      throw TileBudgetExceeded(estimatedTiles: estimate, maxTiles: maxTiles);
    }
    _busy++;
    try {
      final groupId = 'g${++_groupSeq}-${identityHashCode(_groups)}';
      final metadata = Uint8List.fromList(
        utf8.encode(jsonEncode({'fmm': 1, 'group': groupId})),
      );
      final regionIds = <int>[];
      Future<void> rollback() async {
        // Best-effort: a half-created pair must not linger as a seed that
        // never matches its sibling.
        for (final regionId in regionIds) {
          try {
            await _request<Object?>(
              (id, link) =>
                  link.deleteRegion(requestId: id, regionId: regionId),
            );
          } catch (_) {}
        }
      }

      try {
        for (final styleUrl in styleUrls) {
          final definition = OfflineRegionDefinition(
            styleUrl: styleUrl,
            south: bounds.south,
            west: bounds.west,
            north: bounds.north,
            east: bounds.east,
            minZoom: minZoom.toDouble(),
            maxZoom: maxZoom.toDouble(),
            pixelRatio: pixelRatio,
            includeIdeographs: includeIdeographs,
          );
          regionIds.add(
            await _request<int>(
              (id, link) => link.createRegion(
                requestId: id,
                definition: definition,
                metadata: metadata,
              ),
            ),
          );
        }
      } catch (_) {
        await rollback();
        rethrow;
      }
      // Register the group BEFORE observing anything: events are drained in
      // synchronous pump batches, so any status emitted while this method
      // is still awaiting acks would otherwise be dropped — and a member
      // that completes inside such a batch never emits again (probe-
      // observed hang: fully-deduped dark region finished before the group
      // existed). With routing live from the start, no event has nowhere
      // to go.
      final group = _RegionGroup(groupId, regionIds.toSet());
      _groups[groupId] = group;
      for (final regionId in regionIds) {
        _groupByRegion[regionId] = group;
      }
      try {
        await _observeActivatePrime(regionIds);
      } catch (error) {
        group._abort(StateError('offline region setup failed: $error'));
        await rollback();
        rethrow;
      }
      return OfflineRegionHandle._(groupId, group);
    } finally {
      _busy--;
      _maybeGoIdle();
    }
  }

  /// Every seeded region on disk, grouped back into the units [createRegion]
  /// made (native regions carry the group id in their metadata; regions this
  /// package didn't create list as single-style groups `native:<id>`).
  /// Progress fields are a snapshot at call time — `completedBytes` is what
  /// the region really pins on disk.
  static Future<List<OfflineRegion>> listRegions() async {
    _busy++;
    try {
      final records = await _request<List<OfflineRegionRecord>>(
        (id, link) => link.listRegions(requestId: id),
      );
      final byGroup = <String, List<OfflineRegionRecord>>{};
      for (final record in records) {
        byGroup.putIfAbsent(_groupIdOf(record), () => []).add(record);
      }
      final regions = <OfflineRegion>[];
      for (final entry in byGroup.entries) {
        OfflineRegionProgress? progress;
        for (final record in entry.value) {
          final one = await _request<OfflineRegionProgress>(
            (id, link) =>
                link.requestStatus(requestId: id, regionId: record.regionId),
          );
          progress = progress == null ? one : progress + one;
        }
        final definition = entry.value.first.definition;
        regions.add(
          OfflineRegion(
            id: entry.key,
            styleUrls: [for (final r in entry.value) r.definition.styleUrl],
            bounds: definition.bounds,
            minZoom: definition.minZoom.round(),
            maxZoom: definition.maxZoom.round(),
            pixelRatio: definition.pixelRatio,
            progress: progress ?? OfflineRegionProgress.zero,
          ),
        );
      }
      return regions;
    } finally {
      _busy--;
      _maybeGoIdle();
    }
  }

  /// Deletes the whole group (both themes of a pair at once), unpinning its
  /// resources — bytes shared with other regions or the ambient class stay.
  /// Deleting a region that is still downloading aborts it: its handle's
  /// stream and `whenComplete` error.
  static Future<void> deleteRegion(String id) async {
    _busy++;
    try {
      final records = await _request<List<OfflineRegionRecord>>(
        (requestId, link) => link.listRegions(requestId: requestId),
      );
      final members = [
        for (final r in records)
          if (_groupIdOf(r) == id) r.regionId,
      ];
      if (members.isEmpty) {
        throw ArgumentError('no offline region with id $id');
      }
      final active = _groups[id];
      active?._abort(StateError('offline region $id deleted while active'));
      for (final regionId in members) {
        await _request<Object?>(
          (requestId, link) =>
              link.deleteRegion(requestId: requestId, regionId: regionId),
        );
      }
    } finally {
      _busy--;
      _maybeGoIdle();
    }
  }

  /// Observe + activate + status-prime every member of a just-registered
  /// group. The prime replies route into the group like any status event:
  /// a member whose resources were already fully cached may complete
  /// without ever emitting an observed change.
  static Future<void> _observeActivatePrime(List<int> regionIds) async {
    for (final regionId in regionIds) {
      await _request<Object?>(
        (id, link) =>
            link.setObserved(requestId: id, regionId: regionId, observed: true),
      );
      await _request<Object?>(
        (id, link) => link.setDownloadState(
          requestId: id,
          regionId: regionId,
          active: true,
        ),
      );
    }
    for (final regionId in regionIds) {
      await _request<OfflineRegionProgress>(
        (id, link) => link.requestStatus(requestId: id, regionId: regionId),
      );
    }
  }

  // --- cache key (the remote kill switch) ---------------------------------

  /// The purge nudge for live maps, swappable in tests.
  @visibleForTesting
  static void Function() nudgeLiveRenderers = _defaultNudge;

  static void _defaultNudge() {
    FfiBasemapRenderer.nudgeAllForCachePurge();
    WorkerBasemapRenderer.nudgeAllForCachePurge();
  }

  static Future<void> _keyQueue = Future.value();

  /// See [MaplibreCache.setCacheKey] — that is the canonical entry point;
  /// the machinery lives here because the purge runs through the offline
  /// link.
  ///
  /// Compares [key] against the persisted copy (equality, not ordering)
  /// and on difference runs the full destructive purge: capture region
  /// definitions → delete regions → clear ambient → recreate + reactivate
  /// seeds → persist the key → nudge live maps. The key persists only
  /// after the purge commits (at-least-once: a crash mid-purge re-runs it
  /// on the next call). Calls serialize; an unchanged key is a free no-op;
  /// null means "not managing" and never purges.
  static Future<void> setCacheKey(String? key) {
    if (key == null) return Future.value();
    // Fail fast on misconfiguration, synchronously and every call.
    final file = _cacheKeyFile();
    final queued = _keyQueue.then((_) => _applyCacheKey(key, file));
    // Keep the queue alive past failures; the caller still sees the error.
    _keyQueue = queued.then((_) {}, onError: (Object _) {});
    return queued;
  }

  static File _cacheKeyFile() {
    final directory = MaplibreCache.directory;
    if (directory == null) {
      throw StateError(
        'MaplibreCache.configure must run before setCacheKey: the key '
        'persists next to the database.',
      );
    }
    return File('$directory/maplibre_cache.key');
  }

  static Future<void> _applyCacheKey(String key, File file) async {
    // Re-read inside the queue: an earlier queued call may just have
    // persisted this same key.
    final persisted = file.existsSync() ? file.readAsStringSync() : null;
    if (persisted == key) return;
    await _purge();
    file.writeAsStringSync(key, flush: true);
  }

  /// The one destructive path. Retroactive by construction: it removes
  /// every row present at this moment, so a key that arrives mid-flight
  /// (Remote Config) still catches tiles fetched since launch.
  static Future<void> _purge() async {
    _busy++;
    try {
      // 1. Capture region definitions (styleUrl + geometry + metadata —
      // the group ids survive the rebuild).
      final records = await _request<List<OfflineRegionRecord>>(
        (id, link) => link.listRegions(requestId: id),
      );
      // Live handles reference native regions that are about to die.
      for (final group in List.of(_groups.values)) {
        group._abort(StateError('cache key changed: seeds rebuilding'));
      }
      // 2. Delete every region — CLEAR alone cannot touch region-pinned
      // rows.
      for (final record in records) {
        await _request<Object?>(
          (id, link) =>
              link.deleteRegion(requestId: id, regionId: record.regionId),
        );
      }
      // 3. Now everything is deletable: clear the ambient class.
      await _request<Object?>(
        (id, link) => link.ambientOp(requestId: id, op: AmbientCacheOp.clear),
      );
      // 4. Recreate + reactivate the seeds so they rebuild from the fixed
      // server as connectivity allows. Registered as groups so the link
      // (and its runtime hold) stays alive until the rebuilds finish.
      final byGroup = <String, List<OfflineRegionRecord>>{};
      for (final record in records) {
        byGroup.putIfAbsent(_groupIdOf(record), () => []).add(record);
      }
      for (final entry in byGroup.entries) {
        final regionIds = <int>[];
        for (final record in entry.value) {
          regionIds.add(
            await _request<int>(
              (id, link) => link.createRegion(
                requestId: id,
                definition: record.definition,
                metadata: record.metadata,
              ),
            ),
          );
        }
        final group = _RegionGroup(entry.key, regionIds.toSet());
        _groups[entry.key] = group;
        for (final regionId in regionIds) {
          _groupByRegion[regionId] = group;
        }
        await _observeActivatePrime(regionIds);
      }
      // 5. Re-render live maps so garbled pixels leave the screen as fresh
      // tiles arrive rather than lingering until the user pans.
      nudgeLiveRenderers();
    } finally {
      _busy--;
      _maybeGoIdle();
    }
  }

  static String _groupIdOf(OfflineRegionRecord record) {
    if (record.metadata.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(record.metadata));
        if (decoded is Map && decoded['group'] is String) {
          return decoded['group'] as String;
        }
      } on FormatException {
        // Someone else's metadata: fall through to a singleton group.
      }
    }
    return 'native:${record.regionId}';
  }

  static Future<T> _request<T>(
    void Function(int requestId, OfflineLink link) send,
  ) {
    final link = _ensureLink();
    final requestId = ++_requestSeq;
    final completer = Completer<Object?>();
    _pendingRequests[requestId] = completer;
    send(requestId, link);
    return completer.future.then((value) => value as T);
  }

  static OfflineLink _ensureLink() {
    final existing = _link;
    if (existing != null) return existing;
    final link = (debugLinkFactory ?? _defaultLink)();
    if (!link.start(_onEvent)) {
      throw StateError(
        'offline link failed to start (native side unavailable)',
      );
    }
    _link = link;
    _pumpTimer = Timer.periodic(pumpInterval, (_) => link.pump());
    return link;
  }

  static OfflineLink _defaultLink() =>
      // Android: a dedicated map-less worker thread owns the offline
      // runtime (one runtime per thread; the render workers own theirs).
      // Elsewhere the offline ops share the renderers' UI-thread runtime.
      Platform.isAndroid ? WorkerOfflineLink() : FfiOfflineLink();

  static void _onEvent(OfflineEvent event) {
    if (debugLogEvents) {
      debugPrint('[MaplibreOffline] ${_describeEvent(event)}');
    }
    switch (event) {
      case OfflineRegionCreated(:final requestId, :final regionId):
        _complete(requestId, regionId);
      case OfflineRegionList(:final requestId, :final regions):
        _complete(requestId, regions);
      case OfflineRegionDeleted(:final requestId):
        _complete(requestId, null);
      case OfflineAmbientOpCompleted(:final requestId):
        _complete(requestId, null);
      case OfflineCommandAcknowledged(:final requestId):
        _complete(requestId, null);
      case OfflineRegionStatusChanged(
        :final requestId,
        :final regionId,
        :final progress,
      ):
        if (requestId != null) _complete(requestId, progress);
        _groupByRegion[regionId]?._onStatus(regionId, progress);
      case OfflineRegionErrored(
        :final regionId,
        :final message,
        :final isFatal,
      ):
        if (isFatal) {
          _groupByRegion[regionId]?._abort(StateError(message));
        }
      case OfflineOperationFailed(:final requestId, :final message):
        _completeError(requestId, StateError(message));
    }
  }

  static String _describeEvent(OfflineEvent event) => switch (event) {
    OfflineRegionCreated(:final requestId, :final regionId) =>
      'created req=$requestId region=$regionId',
    OfflineRegionList(:final requestId, :final regions) =>
      'list req=$requestId regions=${[for (final r in regions) r.regionId]}',
    OfflineRegionDeleted(:final requestId) => 'deleted req=$requestId',
    OfflineAmbientOpCompleted(:final requestId) => 'ambient req=$requestId',
    OfflineCommandAcknowledged(:final requestId) => 'ack req=$requestId',
    OfflineRegionStatusChanged(
      :final requestId,
      :final regionId,
      :final progress,
    ) =>
      'status req=$requestId region=$regionId $progress',
    OfflineRegionErrored(:final regionId, :final message, :final isFatal) =>
      'error region=$regionId fatal=$isFatal $message',
    OfflineOperationFailed(:final requestId, :final message) =>
      'failed req=$requestId $message',
  };

  static void _complete(int requestId, Object? value) =>
      _pendingRequests.remove(requestId)?.complete(value);

  static void _completeError(int requestId, Object error) =>
      _pendingRequests.remove(requestId)?.completeError(error);

  static void _groupFinished(_RegionGroup group) {
    _groups.remove(group.id);
    for (final regionId in group.regionIds) {
      _groupByRegion.remove(regionId);
    }
    _maybeGoIdle();
  }

  static void _maybeGoIdle() {
    if (_busy > 0 || _pendingRequests.isNotEmpty || _groups.isNotEmpty) {
      return;
    }
    _pumpTimer?.cancel();
    _pumpTimer = null;
    _link?.dispose();
    _link = null;
  }

  @visibleForTesting
  static void resetForTesting() {
    for (final group in List.of(_groups.values)) {
      group._abort(StateError('resetForTesting'));
    }
    for (final completer in _pendingRequests.values) {
      completer.completeError(StateError('resetForTesting'));
    }
    _pendingRequests.clear();
    _groups.clear();
    _groupByRegion.clear();
    _busy = 0;
    _pumpTimer?.cancel();
    _pumpTimer = null;
    _link?.dispose();
    _link = null;
    debugLinkFactory = null;
    nudgeLiveRenderers = _defaultNudge;
    _keyQueue = Future.value();
  }
}

/// A live seed created by [MaplibreOffline.createRegion]. The download runs
/// independently of this handle — dropping it changes nothing; [id] works
/// with [MaplibreOffline.deleteRegion] now and on later launches.
class OfflineRegionHandle {
  OfflineRegionHandle._(this.id, this._group);

  final String id;
  final _RegionGroup _group;

  /// Combined progress across the group's styles. Emits on every native
  /// status change; errors on fatal download failure or deletion; closes
  /// when the seed completes.
  Stream<OfflineRegionProgress> get progress => _group.controller.stream;

  /// Resolves when every style's region reports complete; errors if the
  /// download dies (tile limit) or the region is deleted mid-download.
  Future<void> get whenComplete => _group.doneFuture;
}

class _RegionGroup {
  _RegionGroup(this.id, this.regionIds) {
    doneFuture = _done.future;
    // A caller may use only the stream (or neither); an abandoned
    // whenComplete must not surface as an unhandled async error.
    doneFuture.ignore();
  }

  final String id;
  final Set<int> regionIds;
  final Map<int, OfflineRegionProgress> _byRegion = {};
  final controller = StreamController<OfflineRegionProgress>.broadcast();
  final _done = Completer<void>();
  late final Future<void> doneFuture;

  void _onStatus(int regionId, OfflineRegionProgress progress) {
    if (_done.isCompleted) return;
    _byRegion[regionId] = progress;
    var combined = _byRegion.values.reduce((a, b) => a + b);
    final allReported = _byRegion.length == regionIds.length;
    if (!allReported && combined.isComplete) {
      // A pair is not complete until every member has reported.
      combined = OfflineRegionProgress(
        completedResources: combined.completedResources,
        requiredResources: combined.requiredResources,
        completedTiles: combined.completedTiles,
        requiredTiles: combined.requiredTiles,
        completedBytes: combined.completedBytes,
        requiredIsPrecise: combined.requiredIsPrecise,
        isComplete: false,
        isDownloading: combined.isDownloading,
      );
    }
    controller.add(combined);
    if (allReported && combined.isComplete) {
      controller.close();
      _done.complete();
      MaplibreOffline._groupFinished(this);
    }
  }

  void _abort(Object error) {
    if (_done.isCompleted) return;
    controller.addError(error);
    controller.close();
    _done.completeError(error);
    MaplibreOffline._groupFinished(this);
  }
}
