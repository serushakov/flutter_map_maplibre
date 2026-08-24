import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Scripted [OfflineLink]: answers every command synchronously the way the
/// native side would, records the call sequence, and lets tests push region
/// status/error events by hand.
class FakeOfflineLink implements OfflineLink {
  FakeOfflineLink({this.failCreateForStyle});

  /// When set, createRegion for this style URL answers with
  /// [OfflineOperationFailed] instead of success.
  final String? failCreateForStyle;

  final List<String> log = [];
  bool started = false;
  bool disposed = false;
  int _nextRegionId = 0;
  final Map<int, OfflineRegionDefinition> defs = {};
  final Map<int, Uint8List> metadata = {};
  void Function(OfflineEvent event)? _onEvent;

  void emit(OfflineEvent event) => _onEvent!(event);

  OfflineRegionProgress statusFor(
    int regionId, {
    int tiles = 0,
    int required = 10,
    bool complete = false,
  }) => OfflineRegionProgress(
    completedResources: tiles + 2,
    requiredResources: required + 2,
    completedTiles: tiles,
    requiredTiles: required,
    completedBytes: tiles * 1000,
    requiredIsPrecise: true,
    isComplete: complete,
    isDownloading: !complete,
  );

  @override
  bool start(void Function(OfflineEvent event) onEvent) {
    started = true;
    _onEvent = onEvent;
    return true;
  }

  @override
  void createRegion({
    required int requestId,
    required OfflineRegionDefinition definition,
    required Uint8List metadata,
  }) {
    log.add('create:${definition.styleUrl}');
    if (definition.styleUrl == failCreateForStyle) {
      emit(
        OfflineOperationFailed(requestId: requestId, message: 'scripted fail'),
      );
      return;
    }
    final regionId = ++_nextRegionId;
    defs[regionId] = definition;
    this.metadata[regionId] = metadata;
    emit(OfflineRegionCreated(requestId: requestId, regionId: regionId));
  }

  @override
  void setDownloadState({
    required int requestId,
    required int regionId,
    required bool active,
  }) {
    log.add('downloadState:$regionId:$active');
    emit(OfflineCommandAcknowledged(requestId: requestId));
  }

  @override
  void setObserved({
    required int requestId,
    required int regionId,
    required bool observed,
  }) {
    log.add('observe:$regionId:$observed');
    emit(OfflineCommandAcknowledged(requestId: requestId));
  }

  @override
  void listRegions({required int requestId}) {
    log.add('list');
    emit(
      OfflineRegionList(
        requestId: requestId,
        regions: [
          for (final entry in defs.entries)
            OfflineRegionRecord(
              regionId: entry.key,
              definition: entry.value,
              metadata: metadata[entry.key] ?? Uint8List(0),
            ),
        ],
      ),
    );
  }

  @override
  void deleteRegion({required int requestId, required int regionId}) {
    log.add('delete:$regionId');
    defs.remove(regionId);
    metadata.remove(regionId);
    emit(OfflineRegionDeleted(requestId: requestId));
  }

  @override
  void requestStatus({required int requestId, required int regionId}) {
    log.add('status:$regionId');
    emit(
      OfflineRegionStatusChanged(
        requestId: requestId,
        regionId: regionId,
        progress: statusFor(regionId, tiles: regionId),
      ),
    );
  }

  @override
  void ambientOp({required int requestId, required AmbientCacheOp op}) {
    log.add('ambient:${op.name}');
    emit(OfflineAmbientOpCompleted(requestId: requestId));
  }

  @override
  void pump() {}

  @override
  void dispose() {
    disposed = true;
    _onEvent = null;
  }
}

final _bounds = LatLngBounds(
  const LatLng(59.42, 24.72),
  const LatLng(59.45, 24.78),
);

