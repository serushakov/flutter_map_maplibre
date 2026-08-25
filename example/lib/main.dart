import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_maplibre/flutter_map_maplibre.dart';
import 'package:latlong2/latlong.dart';

void main() {
  // Persistent cache probe wiring (spec 2026-08-24): a real database path
  // instead of :memory:. HOME is the app sandbox container on iOS.
  // HOME is absent from the app process environment; systemTemp is
  // <container>/tmp on iOS and the app cache dir on Android, so its parent
  // is the app's data root on both. (A real app would use path_provider;
  // the example stays dependency-free.)
  try {
    final dataRoot = Directory.systemTemp.parent.path;
    final dir = Directory(
      Platform.isAndroid
          ? '$dataRoot/files/fmm_cache'
          : '$dataRoot/Library/Application Support/fmm_cache',
    )..createSync(recursive: true);
    // FMM_AMBIENT_CAP (bytes) exercises eviction: ambient stays under the
    // cap while seeded regions stay pinned outside it.
    const cap = int.fromEnvironment('FMM_AMBIENT_CAP');
    MaplibreCache.configure(
      directory: dir.path,
      maxAmbientBytes: cap > 0 ? cap : null,
    );
  } on FileSystemException catch (e) {
    debugPrint('[cache-probe] cache dir failed: $e');
  }
  debugPrint('[cache-probe] dbPath=${MaplibreCache.databasePath}');
  MaplibreOffline.debugLogEvents = true;
  // Cold-start-from-cache leg: the map must render Tallinn purely from the
  // persisted database. A flag FILE (not env: Platform.environment is
  // empty-ish inside the simulator app process) next to the database flips
  // it, so the harness can touch it between launches of the same install:
  //   touch "<container>/Library/Application Support/fmm_cache/force_offline"
  final offlineFlag = File(
    '${File(MaplibreCache.databasePath).parent.path}/force_offline',
  );
  if (const bool.fromEnvironment('FMM_START_OFFLINE') ||
      offlineFlag.existsSync()) {
    try {
      final status = MaplibreNetwork.setOffline(true);
      debugPrint('[cache-probe] network_status_set(OFFLINE) -> $status');
    } on ArgumentError catch (e) {
      // Symbol missing from the binary (podspec -u flags not applied):
      // surface it without killing the app.
      debugPrint('[cache-probe] forceOffline failed: $e');
    }
  }
  runApp(const ExampleApp());
}