void main() {
  late FakeOfflineLink link;
  var factoryCalls = 0;

  setUp(() {
    MaplibreOffline.resetForTesting();
    factoryCalls = 0;
    link = FakeOfflineLink();
    MaplibreOffline.debugLinkFactory = () {
      factoryCalls++;
      return link;
    };
  });

  tearDown(MaplibreOffline.resetForTesting);

  Future<OfflineRegionHandle> createTallinn({List<String>? styles}) =>
      MaplibreOffline.createRegion(
        styleUrls: styles ?? ['https://s/light'],
        bounds: _bounds,
        minZoom: 12,
        maxZoom: 14,
        pixelRatio: 3,
      );

  test('create → activate → progress → complete', () async {
    final handle = await createTallinn();
    expect(link.log, [
      'create:https://s/light',
      'observe:1:true',
      'downloadState:1:true',
      'status:1', // priming snapshot
    ]);

    final seen = <OfflineRegionProgress>[];
    handle.progress.listen(seen.add);

    link.emit(
      OfflineRegionStatusChanged(
        regionId: 1,
        progress: link.statusFor(1, tiles: 4),
      ),
    );
    link.emit(
      OfflineRegionStatusChanged(
        regionId: 1,
        progress: link.statusFor(1, tiles: 10, complete: true),
      ),
    );
    await handle.whenComplete;
    await null; // let the stream deliver
    expect(seen.map((p) => p.completedTiles), [4, 10]);
    expect(seen.last.isComplete, true);
    // Download drained → the link (and its runtime hold) is released.
    expect(link.disposed, true);
  });

  test('style pair: combined progress, complete only when both are', () async {
    final handle = await createTallinn(
      styles: ['https://s/light', 'https://s/dark'],
    );
    expect(link.log.where((l) => l.startsWith('create:')).length, 2);

    final seen = <OfflineRegionProgress>[];
    handle.progress.listen(seen.add);

    // First member completes: combined must not read complete yet.
    link.emit(
      OfflineRegionStatusChanged(
        regionId: 1,
        progress: link.statusFor(1, tiles: 10, complete: true),
      ),
    );
    await null;
    expect(seen.last.isComplete, false);
    // 10 from region 1 + the priming snapshot's 2 for region 2.
    expect(seen.last.completedTiles, 12);

    link.emit(
      OfflineRegionStatusChanged(
        regionId: 2,
        progress: link.statusFor(2, tiles: 10, complete: true),
      ),
    );
    await handle.whenComplete;
    await null;
    expect(seen.last.isComplete, true);
    expect(seen.last.completedTiles, 20); // summed across the pair
    expect(link.disposed, true);
  });

  test('budget rejection happens before any native work', () async {
    await expectLater(
      MaplibreOffline.createRegion(
        styleUrls: const ['https://s/light'],
        bounds: _bounds,
        minZoom: 0,
        maxZoom: 14,
        maxTiles: 3,
      ),
      throwsA(isA<TileBudgetExceeded>()),
    );
    expect(factoryCalls, 0);
  });

  test('a generous budget admits the region', () async {
    final handle = await MaplibreOffline.createRegion(
      styleUrls: const ['https://s/light'],
      bounds: _bounds,
      minZoom: 12,
      maxZoom: 14,
      maxTiles: 1000,
      pixelRatio: 3,
    );
    expect(handle.id, isNotEmpty);
  });

  test('fatal tile-limit error fails the handle', () async {
    final handle = await createTallinn();
    final errors = <Object>[];
    handle.progress.listen((_) {}, onError: errors.add);
    link.emit(
      const OfflineRegionErrored(
        regionId: 1,
        message: 'tile count limit 6000 reached',
        isFatal: true,
      ),
    );
    await expectLater(handle.whenComplete, throwsStateError);
    await null;
    expect(errors, hasLength(1));
    expect(link.disposed, true);
  });

  test(
    'a member that completes before the handle exists still counts',
    () async {
      // The race the priming snapshot closes: a fully-deduped member
      // finishes during createRegion's ack sequence and never emits another
      // status event. The snapshot must stand in for it.
      link = _InstantlyCompleteLink();
      final handle = await createTallinn(
        styles: ['https://s/light', 'https://s/dark'],
      );
      // No further events at all — completion came entirely from the primes.
      await handle.whenComplete;
    },
  );

  test('non-fatal resource errors do not kill the download', () async {
    final handle = await createTallinn();
    link.emit(
      const OfflineRegionErrored(
        regionId: 1,
        message: 'resource response error (reason 2)',
        isFatal: false,
      ),
    );
    link.emit(
      OfflineRegionStatusChanged(
        regionId: 1,
        progress: link.statusFor(1, tiles: 10, complete: true),
      ),
    );
    await handle.whenComplete; // still completes
  });

  test(
    'delete while active aborts the handle and deletes both members',
    () async {
      final handle = await createTallinn(
        styles: ['https://s/light', 'https://s/dark'],
      );
      final done = expectLater(handle.whenComplete, throwsStateError);
      await MaplibreOffline.deleteRegion(handle.id);
      await done;
      expect(link.log, containsAllInOrder(['delete:1', 'delete:2']));
      expect(link.defs, isEmpty);
      expect(link.disposed, true);
    },
  );

  test('deleting an unknown id throws without touching regions', () async {
    await expectLater(
      MaplibreOffline.deleteRegion('nope'),
      throwsArgumentError,
    );
    expect(link.log.where((l) => l.startsWith('delete:')), isEmpty);
  });

  test('listRegions groups by metadata and sums statuses', () async {
    await createTallinn(styles: ['https://s/light', 'https://s/dark']);
    // A region some other tool created: no metadata → its own group.
    link.defs[99] = const OfflineRegionDefinition(
      styleUrl: 'https://elsewhere/style',
      south: 0,
      west: 0,
      north: 1,
      east: 1,
      minZoom: 3,
      maxZoom: 5,
      pixelRatio: 1,
    );

    final regions = await MaplibreOffline.listRegions();
    expect(regions, hasLength(2));

    final pair = regions.singleWhere((r) => r.styleUrls.length == 2);
    expect(pair.styleUrls, ['https://s/light', 'https://s/dark']);
    expect(pair.minZoom, 12);
    expect(pair.maxZoom, 14);
    // statusFor(regionId) reports `regionId` completed tiles: 1 + 2.
    expect(pair.progress.completedTiles, 3);

    final foreign = regions.singleWhere((r) => r.styleUrls.length == 1);
    expect(foreign.id, 'native:99');
    expect(foreign.progress.completedTiles, 99);
  });

  test('failed second create rolls back the first', () async {
    link = FakeOfflineLink(failCreateForStyle: 'https://s/dark');
    await expectLater(
      createTallinn(styles: ['https://s/light', 'https://s/dark']),
      throwsStateError,
    );
    expect(link.log, [
      'create:https://s/light',
      'create:https://s/dark',
      'delete:1',
    ]);
    expect(link.defs, isEmpty);
    expect(link.disposed, true);
  });

  test('a link that cannot start surfaces as StateError', () async {
    MaplibreOffline.debugLinkFactory = _NoStartLink.new;
    await expectLater(createTallinn(), throwsStateError);
  });

  test('estimateTileCount delegates to the pure function', () {
    expect(
      MaplibreOffline.estimateTileCount(
        bounds: _bounds,
        minZoom: 12,
        maxZoom: 14,
      ),
      estimateTileCount(
        south: _bounds.south,
        west: _bounds.west,
        north: _bounds.north,
        east: _bounds.east,
        minZoom: 12,
        maxZoom: 14,
      ),
    );
  });
}

class _NoStartLink extends FakeOfflineLink {
  @override
  bool start(void Function(OfflineEvent event) onEvent) => false;
}

class _InstantlyCompleteLink extends FakeOfflineLink {
  @override
  void requestStatus({required int requestId, required int regionId}) {
    log.add('status:$regionId');
    emit(
      OfflineRegionStatusChanged(
        requestId: requestId,
        regionId: regionId,
        progress: statusFor(regionId, tiles: 10, complete: true),
      ),
    );
  }
}