const _tallinn = LatLng(59.437, 24.7536);
// OpenFreeMap: full-planet OSM vector tiles, open infrastructure, no API key.
const _light = 'https://tiles.openfreemap.org/styles/liberty';
const _darkStyle = 'https://tiles.openfreemap.org/styles/dark';

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: MapPage());
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with SingleTickerProviderStateMixin {
  final _mapController = MapController();
  Map<String, Object?> _diagnostics = const {};
  bool _dark = false;
  // The worker renderer ships on Android only; iOS stays on the
  // synchronous ffi renderer.
  bool _useWorker = Platform.isAndroid;
  Ticker? _ticker;

  /// Android display-latency compensation, in frames. Cycled live so the
  /// right depth can be found by feel: the setting where the marker locks to
  /// the map during a pan is the true BufferQueue latch latency.
  int _latencyFrames = FfiBasemapRenderer.androidPresentLatencyFrames;

  OfflineRegionHandle? _seed;
  Map<String, Object?> _cacheProbeStats = const {};

  @override
  void initState() {
    super.initState();
    // Headless driving of the offline seeding (no tap tooling on the
    // simulator):  --dart-define=FMM_AUTO_PROBE=true
    // starts it once the map has had time to come up.
    if (const bool.fromEnvironment('FMM_AUTO_PROBE')) {
      Future<void>.delayed(const Duration(seconds: 5), () {
        if (mounted && _seed == null) _toggleCacheProbe();
      });
    }
    // Eviction harness: sweep the camera across Europe to fill the ambient
    // class well past any FMM_AMBIENT_CAP, then park back on Tallinn.
    if (const bool.fromEnvironment('FMM_AUTO_TOUR')) {
      Future<void>.delayed(const Duration(seconds: 8), _runTour);
    }
    // Covered-purge harness: cover the map with an opaque route, force
    // offline + clear the ambient class while covered, pop. The refocused
    // map must not keep presenting pre-purge pixels.
    if (const bool.fromEnvironment('FMM_AUTO_COVERPURGE')) {
      Future<void>.delayed(const Duration(seconds: 12), _runCoverPurge);
    }
  }

  Future<void> _runCoverPurge() async {
    if (!mounted) return;
    debugPrint('[coverpurge] covering');
    final nav = Navigator.of(context);
    final route = MaterialPageRoute<void>(
      builder: (_) =>
          const Scaffold(body: Center(child: Text('covering route'))),
    );
    unawaited(nav.push(route));
    await Future<void>.delayed(const Duration(seconds: 3));
    debugPrint('[coverpurge] offline + clear');
    MaplibreNetwork.setOffline(true);
    await MaplibreOffline.clearAmbientCache();
    debugPrint('[coverpurge] cleared');
    await Future<void>.delayed(const Duration(seconds: 5));
    debugPrint('[coverpurge] popping');
    nav.removeRoute(route);
  }

  Future<void> _runTour() async {
    const stops = [
      LatLng(59.437, 24.7536), // Tallinn
      LatLng(56.9496, 24.1052), // Riga
      LatLng(54.6872, 25.2797), // Vilnius
      LatLng(52.2297, 21.0122), // Warsaw
      LatLng(50.0755, 14.4378), // Prague
      LatLng(48.2082, 16.3738), // Vienna
      LatLng(47.4979, 19.0402), // Budapest
      LatLng(52.52, 13.405), // Berlin
      LatLng(48.8566, 2.3522), // Paris
      LatLng(51.5072, -0.1276), // London
      LatLng(40.4168, -3.7038), // Madrid
      LatLng(41.9028, 12.4964), // Rome
    ];
    debugPrint('[cache-probe] tour start');
    for (final stop in stops) {
      if (!mounted) return;
      // A few zooms per city: each level fetches a fresh tile set.
      for (final zoom in const [9.0, 11.0, 13.0]) {
        _mapController.move(stop, zoom);
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        if (!mounted) return;
      }
    }
    _mapController.move(_tallinn, 13);
    debugPrint('[cache-probe] tour done');
  }

  /// Seeds a tiny Tallinn region — both themes as one unit — through the
  /// real MaplibreOffline facade, streaming progress into the stats wall.
  /// Tapping again deletes the seed (exercising delete, including
  /// delete-while-active).
  Future<void> _toggleCacheProbe() async {
    if (_seed != null) {
      final id = _seed!.id;
      setState(() {
        _seed = null;
        _cacheProbeStats = const {};
      });
      try {
        await MaplibreOffline.deleteRegion(id);
        debugPrint('[cache-probe] deleted $id');
      } on Object catch (e) {
        debugPrint('[cache-probe] delete failed: $e');
      }
      return;
    }
    final handle = await MaplibreOffline.createRegion(
      styleUrls: [_light, _darkStyle],
      bounds: LatLngBounds(
        LatLng(_tallinn.latitude - 0.015, _tallinn.longitude - 0.03),
        LatLng(_tallinn.latitude + 0.015, _tallinn.longitude + 0.03),
      ),
      minZoom: 12,
      maxZoom: 14,
      maxTiles: 500,
      pixelRatio: MediaQuery.of(context).devicePixelRatio,
    );
    debugPrint('[cache-probe] seed ${handle.id} created');
    handle.progress.listen((p) {
      debugPrint('[cache-probe] progress $p');
      if (mounted) {
        setState(
          () => _cacheProbeStats = {
            'seedTiles': '${p.completedTiles}/${p.requiredTiles}',
            'seedResources': '${p.completedResources}/${p.requiredResources}',
            'seedBytes': p.completedBytes,
            'seedComplete': p.isComplete,
          },
        );
      }
    }, onError: (Object e) => debugPrint('[cache-probe] seed error: $e'));
    unawaited(
      handle.whenComplete.then(
        (_) async {
          debugPrint('[cache-probe] seed complete');
          final regions = await MaplibreOffline.listRegions();
          for (final region in regions) {
            debugPrint('[cache-probe] listed: $region');
          }
          // Kill-switch leg: flip the cache key once the seed is in, so the
          // harness can watch the purge capture → delete → clear → reseed →
          // nudge sequence run against real regions and a live map.
          if (const bool.fromEnvironment('FMM_AUTO_KEYFLIP')) {
            await _flipCacheKey();
          }
        },
        onError: (Object e) {
          debugPrint('[cache-probe] seed failed: $e');
        },
      ),
    );
    setState(() => _seed = handle);
  }

  /// Simulates the Remote Config kill switch: a fresh key every press.
  Future<void> _flipCacheKey() async {
    final key = 'flip-${DateTime.now().millisecondsSinceEpoch}';
    debugPrint('[cache-probe] setCacheKey($key)');
    try {
      await MaplibreCache.setCacheKey(key);
      debugPrint('[cache-probe] purge committed for $key');
      final regions = await MaplibreOffline.listRegions();
      for (final region in regions) {
        debugPrint('[cache-probe] after purge: $region');
      }
    } on Object catch (e) {
      debugPrint('[cache-probe] setCacheKey failed: $e');
    }
  }

  void _cycleLatencyFrames() {
    setState(() {
      _latencyFrames = (_latencyFrames + 1) % 4;
      // Both renderers share this knob's meaning and default (1 frame); keep
      // them in lockstep so the FAB affects whichever one is active.
      FfiBasemapRenderer.androidPresentLatencyFrames = _latencyFrames;
      WorkerBasemapRenderer.presentLatencyFrames = _latencyFrames;
    });
  }

  /// Render-resolution ladder: fraction of native dpr the map renders at.
  /// Cycling recreates the session (brief style reload) — fine for a knob.
  static const _renderScales = [1.0, 0.85, 0.7, 0.55];
  int _renderScaleIndex = 0;

  void _cycleRenderScale() {
    setState(() {
      _renderScaleIndex = (_renderScaleIndex + 1) % _renderScales.length;
    });
  }

  /// Drives pan, zoom and rotation at once — the condition the residual
  /// transform exists for.
  void _toggleAutoPan() {
    if (_ticker != null) {
      _ticker!.dispose();
      setState(() => _ticker = null);
      return;
    }
    final ticker = createTicker((elapsed) {
      final t = elapsed.inMilliseconds / 1000.0;
      _mapController.moveAndRotate(
        LatLng(
          _tallinn.latitude + 0.012 * math.sin(t * 1.1),
          _tallinn.longitude + 0.022 * math.cos(t * 0.9),
        ),
        13.0 + 0.6 * math.sin(t * 0.7),
        18.0 * math.sin(t * 0.5),
      );
    })..start();
    setState(() => _ticker = ticker);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = [
      ..._cacheProbeStats.entries.map((e) => '${e.key}: ${e.value}'),
      ..._diagnostics.entries.map((e) => '${e.key}: ${e.value}'),
    ].join('   ');

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(initialCenter: _tallinn, initialZoom: 13),
            children: [
              MapLibreBasemap(
                key: ValueKey('renderer-$_useWorker'),
                styleUrl: _dark ? _darkStyle : _light,
                // Margin so the lead bias can keep the leading edge covered
                // during flicks: on Android the placed frame is one present
                // old (BufferQueue latch), which bares a velocity x 8.3ms
                // strip without it.
                overRenderFactor: 1.1,
                renderScale: _renderScales[_renderScaleIndex],
                rendererFactory: _useWorker
                    ? WorkerBasemapRenderer.new
                    : FfiBasemapRenderer.new,
                onDiagnostics: (d) {
                  if (mounted) setState(() => _diagnostics = d);
                },
              ),
              MarkerLayer(
                markers: const [
                  Marker(
                    point: _tallinn,
                    width: 20,
                    height: 20,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(0xFFFF2D55),
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                          BorderSide(color: Colors.white, width: 3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'theme',
                      onPressed: () => setState(() => _dark = !_dark),
                      child: Icon(_dark ? Icons.light_mode : Icons.dark_mode),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'pan',
                      onPressed: _toggleAutoPan,
                      child: Icon(
                        _ticker == null ? Icons.play_arrow : Icons.pause,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'latency',
                      onPressed: _cycleLatencyFrames,
                      child: Text('$_latencyFrames'),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'scale',
                      onPressed: _cycleRenderScale,
                      child: Text(
                        '${(_renderScales[_renderScaleIndex] * 100).round()}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    if (Platform.isAndroid) ...[
                      const SizedBox(height: 8),
                      FloatingActionButton.small(
                        heroTag: 'renderer',
                        onPressed: () =>
                            setState(() => _useWorker = !_useWorker),
                        child: Text(_useWorker ? 'wkr' : 'ffi'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'cache',
                      onPressed: _toggleCacheProbe,
                      child: Icon(
                        _seed == null
                            ? Icons.download_for_offline_outlined
                            : Icons.stop_circle_outlined,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'cachekey',
                      onPressed: _flipCacheKey,
                      child: const Icon(Icons.key_off),
                    ),
                    const SizedBox(height: 8),
                    // Multi-instance test case: push a second screen with its
                    // own map while this one stays mounted in the nav stack —
                    // the shape that used to blank the new map and crash
                    // (single presenter slot per plugin). Pass: the pushed map
                    // renders Helsinki, and popping back resumes this one.
                    FloatingActionButton.small(
                      heroTag: 'push',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SecondMapPage(),
                        ),
                      ),
                      child: const Icon(Icons.layers),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (stats.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 24,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    stats,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Second live map on top of the nav stack — the dormant-map-below scenario.
/// Different city and style so each instance is unmistakably its own.
class SecondMapPage extends StatelessWidget {
  const SecondMapPage({super.key});

  static const _helsinki = LatLng(60.1699, 24.9384);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        FlutterMap(
          options: const MapOptions(initialCenter: _helsinki, initialZoom: 12),
          children: const [
            MapLibreBasemap(styleUrl: _darkStyle, overRenderFactor: 1.1),
          ],
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FloatingActionButton.small(
              heroTag: 'pop',
              onPressed: () => Navigator.of(context).pop(),
              child: const Icon(Icons.arrow_back),
            ),
          ),
        ),
      ],
    ),
  );
}
